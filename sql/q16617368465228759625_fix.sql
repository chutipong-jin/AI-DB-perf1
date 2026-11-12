-- Fix for end-of-day store summary (pg_stat_statements queryid -4225865709950654903)
-- Root cause (confirmed by EXPLAIN, custom AND generic plan identical):
--   payment_summary: LEFT JOIN receipt_payment rcpm ON rcpm.receipt_no = rc.receipt_no
--   -> no index on receipt_payment(receipt_no), no partition_date
--   -> Parallel Seq Scan of ALL 36 receipt_payment partitions (~19.5M rows) + hash build, every call (~31 s)

------------------------------------------------------------------------------------------
-- STEP 0: validate assumptions over a longer period (read-only)
--   expect 0 / 0. If not 0, use the BETWEEN variant in option A.
------------------------------------------------------------------------------------------
SELECT count(*) AS receipts,
       count(*) FILTER (WHERE rc.partition_date <> ss.sale_schedule_date) AS receipt_date_ne_schedule_date
FROM pos_mgr.sale_schedule ss
JOIN pos_mgr.receipt rc ON rc.sale_schedule_id = ss.id
     AND rc.partition_date BETWEEN DATE '2026-10-01' - 1 AND DATE '2026-11-12' + 1
WHERE ss.sale_schedule_date BETWEEN DATE '2026-10-01' AND DATE '2026-11-12';

SELECT count(*) AS payments,
       count(*) FILTER (WHERE rp.partition_date <> rc.partition_date OR rp.store_no <> rc.store_no) AS mismatched
FROM pos_mgr.receipt rc
JOIN pos_mgr.receipt_payment rp ON rp.receipt_no = rc.receipt_no
     AND rp.partition_date BETWEEN DATE '2026-10-01' AND DATE '2026-11-30'
WHERE rc.partition_date BETWEEN DATE '2026-11-01' AND DATE '2026-11-12';

------------------------------------------------------------------------------------------
-- OPTION A (recommended, app change): join on the full key + filter receipt partition
--   Replace the payment_summary CTE in the app with:
------------------------------------------------------------------------------------------
/*
payment_summary AS (
    SELECT ss.store_code, ss.sale_schedule_date,
           SUM(CASE WHEN rcpm.payment_type = ... END) AS cash_payment_amount,
           ... (unchanged)
    FROM pos_mgr.sale_schedule ss
    INNER JOIN pos_mgr.receipt rc
            ON rc.sale_schedule_id = ss.id
           AND rc.partition_date BETWEEN :saleScheduleDate AND :saleScheduleDate + 1   -- NEW
           -- receipts right after midnight (end of schedule) land in partition_date = date + 1,
           -- e.g. RC26-CJX00112P04-030771 created 00:00:05 ICT for schedule 2026-11-11
    LEFT JOIN pos_mgr.receipt_payment rcpm
           ON rcpm.partition_date = rc.partition_date                                 -- NEW
          AND rcpm.store_no       = rc.store_no                                       -- NEW
          AND rcpm.receipt_no     = rc.receipt_no                                     -- uses existing index
          AND rcpm.partition_date BETWEEN :saleScheduleDate AND :saleScheduleDate + 1 -- NEW (optional: plan-time pruning)
    -- note: if :saleScheduleDate is bound as varchar/timestamp, use CAST(:saleScheduleDate AS date) + 1
    WHERE ss.sale_schedule_date = :saleScheduleDate AND ss.store_code = :storeCode
    GROUP BY ss.store_code, ss.sale_schedule_date
),
*/

-- Which receipt(s) have partition_date <> sale_schedule_date?
SELECT ss.store_code, ss.sale_schedule_date, ss.start_date, ss.end_date,
       rc.partition_date, rc.receipt_no, rc.receipt_date, rc.created_date
FROM pos_mgr.sale_schedule ss
JOIN pos_mgr.receipt rc ON rc.sale_schedule_id = ss.id
     AND rc.partition_date BETWEEN DATE '2026-09-29' AND DATE '2026-11-13'
WHERE ss.sale_schedule_date BETWEEN DATE '2026-10-01' AND DATE '2026-11-12'
  AND rc.partition_date <> ss.sale_schedule_date;

-- Test of option A (plain EXPLAIN = safe; EXPLAIN ANALYZE should now take milliseconds)
EXPLAIN (ANALYZE, BUFFERS)
SELECT ss.store_code, ss.sale_schedule_date, count(*), SUM(rcpm.amount - rcpm.change)
FROM pos_mgr.sale_schedule ss
INNER JOIN pos_mgr.receipt rc
        ON rc.sale_schedule_id = ss.id
       AND rc.partition_date BETWEEN DATE '2026-11-12' - 1 AND DATE '2026-11-12' + 1
LEFT JOIN pos_mgr.receipt_payment rcpm
       ON rcpm.partition_date = rc.partition_date
      AND rcpm.store_no = rc.store_no
      AND rcpm.receipt_no = rc.receipt_no
WHERE ss.sale_schedule_date = DATE '2026-11-12' AND ss.store_code = 'CJX00142'
GROUP BY 1, 2;

-- Result must equal the old join (compare numbers; old version is the slow one, run off-peak/replica)
-- SELECT ss.store_code, count(*), SUM(rcpm.amount - rcpm.change)
-- FROM pos_mgr.sale_schedule ss
-- JOIN pos_mgr.receipt rc ON rc.sale_schedule_id = ss.id
-- LEFT JOIN pos_mgr.receipt_payment rcpm ON rcpm.receipt_no = rc.receipt_no
-- WHERE ss.sale_schedule_date = DATE '2026-11-12' AND ss.store_code = 'CJX00142'
-- GROUP BY 1;

------------------------------------------------------------------------------------------
-- OPTION B (stop-gap, no app deploy): index receipt_payment(receipt_no)
--   Partitioned table: create on parent ONLY (invalid), build each partition CONCURRENTLY,
--   attach -> parent becomes valid automatically. New partitions later inherit it.
--   CONCURRENTLY cannot run inside a transaction: run statements one by one (autocommit on).
------------------------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_receipt_payment_receipt_no
    ON ONLY pos_mgr.receipt_payment (receipt_no);

-- generate the per-partition statements, copy the output and run it
SELECT format('CREATE INDEX CONCURRENTLY IF NOT EXISTS %I ON pos_mgr.%I (receipt_no);',
              c.relname || '_receipt_no_idx', c.relname) AS create_stmt,
       format('ALTER INDEX pos_mgr.idx_receipt_payment_receipt_no ATTACH PARTITION pos_mgr.%I;',
              c.relname || '_receipt_no_idx') AS attach_stmt
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
WHERE i.inhparent = 'pos_mgr.receipt_payment'::regclass
ORDER BY c.relname;

-- verify: valid = true, and index sizes
SELECT x.indisvalid, pg_size_pretty(pg_relation_size(x.indexrelid))
FROM pg_index x WHERE x.indexrelid = 'pos_mgr.idx_receipt_payment_receipt_no'::regclass;

------------------------------------------------------------------------------------------
-- Secondary (smaller) items
------------------------------------------------------------------------------------------
-- refund CTE: seq scan of whole refund table (69k rows) every call.
--   rewrite the filter as a range (sargable):
--     rf.sale_schedule_date >= (:date::timestamp AT TIME ZONE 'Asia/Bangkok')
--     AND rf.sale_schedule_date < ((:date + 1)::timestamp AT TIME ZONE 'Asia/Bangkok')
--   and add:
-- CREATE INDEX CONCURRENTLY idx_refund_store_code_ss_date ON pos_mgr.refund (store_code, sale_schedule_date);
--
-- receipt_summary CTE: probes 24 sale_transaction_report partitions; if
--   sale_transaction_report.partition_date = sale_schedule_date (check like STEP 0),
--   add "AND ssr.partition_date = :saleScheduleDate".
--
-- Correctness (not CPU): final "LEFT JOIN refund rf ON rf.store_code = rcs.store_code ..."
--   joins to receipt_summary instead of ssss -> refunds disappear when a store has no receipts.
