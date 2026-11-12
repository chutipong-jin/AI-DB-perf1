-- Investigation: Query Insights hash 16617368465228759625
-- store_prod / sa-pos-sale-stream-prd : end-of-day summary per store (~22:00)
-- ~90 executions/night, ~60 s each, CPU-bound (io ~5%, lock ~5%)

-- 1) Get the FULL query text (Query Insights truncates at 1024 chars)
SELECT queryid, calls, round((total_exec_time/1000)::numeric) AS total_s,
       round((mean_exec_time/1000)::numeric, 1) AS mean_s, round((max_exec_time/1000)::numeric, 1) AS max_s,
       rows, shared_blks_hit, shared_blks_read, temp_blks_written, query
FROM pg_stat_statements
WHERE query LIKE 'WITH store_terminate_date AS%'
ORDER BY total_exec_time DESC;

-- 2) Table types and sizes
SELECT n.nspname, c.relname, c.relkind, c.reltuples::bigint AS est_rows,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS size
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'pos_mgr'
  AND c.relname IN ('store','sale_transaction_report','agent_transaction','sale_schedule',
                    'receipt','receipt_payment_method')   -- adjust to the tables in the full query
ORDER BY c.relname;

-- 3) Existing indexes on those tables
SELECT tablename, indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'pos_mgr'
  AND tablename IN ('sale_transaction_report','agent_transaction','sale_schedule',
                    'receipt','receipt_payment_method')
ORDER BY tablename, indexname;

-- 4) Seq-scan pressure on those tables
SELECT relname, seq_scan, seq_tup_read, idx_scan, n_live_tup,
       round(seq_tup_read::numeric / nullif(seq_scan, 0)) AS avg_rows_per_seqscan,
       last_autoanalyze AT TIME ZONE 'Asia/Bangkok' AS last_autoanalyze_ict
FROM pg_stat_user_tables
WHERE schemaname = 'pos_mgr'
  AND relname IN ('sale_transaction_report','agent_transaction','sale_schedule',
                  'receipt','receipt_payment_method');

-- 5) Plan with real params (one store, one day). Run on a replica if possible.
--    Paste the full text from step 1, replace $n with real values.
--    a) custom plan (literal values):
-- EXPLAIN (ANALYZE, BUFFERS, SETTINGS) <full query with literals>;
--
--    b) generic plan (what JDBC gets after 5 executions of a prepared statement):
-- SET plan_cache_mode = force_generic_plan;
-- PREPARE q(...) AS <full query with $n>;
-- EXPLAIN (ANALYZE, BUFFERS) EXECUTE q(...);
-- RESET plan_cache_mode; DEALLOCATE q;
--
--    If (b) is much slower than (a) -> generic-plan problem; fix with
--    prepareThreshold=0 for this statement / plan_cache_mode=force_custom_plan for this role.

-- 6) Concurrency at 22:00-22:30: how many run at the same time?
SELECT count(*) AS running, min(query_start) AS oldest,
       max(now() - query_start) AS longest
FROM pg_stat_activity
WHERE usename = 'sa-pos-sale-stream-prd@cjx-app-pos.iam'
  AND state = 'active' AND query LIKE 'WITH store_terminate_date AS%';
