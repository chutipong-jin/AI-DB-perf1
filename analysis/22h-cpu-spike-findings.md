# CPU spike ~22:15 ทุกคืน: sql-cjx-pos-prod-1 (cjx-app-pos)

ข้อมูลจาก Query Insights ช่วง 21:30–23:00 (เวลาไทย) วันที่ 2026-11-05 ถึง 2026-11-11

## อาการ
- CPU peak 93.6–98.3% ทุกคืน ช่วง **22:14–22:21** และอยู่ที่ ≥80% นาน 17–31 นาที
- CPU ในช่วงนี้แทบทั้งหมดมาจาก `store_prod` (124k วินาที คิดเป็น 90%) ส่วน `payment_prod` ใช้ 13k วินาที (10%)
- แยกตาม service account: `sa-pos-api-prd` 57%, `sa-pos-sale-stream-prd` 28%, `sa-payment-api-prd` 10%, `sa-pos-stream-prd` 4%
- คืนที่หนักที่สุดคือ 11-06 (27.5k วินาที) และ 11-11 (22.1k วินาที)

ค่า "CPU est" ประมาณจาก execution_time − io_time − lock_time

## Query ที่ต้องตรวจ (เรียงตามลำดับความสำคัญ)

### P1: `12715254651768059028` ยอดขายจาก `pos_mgr.sales_performance` (31% ของ CPU)
- `store_prod` / `sa-pos-api-prd` เจอทุกวัน ใช้ 4.2k–8.0k วินาทีต่อคืน
- io เกือบเป็นศูนย์ (77 วินาที จากทั้งหมด 45.5k วินาที) แปลว่าข้อมูลอยู่ใน cache แล้ว แต่ใช้ CPU คำนวณหนัก น่าจะ scan หรือ aggregate แถวจำนวนมาก
- เงื่อนไข: `store_code = $1 AND partition_date BETWEEN LEAST(CAST($2 AS DATE), CAST($3 AS DATE)) AND GREATEST(...)`
- สิ่งที่ต้องเช็ก:
  - มี index `(store_code, partition_date)` ไหม และเป็น partitioned table หรือเปล่า
  - การตัด partition ทำงานไหม: ดู `Subplans Removed` ใน plan เพราะถ้าเป็น generic plan การใช้ LEAST/GREATEST อาจทำให้ตัด partition ตอน plan ไม่ได้
  - ช่วงวันที่ที่ส่งมากว้างแค่ไหน และ 22:00 มี job หรือหน้า dashboard ที่วนเรียก query นี้ทุกสาขาหรือเปล่า

### P1: `16617368465228759625` สรุปยอดปิดวันรายสาขา (27.4% ของ CPU)
- `store_prod` / `sa-pos-sale-stream-prd` เจอทุกวัน ใช้ 4.2k–7.6k วินาทีต่อคืน
- **คืนแถวแค่ 629 แถวใน 7 วัน แต่ใช้เวลารวม 41.6k วินาที** ตกประมาณ 66 วินาทีต่อแถว แปลว่าแต่ละครั้งที่รันหนักมาก
- ใช้ตาราง `pos_mgr.sale_transaction_report`, `agent_transaction` JOIN `sale_schedule` และ payment summary (มี `COUNT(DISTINCT)` หลายจุด)
- สิ่งที่ต้องเช็ก:
  - `sale_transaction_report` เป็น view หรือ table ถ้าเป็น view ซ้อนกันจะหนักมาก
  - มี index `(store_code, sale_schedule_date)` ไหม
  - `agent_transaction` มี index ที่ `(store_code, sale_schedule_id)` ไหม
  - น่าจะเป็นงานปิดยอดสิ้นวันที่ทุกสาขายิงพร้อมกันประมาณ 22:00 จึงควรเช็ก concurrency ฝั่ง stream consumer ด้วย

### P2: ตาราง `payment.kbank_qr_request` ค้นด้วย `partner_txn_uid` (รวม 9.6% ของ CPU)
| hash | ประเภท | exec (วินาที) | rows |
|---|---|---|---|
| `4743407899744000506` | UPDATE ... WHERE partner_txn_uid=$1 | 6,497 | 12,570 |
| `10668683393512320679` | SELECT ... WHERE partner_txn_uid=$1 | 3,445 | **0** |
| `4478209086067181327` | SELECT ... WHERE partner_txn_uid=$1 | 3,424 | **0** |
| `13655869479185519242` | SELECT * ... WHERE partner_txn_uid=$1 | 843 | 1,676 |
- เป็น lookup ด้วย key ตัวเดียว แต่ UPDATE ใช้ประมาณ 0.5 วินาทีต่อแถว และ io เป็นศูนย์ อาการแบบนี้ชี้ว่าน่าจะ **seq scan ทั้งตาราง หรือไล่ index ครบทุก partition** เพราะตารางมี `partition_date` แต่ใน WHERE ไม่มีคอลัมน์นี้
- สิ่งที่ต้องเช็ก:
  - มี index ที่ `partner_txn_uid` ในทุก partition ไหม
  - มีกี่ partition
  - ฝั่ง application ใส่ `partition_date` ใน WHERE ได้ไหม
- น่าจะแก้ได้ง่ายที่สุดและได้ผลไวที่สุด

### P2: query refill สินค้าบนชั้น (`store_assortment` + `IN (...)`) (รวม 7.4% ของ CPU)
- hash `1410696029775236298`, `3265351750015912021`, `15689969568551479235`, `204439311230135596`, `929203002090136244` และอื่น ๆ
- **เป็น query เดียวกัน** แต่ความยาวของ `IN ($2..$N)` ไม่เท่ากัน จึงได้ hash และ plan แยกกัน และต้อง plan ใหม่บ่อย
- แนะนำให้เปลี่ยนเป็น `article_no = ANY($2::text[])` และเช็ก index `store_assortment(store_id, article_no)`

### P3: query อื่นที่ควรดู
- `14894553287570445091` price tag printing (4.9%) และ `14997354786882506216` promotion tag printing (2.0%): มี io สูง (4.7k และ 4.0k วินาที) และใช้ EXISTS หลายชั้นไปที่ `stock`, `barcode`, `product` จึงควรเช็ก index `stock(article_no, store_no, location)`
- `2960380511164394620` (count) กับ `12931399946786828444` (list) refill recommendation: โครงเดียวกัน ใช้ CPU รวม 4.2%
- `8379791800053372954` focus products (2.1%)
- `7134121678547031783` และ `7783947514661753345` ดึงข้อมูล refund: query เดียวกันแต่ IN ยาวไม่เท่ากัน รวม 2.9% มี io สูง
- `17176310318861720600` sales_performance_focus_item: row_count 77.8M ใน 7 วัน ถือว่าสูงผิดปกติ
- `7153211249637256469` `get_receipt_list()`: **มีแนวโน้มโตขึ้น** จาก 23 วินาทีต่อคืน (11-05) เป็น 791 วินาทีต่อคืน (11-11) ควรเฝ้าดู

## ลำดับการตรวจบน DB
1. ช่วง 22:00–22:30 รันข้อ 1 ใน `sql/verify_22h_cpu.sql` (pg_stat_activity) เพื่อดูว่า P1 รันพร้อมกันกี่ session และมาจาก client ไหน
2. รัน `EXPLAIN (ANALYZE, BUFFERS)` กับ P1 ทั้งสองตัวและ P2 kbank ด้วยค่า parameter จริง (ควรรันบน replica)
3. เช็ก index และ partition ด้วยคำสั่งด้านล่าง

```sql
-- index ของตารางที่เกี่ยวข้อง
SELECT tablename, indexname, indexdef FROM pg_indexes
WHERE (schemaname, tablename) IN (('pos_mgr','sales_performance'),('pos_mgr','sale_transaction_report'),
      ('pos_mgr','agent_transaction'),('pos_mgr','store_assortment'),('payment','kbank_qr_request'))
   OR tablename LIKE 'kbank_qr_request%' OR tablename LIKE 'sales_performance%';

-- เป็น view / table / partitioned?
SELECT n.nspname, c.relname, c.relkind, c.reltuples::bigint
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relname IN ('sales_performance','sale_transaction_report','kbank_qr_request','agent_transaction');

-- จำนวน partition
SELECT inhparent::regclass, count(*) FROM pg_inherits
WHERE inhparent::regclass::text IN ('payment.kbank_qr_request','pos_mgr.sales_performance')
GROUP BY 1;
```
