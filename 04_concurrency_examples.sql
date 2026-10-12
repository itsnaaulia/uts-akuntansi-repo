-- =====================================================================
-- SOAL 2.2 : Contoh kode penanganan race condition (overselling)
-- Skenario: stok BRG-002 tersisa 1 unit, dua kasir menjual 1 unit bersamaan.
-- Dijalankan otomatis oleh sql/run_concurrency_test.sh
-- =====================================================================

-- ---------------------------------------------------------------------
-- Teknik 1 (utama): pessimistic locking dengan SELECT ... FOR UPDATE
-- Kasir kedua menunggu sampai kasir pertama COMMIT, lalu membaca stok TERBARU (0).
-- ---------------------------------------------------------------------
BEGIN;                                   -- READ COMMITTED (default PostgreSQL)

SELECT stock_qty
  FROM inventory_items
 WHERE item_id = 'BRG-002'
   FOR UPDATE;                           -- kunci baris; sesi lain antre di sini

-- aplikasi memeriksa: jika stock_qty < qty_diminta -> ROLLBACK dan tampilkan pesan
INSERT INTO inventory_transactions (item_id, trx_type, qty)
VALUES ('BRG-002', 'SALE', 1);           -- trigger memutakhirkan stok + jurnal

COMMIT;

-- ---------------------------------------------------------------------
-- Teknik 2: isolasi SERIALIZABLE + retry bila SQLSTATE 40001
-- ---------------------------------------------------------------------
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT stock_qty FROM inventory_items WHERE item_id = 'BRG-002';
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-002', 'SALE', 1);
COMMIT;
-- Bila PostgreSQL menjawab "ERROR: could not serialize access ... (40001)",
-- aplikasi WAJIB mengulang seluruh transaksi dari BEGIN (maks. beberapa kali).
-- Pada percobaan ulang, stok sudah 0 sehingga trigger menolak dengan pesan "Stok tidak mencukupi".
