-- EXPLAIN for end-of-day store summary (Query Insights hash 16617368465228759625,
-- pg_stat_statements queryid -4225865709950654903). PostgreSQL 15.
--
-- Step A: pick real parameter values (a busy store, last night)
SELECT ss.store_code, ss.sale_schedule_date, count(*) AS schedules
FROM pos_mgr.sale_schedule ss
WHERE ss.sale_schedule_date >= now() - interval '2 days'
GROUP BY 1, 2
ORDER BY 3 DESC
LIMIT 10;

-- Step B: column types + indexes of every table the query touches
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'pos_mgr'
  AND (table_name, column_name) IN (
    ('sale_schedule','sale_schedule_date'), ('sale_schedule','store_code'),
    ('sale_transaction_report','sale_schedule_date'), ('refund','sale_schedule_date'))
ORDER BY 1, 2;

SELECT tablename, indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'pos_mgr'
  AND tablename IN ('store','sale_transaction_report','agent_transaction','sale_schedule',
                    'receipt','receipt_payment','agent_transaction_payment','shift','refund')
ORDER BY tablename, indexname;

SELECT relname, n_live_tup, seq_scan, seq_tup_read, idx_scan,
       pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables
WHERE schemaname = 'pos_mgr'
  AND relname IN ('store','sale_transaction_report','agent_transaction','sale_schedule',
                  'receipt','receipt_payment','agent_transaction_payment','shift','refund')
ORDER BY seq_tup_read DESC;


-- Step B2: partitioning of receipt / sale_transaction_report (no partition_date in the query -> no pruning)
SELECT c.relname AS parent, pg_get_partkeydef(c.oid) AS partition_key,
       count(i.inhrelid) AS n_partitions,
       min(pg_get_expr(ch.relpartbound, ch.oid)) AS first_bound,
       max(pg_get_expr(ch.relpartbound, ch.oid)) AS last_bound
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'pos_mgr'
LEFT JOIN pg_inherits i ON i.inhparent = c.oid
LEFT JOIN pg_class ch ON ch.oid = i.inhrelid
WHERE c.relname IN ('receipt','sale_transaction_report','receipt_payment','refund',
                    'agent_transaction_payment','shift')
  AND c.relkind = 'p'
GROUP BY c.relname, c.oid;

-- Are the partitioned (ON ONLY) indexes valid on every partition?
SELECT ic.relname AS index_name, x.indisvalid
FROM pg_index x JOIN pg_class ic ON ic.oid = x.indexrelid
JOIN pg_class t ON t.oid = x.indrelid
WHERE t.relname IN ('receipt','sale_transaction_report') AND NOT x.indisvalid;

-- Real size / scan stats of the partitions (parent shows 0)
SELECT parent.relname AS parent, count(*) AS parts,
       sum(s.n_live_tup) AS live_rows, sum(s.seq_scan) AS seq_scan,
       sum(s.seq_tup_read) AS seq_tup_read, sum(s.idx_scan) AS idx_scan,
       pg_size_pretty(sum(pg_total_relation_size(s.relid))) AS size
FROM pg_inherits i
JOIN pg_class parent ON parent.oid = i.inhparent
JOIN pg_stat_user_tables s ON s.relid = i.inhrelid
WHERE parent.relname IN ('receipt','sale_transaction_report','receipt_payment','refund')
GROUP BY parent.relname;

-- Who else seq-scans sale_schedule? (659k seq scans, 21 billion rows read)
SELECT queryid, calls, round((total_exec_time/1000)::numeric) AS total_s, left(query, 200)
FROM pg_stat_statements
WHERE query ILIKE '%sale_schedule%'
ORDER BY total_exec_time DESC LIMIT 15;

-- Step C: EXPLAIN ANALYZE with literals.
-- Find/Replace before running:
--   __STORE__  -> store_code from step A          (e.g. 'S0001')
--   __SSDATE__ -> sale_schedule_date from step A   (copy the value exactly as returned)
--   __DATE__   -> the business date, 'YYYY-MM-DD'  (for the refund part)
-- Payment-type / status literals below are placeholders; they do not change the plan shape.
-- SELECT-only, safe to run; still prefer a read replica because it may take ~30 s.
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS)
WITH
store_terminate_date AS (
    SELECT s.store_code, s.name, s.terminate_date
    FROM pos_mgr.store s
    WHERE 1=1 AND s.store_code = '__STORE__'
),
receipt_summary AS (
    SELECT ssr.store_code, ssr.sale_schedule_date,
           COUNT(DISTINCT ssr.receipt_no) AS receipt_count,
           SUM(ssr.net_amount) AS total_receipt_net_amount
    FROM pos_mgr.sale_transaction_report ssr
    WHERE 1=1 AND ssr.sale_schedule_date = '__SSDATE__' AND ssr.store_code = '__STORE__'
    GROUP BY ssr.store_code, ssr.sale_schedule_date
),
agent_transaction_summary AS (
    SELECT at2.store_code, ss2.sale_schedule_date,
           COUNT(DISTINCT at2.receipt_no) AS agent_transaction_count,
           SUM(at2.total_amount) AS total_agent_transaction_net_amount
    FROM pos_mgr.agent_transaction at2
    JOIN pos_mgr.sale_schedule ss2 ON ss2.id = at2.sale_schedule_id
    WHERE 1=1 AND ss2.sale_schedule_date = '__SSDATE__' AND at2.store_code = '__STORE__'
    GROUP BY at2.store_code, ss2.sale_schedule_date
),
payment_summary AS (
    SELECT ss.store_code, ss.sale_schedule_date,
           SUM(CASE WHEN rcpm.payment_type = 'CASH' THEN (rcpm.amount - rcpm.change) ELSE 0 END) AS cash_payment_amount,
           SUM(CASE WHEN rcpm.payment_type = 'QR'   THEN (rcpm.amount - rcpm.change) ELSE 0 END) AS qr_payment_amount
    FROM pos_mgr.sale_schedule ss
    INNER JOIN pos_mgr.receipt rc ON rc.sale_schedule_id = ss.id
    LEFT JOIN pos_mgr.receipt_payment rcpm ON rcpm.receipt_no = rc.receipt_no
    WHERE 1=1 AND ss.sale_schedule_date = '__SSDATE__' AND ss.store_code = '__STORE__'
    GROUP BY ss.store_code, ss.sale_schedule_date
),
agent_transaction_payment_summary AS (
    SELECT ss.store_code, ss.sale_schedule_date,
           SUM(CASE WHEN atp.payment_type = 'CASH' THEN (atp.amount - atp.change) ELSE 0 END) AS agent_transaction_cash_payment_amount
    FROM pos_mgr.sale_schedule ss
    INNER JOIN pos_mgr.agent_transaction at3 ON at3.sale_schedule_id = ss.id
    LEFT JOIN pos_mgr.agent_transaction_payment atp ON atp.agent_transaction_id = at3.id
    WHERE 1=1 AND ss.sale_schedule_date = '__SSDATE__' AND ss.store_code = '__STORE__'
    GROUP BY ss.store_code, ss.sale_schedule_date
),
store_sale_schedule_summary AS (
    SELECT ss.store_code, ss.sale_schedule_date, ss.start_date,
           CASE WHEN (ss.end_date AT TIME ZONE 'Asia/Bangkok' < now() AT TIME ZONE 'Asia/Bangkok')
                 AND BOOL_AND(sh.status = 'CLOSED' OR sh.status IS NULL)
                 AND BOOL_AND((ss.status = 'CLOSED') OR (ss.device_is_deactivated = true))
                THEN 'CLOSED' ELSE 'OPEN' END AS status
    FROM pos_mgr.sale_schedule ss
    LEFT JOIN pos_mgr.shift sh ON sh.sale_schedule_id = ss.id
    WHERE 1=1 AND ss.sale_schedule_date = '__SSDATE__' AND ss.store_code = '__STORE__'
    GROUP BY ss.store_code, ss.sale_schedule_date, ss.end_date, ss.start_date
),
refund AS (
    SELECT rf.store_code,
           CAST(DATE_TRUNC('day', rf.sale_schedule_date AT TIME ZONE 'Asia/Bangkok') AS DATE) AS sale_schedule_date,
           COUNT(DISTINCT rf.refund_no) AS no_of_refund,
           SUM(rf.original_net_amount) AS original_net_amount,
           SUM(rf.exceptional_refund_amount) AS exceptional_refund_amount
    FROM pos_mgr.refund rf
    WHERE 1=1
      AND CAST(DATE_TRUNC('day', rf.sale_schedule_date AT TIME ZONE 'Asia/Bangkok') AS DATE) = '__DATE__'
      AND rf.store_code = '__STORE__'
    GROUP BY rf.store_code, CAST(DATE_TRUNC('day', rf.sale_schedule_date AT TIME ZONE 'Asia/Bangkok') AS DATE)
)
SELECT ssss.sale_schedule_date, std.store_code, std.name,
       rcs.receipt_count, rcs.total_receipt_net_amount,
       pms.cash_payment_amount, pms.qr_payment_amount,
       rf.original_net_amount, rf.no_of_refund,
       ats.agent_transaction_count, atps.agent_transaction_cash_payment_amount,
       ssss.status
FROM store_sale_schedule_summary ssss
INNER JOIN store_terminate_date std ON ssss.store_code = std.store_code
     AND ((std.terminate_date IS NULL) OR (ssss.start_date AT TIME ZONE 'Asia/Bangkok' <= std.terminate_date AT TIME ZONE 'Asia/Bangkok'))
LEFT JOIN receipt_summary rcs ON ssss.store_code = rcs.store_code AND ssss.sale_schedule_date = rcs.sale_schedule_date
LEFT JOIN payment_summary pms ON ssss.store_code = pms.store_code AND ssss.sale_schedule_date = pms.sale_schedule_date
LEFT JOIN agent_transaction_summary ats ON ssss.store_code = ats.store_code AND ssss.sale_schedule_date = ats.sale_schedule_date
LEFT JOIN agent_transaction_payment_summary atps ON ssss.store_code = atps.store_code AND ssss.sale_schedule_date = atps.sale_schedule_date
LEFT JOIN refund rf ON rf.store_code = rcs.store_code AND rf.sale_schedule_date = rcs.sale_schedule_date
ORDER BY ssss.sale_schedule_date, std.store_code;
