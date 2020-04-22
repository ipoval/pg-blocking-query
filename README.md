### The problem context
- transaction A starts with `ROW SHARE` or `ROW EXCLUSIVE` lock type
- transaction B starts with `ACCESS EXCLUSIVE` lock type which has to be scheduled into waiting queue since it's conflicting with A. It will make a lock entry in the lock queue
    * `ALTER TABLE` for example
- transactions C, D, E, ... with lock types `ACCESS SHARE`, ... will all have to be scheduled into the waiting queue, waiting on transaction B to execute
    * that includes all types of read transactions
### TLDR;
- `SELECT`s cannot start if a table is about to be `ALTER`ed
   - prevention: set an adequate `lock_timeout`
  ```sql
  BEGIN;
  SET LOCAL lock_timeout = '2s';
  ALTER TABLE high_reads_and_writes_table ADD COLUMN col_blocking_query_test varchar(5);
  COMMIT;
  ```
   - use `pg_abort_blocking_query_procedure.sql` to schedule automatic abortion of blocking queries

### Reproduce and test
```sql
"/Applications/Postgres.app/Contents/Versions/10/bin/psql" -p5432 -d "testdb"

SELECT pg_backend_pid();
SELECT pg_blocking_pids(51165);
SELECT pg_blocking_pids(50733);
SELECT pg_blocking_pids(50844);

CREATE TABLE messages(id INTEGER, body VARCHAR(50));

BEGIN TRANSACTION;
LOCK messages IN ACCESS EXCLUSIVE MODE;
COMMIT;

do $$
begin
  for i in 1..1400000 loop
    INSERT INTO messages VALUES (i, 'body');
  end loop;
end;$$;

###################################################### REPRODUCE
# terminal 1
do $$
begin
  for i in 1000..5000 loop
    PERFORM body FROM messages WHERE ID = i FOR UPDATE;
  end loop;
end;$$;
################################################################

# terminal 2 - test case for AccessExclusiveLock
ALTER TABLE messages ALTER COLUMN body TYPE VARCHAR(51);
# or
DROP INDEX messages_body_idx;
################################################################

# terminal 3
update messages set body = 'value' where id=1;
################################################################

# terminal 4
select * from messages where id=2;
################################################################

# terminal 5
select * from messages where id=999 for update;
select * from messages where id=1000 for update;
################################################################

# terminal 6
\x on;
select pgsa.*, pg_blocking_pids(pgsa.pid) as blocking_pids, age(now(), query_start) as runtime, pgl.mode from pg_stat_activity pgsa inner join pg_locks pgl on (pgsa.pid = pgl.pid) where pgsa.state='active' and pgsa.backend_type='client backend' and age(now(), pgsa.query_start) > '1 second'::interval and not pgl.granted;
select pgsa.*, pg_blocking_pids(pgsa.pid) as blocking_pids, age(now(), query_start) as runtime, pgl.mode from pg_stat_activity pgsa inner join pg_locks pgl on (pgsa.pid = pgl.pid) where pgsa.state='active' and pgsa.wait_event='relation' and pgsa.wait_event_type='Lock' and pgsa.backend_type='client backend' and age(now(), pgsa.query_start) > '4 second'::interval and not pgl.granted;
=> 50733

###################################################### REPRODUCE
select pgsa.*, pg_blocking_pids(pgsa.pid) as blocking_pids, age(now(), query_start) as runtime, pgl.mode from pg_stat_activity pgsa inner join pg_locks pgl on (pgsa.pid = pgl.pid) where pgsa.state='active' and pgsa.wait_event='relation' and pgsa.wait_event_type='Lock' and pgsa.backend_type='client backend' and age(now(), pgsa.query_start) > '5 second'::interval and not pgl.granted and (50733)=ANY(pg_blocking_pids(pgsa.pid));
################################################################

# Test case for ShareLock
CREATE INDEX messages_body_idx ON messages(body);
update messages set body = 'value' where id=1;
update messages set body = 'value' where id=2;
update messages set body = 'value' where id=3;
################################################################

# Test case for ShareRowExclusiveLock
CREATE OR REPLACE FUNCTION totalRecords() RETURNS integer AS $total$
declare
  total integer;
BEGIN
  SELECT count(*) into total FROM messages;
  RETURN total;
END;
$total$ LANGUAGE plpgsql;

CREATE TRIGGER check_total_records BEFORE UPDATE ON messages FOR EACH ROW EXECUTE PROCEDURE totalRecords();
################################################################

# Test case for ExclusiveLock
CREATE MATERIALIZED VIEW messages_top_5_view AS SELECT messages.id,messages.body from messages limit 1000000;
CREATE UNIQUE INDEX messages_top_5_view_idx ON messages_top_5_view(id);
drop materialized view messages_top_5_view;
refresh materialized view concurrently messages_top_5_view;
################################################################
```
