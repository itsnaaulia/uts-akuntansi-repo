-- =====================================================================
-- Uji otomatis seluruh skema. Jalankan setelah 01, 02, 03:
--   psql -d <db> -v ON_ERROR_STOP=1 -f sql/99_tests.sql
-- Setiap uji mencetak PASS / FAIL.
-- =====================================================================
\set QUIET on
\o /dev/null
SET client_min_messages = warning;

CREATE TEMP TABLE t_result (name TEXT, ok BOOLEAN, detail TEXT);

-- helper: jalankan SQL, harapkan GAGAL dengan SQLSTATE tertentu (atau apapun jika NULL)
CREATE FUNCTION pg_temp.expect_fail(p_name TEXT, p_sql TEXT, p_state TEXT DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
        INSERT INTO t_result VALUES (p_name, false, 'seharusnya ditolak, tetapi berhasil');
    EXCEPTION WHEN OTHERS THEN
        IF p_state IS NULL OR SQLSTATE = p_state THEN
            INSERT INTO t_result VALUES (p_name, true, SQLSTATE || ': ' || left(SQLERRM, 90));
        ELSE
            INSERT INTO t_result VALUES (p_name, false, 'SQLSTATE salah ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;
END $$;

CREATE FUNCTION pg_temp.expect_true(p_name TEXT, p_cond BOOLEAN, p_detail TEXT DEFAULT '') RETURNS void
LANGUAGE sql AS $$ INSERT INTO t_result VALUES (p_name, COALESCE(p_cond, false), p_detail) $$;

-- ===================== SOAL 1: constraint =====================
SELECT set_config('app.user', 'tester', false);
INSERT INTO journal_headers (trx_date, ref_no, description) VALUES ('2026-10-01', 'T-001', 'uji constraint');

SELECT pg_temp.expect_fail('1.2 debit negatif ditolak',
  $q$INSERT INTO journal_lines (header_id, account_id, debit, credit)
     SELECT header_id, 1, -5, 0 FROM journal_headers WHERE ref_no='T-001'$q$, '23514');
SELECT pg_temp.expect_fail('1.2 kredit negatif ditolak',
  $q$INSERT INTO journal_lines (header_id, account_id, debit, credit)
     SELECT header_id, 1, 0, -5 FROM journal_headers WHERE ref_no='T-001'$q$, '23514');
SELECT pg_temp.expect_fail('1.2 debit=0 & kredit=0 ditolak',
  $q$INSERT INTO journal_lines (header_id, account_id, debit, credit)
     SELECT header_id, 1, 0, 0 FROM journal_headers WHERE ref_no='T-001'$q$, '23514');
SELECT pg_temp.expect_fail('1.2 FK akun tidak ada ditolak',
  $q$INSERT INTO journal_lines (header_id, account_id, debit, credit)
     SELECT header_id, 99999, 10, 0 FROM journal_headers WHERE ref_no='T-001'$q$, '23503');
SELECT pg_temp.expect_fail('1.2 debit & kredit sekaligus >0 ditolak (penguatan)',
  $q$INSERT INTO journal_lines (header_id, account_id, debit, credit)
     SELECT header_id, 1, 10, 10 FROM journal_headers WHERE ref_no='T-001'$q$, '23514');
SELECT pg_temp.expect_fail('1.2 status posting ilegal ditolak',
  $q$INSERT INTO journal_headers (trx_date, ref_no, description, posting_status) VALUES ('2026-10-01','T-X','x','FOO')$q$, '23514');

-- ===================== Asas berpasangan =====================
-- Jurnal tidak seimbang tidak bisa diposting
INSERT INTO journal_headers (trx_date, ref_no, description) VALUES ('2026-10-02', 'T-002', 'tidak seimbang');
INSERT INTO journal_lines (header_id, account_id, debit, credit)
SELECT h.header_id, a.account_id, 100, 0 FROM journal_headers h, chart_of_accounts a WHERE h.ref_no='T-002' AND a.account_code='6101';
INSERT INTO journal_lines (header_id, account_id, debit, credit)
SELECT h.header_id, a.account_id, 0, 90 FROM journal_headers h, chart_of_accounts a WHERE h.ref_no='T-002' AND a.account_code='1101';
SELECT pg_temp.expect_fail('3.x posting jurnal tidak seimbang ditolak',
  $q$UPDATE journal_headers SET posting_status='POSTED' WHERE ref_no='T-002'$q$, '23514');
SELECT pg_temp.expect_fail('3.x header langsung POSTED ditolak (bypass API)',
  $q$INSERT INTO journal_headers (trx_date, ref_no, description, posting_status) VALUES ('2026-10-02','T-003','x','POSTED')$q$, '23514');
-- Jurnal 1 baris tidak bisa diposting
INSERT INTO journal_headers (trx_date, ref_no, description) VALUES ('2026-10-02', 'T-004', 'satu baris');
INSERT INTO journal_lines (header_id, account_id, debit, credit)
SELECT h.header_id, a.account_id, 100, 0 FROM journal_headers h, chart_of_accounts a WHERE h.ref_no='T-004' AND a.account_code='6101';
SELECT pg_temp.expect_fail('3.x posting jurnal 1 baris ditolak',
  $q$UPDATE journal_headers SET posting_status='POSTED' WHERE ref_no='T-004'$q$, '23514');

-- Koreksi lalu posting jurnal seimbang
UPDATE journal_lines SET credit = 100 WHERE header_id = (SELECT header_id FROM journal_headers WHERE ref_no='T-002') AND credit = 90;
UPDATE journal_headers SET posting_status='POSTED' WHERE ref_no='T-002';
SELECT pg_temp.expect_true('3.2 jurnal seimbang berhasil POSTED + checksum 64 hex',
  (SELECT posting_status='POSTED' AND length(hash_checksum)=64 AND posted_by='tester' AND created_by='tester'
     FROM journal_headers WHERE ref_no='T-002'));

-- ===================== SOAL 3.2: immutability =====================
SELECT pg_temp.expect_fail('3.2 UPDATE header POSTED ditolak',
  $q$UPDATE journal_headers SET description='diubah' WHERE ref_no='T-002'$q$, '23001');
SELECT pg_temp.expect_fail('3.2 DELETE header POSTED ditolak',
  $q$DELETE FROM journal_headers WHERE ref_no='T-002'$q$, '23001');
SELECT pg_temp.expect_fail('3.2 UPDATE baris milik POSTED ditolak',
  $q$UPDATE journal_lines SET debit=1, credit=0 WHERE header_id=(SELECT header_id FROM journal_headers WHERE ref_no='T-002') AND debit>0$q$, '23001');
SELECT pg_temp.expect_fail('3.2 DELETE baris milik POSTED ditolak',
  $q$DELETE FROM journal_lines WHERE header_id=(SELECT header_id FROM journal_headers WHERE ref_no='T-002')$q$, '23001');
SELECT pg_temp.expect_fail('3.2 INSERT baris ke header POSTED ditolak',
  $q$INSERT INTO journal_lines (header_id, account_id, debit, credit)
     SELECT h.header_id, a.account_id, 5, 0 FROM journal_headers h, chart_of_accounts a WHERE h.ref_no='T-002' AND a.account_code='6101'$q$, '23001');
SELECT pg_temp.expect_fail('3.2 TRUNCATE journal_lines ditolak', $q$TRUNCATE journal_lines$q$, '23001');
SELECT pg_temp.expect_fail('3.2 UPDATE audit_log ditolak', $q$UPDATE audit_log SET changed_by='x'$q$, '23001');
SELECT pg_temp.expect_fail('3.2 DELETE audit_log ditolak', $q$DELETE FROM audit_log$q$, '23001');
SELECT pg_temp.expect_fail('3.2 pemalsuan hash lewat UPDATE ditolak',
  $q$UPDATE journal_headers SET hash_checksum=repeat('0',64) WHERE ref_no='T-002'$q$, '23001');

-- Klien tidak bisa memalsukan created_by/created_at saat INSERT
INSERT INTO journal_headers (trx_date, ref_no, description, created_by, created_at)
VALUES ('2026-10-03', 'T-005', 'coba palsukan', 'penyusup', '2000-01-01');
SELECT pg_temp.expect_true('3.2 created_by/created_at tidak bisa dipalsukan',
  (SELECT created_by='tester' AND created_at > now() - interval '1 minute' FROM journal_headers WHERE ref_no='T-005'));

-- Jurnal pembalik
SELECT fn_reverse_journal((SELECT header_id FROM journal_headers WHERE ref_no='T-002'), 'salah akun', '2026-10-05') AS rev_id \gset
SELECT pg_temp.expect_true('3.2 jurnal pembalik terbentuk & POSTED',
  (SELECT h.posting_status='POSTED' AND h.reverses_header_id=(SELECT header_id FROM journal_headers WHERE ref_no='T-002')
     FROM journal_headers h WHERE h.header_id = :rev_id));
SELECT pg_temp.expect_true('3.2 pembalik menukar debit/kredit (net = 0 per akun)',
  (SELECT bool_and(net = 0) FROM (
      SELECT account_id, sum(debit - credit) AS net FROM journal_lines
       WHERE header_id IN (SELECT header_id FROM journal_headers WHERE ref_no IN ('T-002','REV-T-002'))
       GROUP BY account_id) s));
SELECT pg_temp.expect_fail('3.2 membalik dua kali ditolak',
  $q$SELECT fn_reverse_journal((SELECT header_id FROM journal_headers WHERE ref_no='T-002'), 'lagi')$q$);
SELECT pg_temp.expect_fail('3.2 membalik jurnal DRAFT ditolak',
  $q$SELECT fn_reverse_journal((SELECT header_id FROM journal_headers WHERE ref_no='T-004'), 'x')$q$);

-- Deteksi manipulasi (superuser menonaktifkan trigger lalu mengubah data)
ALTER TABLE journal_lines DISABLE TRIGGER trg_jl_guard;
UPDATE journal_lines SET debit = 999 WHERE header_id = (SELECT header_id FROM journal_headers WHERE ref_no='T-002') AND debit > 0;
SELECT pg_temp.expect_true('3.2 checksum mendeteksi manipulasi di luar aplikasi',
  (SELECT NOT is_intact FROM v_journal_integrity WHERE ref_no='T-002'));
SELECT pg_temp.expect_true('3.2 jurnal lain tetap utuh',
  (SELECT bool_and(is_intact) FROM v_journal_integrity WHERE ref_no <> 'T-002'));
UPDATE journal_lines SET debit = 100 WHERE header_id = (SELECT header_id FROM journal_headers WHERE ref_no='T-002') AND debit = 999;
ALTER TABLE journal_lines ENABLE TRIGGER trg_jl_guard;

-- ===================== SOAL 2: persediaan =====================
INSERT INTO inventory_items (item_id, item_name, stock_qty, unit_cost) VALUES ('BRG-001', 'Laptop Dell', 0, 10000000.00);
SELECT pg_temp.expect_fail('2.x stok awal != 0 ditolak',
  $q$INSERT INTO inventory_items VALUES ('BRG-X','x',5,1)$q$, '23514');

INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001', 'PURCHASE', 10);
SELECT pg_temp.expect_true('2.1a PURCHASE 10 -> stok 10',
  (SELECT stock_qty = 10 FROM inventory_items WHERE item_id='BRG-001'));
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001', 'SALE', 4);
SELECT pg_temp.expect_true('2.1a SALE 4 -> stok 6',
  (SELECT stock_qty = 6 FROM inventory_items WHERE item_id='BRG-001'));
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001', 'ADJUSTMENT', -1);
SELECT pg_temp.expect_true('2.1a ADJUSTMENT -1 -> stok 5',
  (SELECT stock_qty = 5 FROM inventory_items WHERE item_id='BRG-001'));

SELECT pg_temp.expect_fail('2.1b SALE melebihi stok ditolak (RAISE EXCEPTION)',
  $q$INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001','SALE',6)$q$, '23514');
SELECT pg_temp.expect_true('2.1b stok & log tetap utuh setelah penolakan',
  (SELECT i.stock_qty = 5 AND (SELECT count(*) FROM inventory_transactions)=3 FROM inventory_items i WHERE item_id='BRG-001'));
SELECT pg_temp.expect_fail('2.x qty SALE negatif ditolak',
  $q$INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001','SALE',-2)$q$, '23514');
SELECT pg_temp.expect_fail('2.x barang tidak dikenal ditolak',
  $q$INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('NOPE','SALE',1)$q$);
SELECT pg_temp.expect_fail('2.x ubah stock_qty langsung ditolak',
  $q$UPDATE inventory_items SET stock_qty = 999 WHERE item_id='BRG-001'$q$, '23001');
SELECT pg_temp.expect_fail('2.x ubah/hapus log transaksi ditolak',
  $q$DELETE FROM inventory_transactions$q$, '23001');

-- Jurnal otomatis: nilai & keseimbangan
SELECT pg_temp.expect_true('2.1c jurnal otomatis: PURCHASE Dr 1301 / Kr 2101 = 100.000.000',
  (SELECT bool_and(CASE a.account_code WHEN '1301' THEN l.debit=100000000 WHEN '2101' THEN l.credit=100000000 ELSE false END)
     FROM journal_headers h JOIN journal_lines l USING (header_id) JOIN chart_of_accounts a USING (account_id)
    WHERE h.ref_no = 'INV-00000001'));
SELECT pg_temp.expect_true('2.1c jurnal otomatis: SALE Dr 5101 / Kr 1301 = 40.000.000',
  (SELECT bool_and(CASE a.account_code WHEN '5101' THEN l.debit=40000000 WHEN '1301' THEN l.credit=40000000 ELSE false END)
     FROM journal_headers h JOIN journal_lines l USING (header_id) JOIN chart_of_accounts a USING (account_id)
    WHERE h.ref_no = 'INV-00000002'));
SELECT pg_temp.expect_true('2.1c ADJUSTMENT(-) Dr 5901 / Kr 1301 = 10.000.000',
  (SELECT bool_and(CASE a.account_code WHEN '5901' THEN l.debit=10000000 WHEN '1301' THEN l.credit=10000000 ELSE false END)
     FROM journal_headers h JOIN journal_lines l USING (header_id) JOIN chart_of_accounts a USING (account_id)
    WHERE h.ref_no = 'INV-00000003'));
-- Rekonsiliasi stock opname: saldo buku persediaan = qty x unit_cost
SELECT pg_temp.expect_true('2.x rekonsiliasi: saldo akun 1301 = stok fisik x unit_cost',
  (SELECT (SELECT sum(l.debit - l.credit) FROM journal_lines l JOIN chart_of_accounts a USING (account_id)
             JOIN journal_headers h USING (header_id) WHERE a.account_code='1301' AND h.ref_no LIKE 'INV-%')
          = (SELECT sum(stock_qty * unit_cost) FROM inventory_items)));
-- Neraca saldo global seimbang
SELECT pg_temp.expect_true('GL: total debit = total kredit seluruh jurnal POSTED',
  (SELECT sum(l.debit) = sum(l.credit) FROM journal_lines l JOIN journal_headers h USING (header_id) WHERE h.posting_status='POSTED'));
SELECT pg_temp.expect_true('Audit log terisi',
  (SELECT count(*) > 20 FROM audit_log));

-- ===================== SOAL 3: RPC voucher kas keluar =====================
\i 05_rpc_voucher.sql
SELECT fn_create_cash_out_voucher('2026-10-10', 'VCO-001', 'Bayar listrik',
  '[{"account_code":"6101","debit":500000,"credit":0},{"account_code":"1101","debit":0,"credit":500000}]'::jsonb) AS v1 \gset
SELECT pg_temp.expect_true('3.1 RPC voucher seimbang -> POSTED',
  (SELECT posting_status='POSTED' AND hash_checksum IS NOT NULL FROM journal_headers WHERE header_id = :v1));
SELECT pg_temp.expect_fail('3.1 RPC voucher tidak seimbang ditolak',
  $q$SELECT fn_create_cash_out_voucher('2026-10-10','VCO-002','x','[{"account_code":"6101","debit":500000,"credit":0},{"account_code":"1101","debit":0,"credit":400000}]'::jsonb)$q$, '23514');
SELECT pg_temp.expect_fail('3.1 RPC tanpa kredit kas ditolak',
  $q$SELECT fn_create_cash_out_voucher('2026-10-10','VCO-003','x','[{"account_code":"6101","debit":500,"credit":0},{"account_code":"2101","debit":0,"credit":500}]'::jsonb)$q$, '23514');
SELECT pg_temp.expect_fail('3.1 RPC akun tidak dikenal ditolak',
  $q$SELECT fn_create_cash_out_voucher('2026-10-10','VCO-004','x','[{"account_code":"9999","debit":5,"credit":0},{"account_code":"1101","debit":0,"credit":5}]'::jsonb)$q$, '23503');
SELECT pg_temp.expect_true('3.1 voucher gagal tidak meninggalkan sisa data (atomik)',
  (SELECT count(*) = 0 FROM journal_headers WHERE ref_no IN ('VCO-002','VCO-003','VCO-004')));

-- ===================== Laporan =====================
\o
\set QUIET off
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS hasil, name AS uji, detail FROM t_result;
SELECT count(*) FILTER (WHERE ok) AS lulus, count(*) FILTER (WHERE NOT ok) AS gagal, count(*) AS total FROM t_result;
