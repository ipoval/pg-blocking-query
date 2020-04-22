# NOTE: to workaround security constraints
# CREATE OR REPLACE FUNCTION secure_pg_kill_connection(integer) RETURNS boolean AS 'select pg_terminate_backend($1);' LANGUAGE SQL SECURITY DEFINER;

# NOTE: to avoid aborting blocking transaction in some context
# SET application_name = 'exempt_schema_migration';

# NOTE:
#   usage: SELECT abort_blocking_query();
#
CREATE OR REPLACE FUNCTION public.abort_blocking_query() RETURNS void AS $$
DECLARE
  allowed_blocking_app CONSTANT varchar(25) := 'exempt_schema_migration';
  blocking_pid_var integer;
  blocked_pids_count_var integer;
BEGIN
  RAISE INFO 'abort_blocking_query | start';

  select     pgsa.pid into blocking_pid_var
  from       pg_stat_activity pgsa
  inner join pg_locks pgl on (pgsa.pid = pgl.pid)
  where
  (
    (pgsa.state='active' and pgsa.wait_event='relation' and pgsa.wait_event_type='Lock') or
    (pgsa.state='idle in transaction' and pgsa.wait_event='ClientRead' and pgsa.wait_event_type='Client')
  )
  and        pgsa.backend_type='client backend'
  and        age(now(), pgsa.query_start) > '4 second'::interval
  and not    pgsa.application_name=allowed_blocking_app
  and        (pgl.mode = 'AccessExclusiveLock' or pgl.mode = 'ShareLock' or pgl.mode = 'ShareRowExclusiveLock')
  limit 1;

  IF blocking_pid_var IS NOT NULL THEN
    RAISE WARNING 'abort_blocking_query | found blocking pid %', blocking_pid_var;

    select     count(pgsa.pid) into blocked_pids_count_var
    from       pg_stat_activity pgsa
    inner join pg_locks pgl on (pgsa.pid = pgl.pid)
    where      pgsa.state='active'
    and        pgsa.wait_event='relation'
    and        pgsa.wait_event_type='Lock'
    and        pgsa.backend_type='client backend'
    and        age(now(), pgsa.query_start) > '4 second'::interval
    and not    pgl.granted
    and        (blocking_pid_var)=any(pg_blocking_pids(pgsa.pid));

    IF blocked_pids_count_var > 2 THEN
      RAISE WARNING 'abort_blocking_query | found blocked pids %, terminating %', blocked_pids_count_var, blocking_pid_var;
      perform secure_pg_kill_connection(blocking_pid_var);
    END IF;
  END IF;
END;
$$ LANGUAGE PLPGSQL;
