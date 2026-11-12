-- Verify the ~22:00 (Asia/Bangkok) CPU spike directly on the Cloud SQL PostgreSQL instance.
-- Run as a user with pg_read_all_stats (e.g. cloudsqlsuperuser).

-- 0) What is scheduled around 22:00? (pg_cron, if installed)
SELECT jobid, schedule, command, database, username, active
FROM cron.job ORDER BY schedule;
SELECT jobid, start_time AT TIME ZONE 'Asia/Bangkok' AS start_ict, end_time - start_time AS dur, status, left(command, 200)
FROM cron.job_run_details
WHERE start_time > now() - interval '7 days'
  AND extract(hour FROM start_time AT TIME ZONE 'Asia/Bangkok') BETWEEN 21 AND 23
ORDER BY start_time DESC;

-- 1) Live view: run this DURING 21:55-22:30 to catch what is actually burning CPU
SELECT pid, usename, datname, application_name, client_addr, state,
       now() - query_start AS running_for, wait_event_type, wait_event,
       query_id, left(query, 300) AS query
FROM pg_stat_activity
WHERE state <> 'idle' AND pid <> pg_backend_pid()
ORDER BY query_start;

-- 2) Snapshot pg_stat_statements before and after the window, then diff
--    (requires pg_stat_statements; Cloud SQL enables it with Query Insights)
CREATE TABLE IF NOT EXISTS public._pss_snap AS
SELECT now() AS snap_at, userid, dbid, queryid, calls, total_exec_time, rows,
       shared_blks_hit, shared_blks_read, temp_blks_written, query
FROM pg_stat_statements WHERE false;

-- run at ~21:30 and again at ~23:00:
INSERT INTO public._pss_snap
SELECT now(), userid, dbid, queryid, calls, total_exec_time, rows,
       shared_blks_hit, shared_blks_read, temp_blks_written, query
FROM pg_stat_statements;

-- diff of the last two snapshots: top queries during the window
WITH s AS (
  SELECT DISTINCT snap_at FROM public._pss_snap ORDER BY snap_at DESC LIMIT 2
), a AS (SELECT * FROM public._pss_snap WHERE snap_at = (SELECT min(snap_at) FROM s)),
   b AS (SELECT * FROM public._pss_snap WHERE snap_at = (SELECT max(snap_at) FROM s))
SELECT b.queryid,
       b.calls - coalesce(a.calls, 0)                              AS calls,
       round((b.total_exec_time - coalesce(a.total_exec_time, 0))::numeric / 1000, 1) AS exec_s,
       round(((b.total_exec_time - coalesce(a.total_exec_time, 0))
              / nullif(b.calls - coalesce(a.calls, 0), 0))::numeric, 2) AS avg_ms,
       b.rows - coalesce(a.rows, 0)                                AS rows,
       b.shared_blks_hit - coalesce(a.shared_blks_hit, 0)          AS blks_hit,
       b.shared_blks_read - coalesce(a.shared_blks_read, 0)        AS blks_read,
       b.temp_blks_written - coalesce(a.temp_blks_written, 0)      AS temp_written,
       left(b.query, 300) AS query
FROM b LEFT JOIN a USING (userid, dbid, queryid)
ORDER BY exec_s DESC NULLS LAST
LIMIT 20;

-- 3) For each suspect query from the Query Insights report:
--    EXPLAIN (ANALYZE, BUFFERS) <query with realistic params>;   -- on a replica / off-peak if heavy
--    Look for: Seq Scan on large tables, high "Rows Removed by Filter", Sort/Hash spilling to disk,
--    nested loops with large loops= counts.

-- 4) Tables getting sequentially scanned heavily (candidate missing indexes)
SELECT relname, seq_scan, seq_tup_read, idx_scan, n_live_tup,
       round(seq_tup_read::numeric / nullif(seq_scan, 0)) AS avg_rows_per_seqscan
FROM pg_stat_user_tables
ORDER BY seq_tup_read DESC LIMIT 20;

-- 5) Autovacuum / analyze running at that time? (also CPU)
SELECT relname, last_autovacuum AT TIME ZONE 'Asia/Bangkok', last_autoanalyze AT TIME ZONE 'Asia/Bangkok',
       n_dead_tup, autovacuum_count
FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 20;
