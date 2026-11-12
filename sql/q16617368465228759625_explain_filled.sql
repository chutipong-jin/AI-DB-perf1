-- End-of-day store summary (pg_stat_statements queryid -4225865709950654903)
-- PostgreSQL 15. Everything in PART 1 is SAFE on production: plain EXPLAIN does not execute the query.
-- Run all statements in ONE session (pgAdmin Query Tool: same tab), top to bottom.
--
-- Bind parameters $1..$13 (from the app) = store_code / sale_schedule_date / refund date.
-- Everything else ($14..$99 in pg_stat_statements) were literals normalized away; filled with
-- representative values below (payment_type / status strings do not change the plan shape).

------------------------------------------------------------------------------------------
-- PART 1: plan only, no execution
------------------------------------------------------------------------------------------
DEALLOCATE ALL;

PREPARE eod_summary(varchar, date, varchar, date, varchar, date, varchar,
                    date, varchar, date, varchar, date, varchar) AS
WITH
store_terminate_date AS (
    SELECT s.store_code, s.name, s.terminate_date
    FROM pos_mgr.store s
    WHERE 1=1 AND s.store_code = $1
),
receipt_summary AS (
    SELECT ssr.store_code, ssr.sale_schedule_date,
           COUNT(DISTINCT ssr.receipt_no) AS receipt_count,
           SUM(ssr.net_amount) AS total_receipt_net_amount
    FROM pos_mgr.sale_transaction_report ssr
    WHERE 1=1 AND ssr.sale_schedule_date = $2 AND ssr.store_code = $3
    GROUP BY ssr.store_code, ssr.sale_schedule_date
),
agent_transaction_summary AS (
    SELECT at2.store_code, ss2.sale_schedule_date,
           COUNT(DISTINCT at2.receipt_no) AS agent_transaction_count,
           SUM(at2.total_amount) AS total_agent_transaction_net_amount
    FROM pos_mgr.agent_transaction at2
    JOIN pos_mgr.sale_schedule ss2 ON ss2.id = at2.sale_schedule_id
    WHERE 1=1 AND ss2.sale_schedule_date = $4 AND at2.store_code = $5
    GROUP BY at2.store_code, ss2.sale_schedule_date
),
payment_summary AS (
    SELECT ss.store_code, ss.sale_schedule_date,
           SUM(CASE WHEN rcpm.payment_type = 'CASH'            THEN (rcpm.amount - rcpm.change) ELSE 0 END) AS cash_payment_amount,
           SUM(CASE WHEN rcpm.payment_type = 'QR'              THEN (rcpm.amount - rcpm.change) ELSE 0 END) AS qr_payment_amount,
           SUM(CASE WHEN rcpm.payment_type = 'POINT'           THEN (rcpm.amount - rcpm.change) ELSE 0 END) AS cash_point_payment_amount,
           SUM(CASE WHEN rcpm.payment_type = 'WELFARE'         THEN (rcpm.amount - rcpm.change) ELSE 0 END) AS gov_welfare_payment_amount,
           SUM(CASE WHEN rcpm.payment_type = 'EDC'             THEN (rcpm.amount - rcpm.change) ELSE 0 END) AS edc_payment_amount,
           SUM(CASE WHEN rcpm.payment_type = 'ONLINE_DELIVERY' THEN (rcpm.amount - rcpm.change) ELSE 0 END) AS online_delivery_payment_amount,
           SUM(CASE WHEN rcpm.payment_type = 'KBAO'            THEN (rcpm.amount - rcpm.change) ELSE 0 END) AS kbao_installment_payment_amount
    FROM pos_mgr.sale_schedule ss
    INNER JOIN pos_mgr.receipt rc ON rc.sale_schedule_id = ss.id
    LEFT JOIN pos_mgr.receipt_payment rcpm ON rcpm.receipt_no = rc.receipt_no
    WHERE 1=1 AND ss.sale_schedule_date = $6 AND ss.store_code = $7
    GROUP BY ss.store_code, ss.sale_schedule_date
),
agent_transaction_payment_summary AS (
    SELECT ss.store_code, ss.sale_schedule_date,
           SUM(CASE WHEN atp.payment_type = 'CASH' THEN (atp.amount - atp.change) ELSE 0 END) AS agent_transaction_cash_payment_amount,
           SUM(CASE WHEN atp.payment_type = 'QR'   THEN (atp.amount - atp.change) ELSE 0 END) AS agent_transaction_qr_payment_amount,
           SUM(CASE WHEN atp.payment_type = 'KBAO' THEN (atp.amount - atp.change) ELSE 0 END) AS agent_transaction_kbao_credit_payment_amount
    FROM pos_mgr.sale_schedule ss
    INNER JOIN pos_mgr.agent_transaction at3 ON at3.sale_schedule_id = ss.id
    LEFT JOIN pos_mgr.agent_transaction_payment atp ON atp.agent_transaction_id = at3.id
    WHERE 1=1 AND ss.sale_schedule_date = $8 AND ss.store_code = $9
    GROUP BY ss.store_code, ss.sale_schedule_date
),
store_sale_schedule_summary AS (
    SELECT ss.store_code, ss.sale_schedule_date, ss.start_date,
           CASE WHEN (CASE WHEN ss.end_date AT TIME ZONE 'Asia/Bangkok' < now() AT TIME ZONE 'Asia/Bangkok' THEN true ELSE false END)
                 AND BOOL_AND(CASE WHEN sh.status = 'CLOSED' OR sh.status IS NULL THEN true ELSE false END)
                 AND BOOL_AND((ss.status = 'CLOSED') OR (ss.device_is_deactivated = true))
                THEN 'CLOSED' ELSE 'OPEN' END AS status
    FROM pos_mgr.sale_schedule ss
    LEFT JOIN pos_mgr.shift sh ON sh.sale_schedule_id = ss.id
    WHERE 1=1 AND ss.sale_schedule_date = $10 AND ss.store_code = $11
    GROUP BY ss.store_code, ss.sale_schedule_date, ss.end_date, ss.start_date
),
refund AS (
    SELECT rf.store_code,
           CAST(DATE_TRUNC('day', rf.sale_schedule_date AT TIME ZONE 'Asia/Bangkok') AS DATE) AS sale_schedule_date,
           COUNT(DISTINCT rf.refund_no) AS no_of_refund,
           SUM(rf.original_net_amount) AS original_net_amount,
           SUM(rf.original_pay_by_point_amount_in_thb) AS original_pay_by_point_amount_in_thb,
           SUM(rf.exceptional_refund_amount) AS exceptional_refund_amount
    FROM pos_mgr.refund rf
    WHERE 1=1
      AND CAST(DATE_TRUNC('day', rf.sale_schedule_date AT TIME ZONE 'Asia/Bangkok') AS DATE) = $12
      AND rf.store_code = $13
    GROUP BY rf.store_code, CAST(DATE_TRUNC('day', rf.sale_schedule_date AT TIME ZONE 'Asia/Bangkok') AS DATE)
)
SELECT TO_CHAR(ssss.sale_schedule_date AT TIME ZONE 'Asia/Bangkok', 'YYYY-MM-DD') AS sale_schedule_date,
       std.store_code, std.name AS store_name,
       COALESCE(rcs.receipt_count, 0) AS no_of_receipt,
       COALESCE(rcs.total_receipt_net_amount, 0) AS net_sales_amount_inc_vat,
       COALESCE(pms.cash_payment_amount, 0), COALESCE(pms.qr_payment_amount, 0),
       COALESCE(pms.cash_point_payment_amount, 0), COALESCE(pms.gov_welfare_payment_amount, 0),
       COALESCE(pms.edc_payment_amount, 0), COALESCE(pms.online_delivery_payment_amount, 0),
       COALESCE(pms.kbao_installment_payment_amount, 0),
       COALESCE(rf.original_net_amount, 0), COALESCE(rf.no_of_refund, 0),
       COALESCE(ats.agent_transaction_count, 0), COALESCE(ats.total_agent_transaction_net_amount, 0),
       COALESCE(atps.agent_transaction_cash_payment_amount, 0),
       ssss.status
FROM store_sale_schedule_summary ssss
INNER JOIN store_terminate_date std ON ssss.store_code = std.store_code
     AND ((std.terminate_date IS NULL) OR (ssss.start_date AT TIME ZONE 'Asia/Bangkok' <= std.terminate_date AT TIME ZONE 'Asia/Bangkok'))
LEFT JOIN receipt_summary rcs ON ssss.store_code = rcs.store_code AND ssss.sale_schedule_date = rcs.sale_schedule_date
LEFT JOIN payment_summary pms ON ssss.store_code = pms.store_code AND ssss.sale_schedule_date = pms.sale_schedule_date
LEFT JOIN agent_transaction_summary ats ON ssss.store_code = ats.store_code AND ssss.sale_schedule_date = ats.sale_schedule_date
LEFT JOIN agent_transaction_payment_summary atps ON ssss.store_code = atps.store_code AND ssss.sale_schedule_date = atps.sale_schedule_date
LEFT JOIN refund rf ON rf.store_code = rcs.store_code AND rf.sale_schedule_date = rcs.sale_schedule_date
ORDER BY ssss.sale_schedule_date ASC, std.store_code ASC;

-- 1a) custom plan (planner sees the real values) -- NOT executed
SET plan_cache_mode = force_custom_plan;
EXPLAIN (COSTS, SETTINGS)
EXECUTE eod_summary('CJX00142','2026-11-12','CJX00142','2026-11-12','CJX00142','2026-11-12','CJX00142',
                    '2026-11-12','CJX00142','2026-11-12','CJX00142','2026-11-12','CJX00142');

-- 1b) generic plan (what JDBC may get after 5 executions) -- NOT executed
SET plan_cache_mode = force_generic_plan;
EXPLAIN (COSTS, SETTINGS)
EXECUTE eod_summary('CJX00142','2026-11-12','CJX00142','2026-11-12','CJX00142','2026-11-12','CJX00142',
                    '2026-11-12','CJX00142','2026-11-12','CJX00142','2026-11-12','CJX00142');

RESET plan_cache_mode;

------------------------------------------------------------------------------------------
-- PART 2: is receipt_payment.partition_date always = receipt.partition_date?
--         (needed before rewriting the join). Read-only, touches one month partition.
------------------------------------------------------------------------------------------
SELECT count(*) AS payments,
       count(*) FILTER (WHERE rp.partition_date <> rc.partition_date) AS diff_partition,
       count(*) FILTER (WHERE rp.store_no <> rc.store_no)             AS diff_store
FROM pos_mgr.receipt rc
JOIN pos_mgr.receipt_payment rp ON rp.receipt_no = rc.receipt_no
WHERE rc.partition_date = DATE '2026-11-12' AND rc.store_code = 'CJX00142'
  AND rp.partition_date BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';

-- receipt.partition_date vs sale_schedule.sale_schedule_date (receipts after midnight?)
SELECT ss.sale_schedule_date, rc.partition_date, count(*)
FROM pos_mgr.sale_schedule ss
JOIN pos_mgr.receipt rc ON rc.sale_schedule_id = ss.id
     AND rc.partition_date BETWEEN DATE '2026-11-11' AND DATE '2026-11-13'
WHERE ss.sale_schedule_date = DATE '2026-11-12'
GROUP BY 1, 2 ORDER BY 1, 2;

------------------------------------------------------------------------------------------
-- PART 3 (optional): measure only the suspect CTE with ANALYZE.
-- SELECT-only (no writes) but it DOES execute (~same cost as one app call, which already runs
-- ~190x every night). Prefer read replica / daytime.
------------------------------------------------------------------------------------------
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT ss.store_code, ss.sale_schedule_date, SUM(rcpm.amount - rcpm.change)
-- FROM pos_mgr.sale_schedule ss
-- INNER JOIN pos_mgr.receipt rc ON rc.sale_schedule_id = ss.id
-- LEFT JOIN pos_mgr.receipt_payment rcpm ON rcpm.receipt_no = rc.receipt_no
-- WHERE ss.sale_schedule_date = DATE '2026-11-12' AND ss.store_code = 'CJX00142'
-- GROUP BY 1, 2;

DEALLOCATE eod_summary;
