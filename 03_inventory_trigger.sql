-- =====================================================================
-- SOAL 2 : Trigger persediaan perpetual (stok + jurnal otomatis)
-- Prasyarat: 01_schema_gl.sql dan 02_audit_immutability.sql
-- =====================================================================

-- Struktur tabel sesuai naskah soal -----------------------------------
CREATE TABLE inventory_items (
    item_id    VARCHAR(10) PRIMARY KEY,
    item_name  VARCHAR(100),
    stock_qty  INT            NOT NULL DEFAULT 0,
    unit_cost  NUMERIC(15, 2) NOT NULL
);

CREATE TABLE inventory_transactions (
    trx_id    SERIAL PRIMARY KEY,
    item_id   VARCHAR(10) REFERENCES inventory_items(item_id),
    trx_type  VARCHAR(10) CHECK (trx_type IN ('PURCHASE', 'SALE', 'ADJUSTMENT')),
    qty       INT NOT NULL,
    trx_date  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Akun yang dipakai jurnal otomatis -------------------------------------
INSERT INTO chart_of_accounts (account_code, account_name, normal_balance, report_classification) VALUES
    ('1101', 'Kas dan Setara Kas',          'DEBIT',  'ASET'),
    ('1301', 'Persediaan Barang Dagang',    'DEBIT',  'ASET'),
    ('2101', 'Utang Usaha',                 'CREDIT', 'LIABILITAS'),
    ('3101', 'Modal Saham',                 'CREDIT', 'EKUITAS'),
    ('4101', 'Penjualan',                   'CREDIT', 'PENDAPATAN'),
    ('5101', 'Beban Pokok Pendapatan (HPP)','DEBIT',  'BEBAN'),
    ('5901', 'Selisih Persediaan',          'DEBIT',  'BEBAN'),
    ('6101', 'Beban Operasional',           'DEBIT',  'BEBAN')
ON CONFLICT (account_code) DO NOTHING;

-- ---------------------------------------------------------------------
-- 2.1  trg_update_stock_and_journal()
--
-- Konvensi qty:
--   PURCHASE   qty > 0  -> stok bertambah, Dr Persediaan / Kr Utang Usaha
--   SALE       qty > 0  -> stok berkurang, Dr HPP / Kr Persediaan
--   ADJUSTMENT qty <> 0 -> bertanda (+ menambah, - mengurangi),
--                          Dr/Kr Persediaan terhadap Selisih Persediaan
-- Nilai jurnal = |perubahan qty| x unit_cost.
-- Sisi pendapatan (Kr Penjualan) dicatat modul penjualan, bukan trigger ini.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_update_stock_and_journal()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_item    inventory_items%ROWTYPE;
    v_delta   INT;
    v_new_qty INT;
    v_amount  NUMERIC(18, 2);
    v_hdr     BIGINT;
    v_acc_inv INT; v_acc_hpp INT; v_acc_ap INT; v_acc_adj INT;
    v_debit   INT; v_credit INT;
BEGIN
    -- Validasi input
    IF NEW.trx_type IN ('PURCHASE', 'SALE') AND NEW.qty <= 0 THEN
        RAISE EXCEPTION 'qty % harus > 0 untuk transaksi %.', NEW.qty, NEW.trx_type
            USING ERRCODE = 'check_violation';
    ELSIF NEW.trx_type = 'ADJUSTMENT' AND NEW.qty = 0 THEN
        RAISE EXCEPTION 'qty ADJUSTMENT tidak boleh 0.' USING ERRCODE = 'check_violation';
    END IF;

    -- Kunci baris barang sampai transaksi selesai (cegah race condition).
    -- FOR NO KEY UPDATE (bukan FOR UPDATE): INSERT ke inventory_transactions sudah memegang
    -- FOR KEY SHARE pada baris induk (cek FK); dua sesi yang sama-sama menaikkan ke FOR UPDATE
    -- akan saling tunggu (deadlock). NO KEY UPDATE kompatibel dengan KEY SHARE sehingga sesi
    -- kedua cukup antre lalu membaca stok terbaru.
    SELECT * INTO v_item FROM inventory_items WHERE item_id = NEW.item_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Barang % tidak ditemukan.', NEW.item_id;
    END IF;

    v_delta   := CASE NEW.trx_type WHEN 'SALE' THEN -NEW.qty ELSE NEW.qty END;
    v_new_qty := v_item.stock_qty + v_delta;

    -- (b) Anti-negative inventory
    IF v_new_qty < 0 THEN
        RAISE EXCEPTION 'Stok % tidak mencukupi: tersedia %, mutasi % (%). Transaksi dibatalkan.',
            NEW.item_id, v_item.stock_qty, v_delta, NEW.trx_type
            USING ERRCODE = 'check_violation',
                  HINT = 'Kurangi qty atau lakukan pembelian/penyesuaian terlebih dahulu.';
    END IF;

    -- (a) Mutasi stok
    UPDATE inventory_items SET stock_qty = v_new_qty WHERE item_id = NEW.item_id;

    -- (c) Jurnal otomatis ke buku besar
    v_amount := abs(v_delta) * v_item.unit_cost;
    IF v_amount > 0 THEN
        SELECT account_id INTO v_acc_inv FROM chart_of_accounts WHERE account_code = '1301';
        SELECT account_id INTO v_acc_hpp FROM chart_of_accounts WHERE account_code = '5101';
        SELECT account_id INTO v_acc_ap  FROM chart_of_accounts WHERE account_code = '2101';
        SELECT account_id INTO v_acc_adj FROM chart_of_accounts WHERE account_code = '5901';
        IF v_acc_inv IS NULL OR v_acc_hpp IS NULL OR v_acc_ap IS NULL OR v_acc_adj IS NULL THEN
            RAISE EXCEPTION 'Akun 1301/5101/2101/5901 belum ada di chart_of_accounts.';
        END IF;

        IF NEW.trx_type = 'SALE' THEN
            v_debit := v_acc_hpp;  v_credit := v_acc_inv;
        ELSIF NEW.trx_type = 'PURCHASE' THEN
            v_debit := v_acc_inv;  v_credit := v_acc_ap;
        ELSIF v_delta > 0 THEN                     -- ADJUSTMENT (+)
            v_debit := v_acc_inv;  v_credit := v_acc_adj;
        ELSE                                       -- ADJUSTMENT (-)
            v_debit := v_acc_adj;  v_credit := v_acc_inv;
        END IF;

        INSERT INTO journal_headers (trx_date, ref_no, description)
        VALUES (NEW.trx_date::date,
                'INV-' || lpad(NEW.trx_id::text, 8, '0'),
                format('%s %s x %s (%s)', NEW.trx_type, NEW.qty, v_item.item_name, NEW.item_id))
        RETURNING header_id INTO v_hdr;

        INSERT INTO journal_lines (header_id, account_id, debit, credit) VALUES
            (v_hdr, v_debit,  v_amount, 0),
            (v_hdr, v_credit, 0, v_amount);

        UPDATE journal_headers SET posting_status = 'POSTED' WHERE header_id = v_hdr;
    END IF;

    RETURN NULL;   -- AFTER trigger: nilai kembalian diabaikan
END;
$$;

CREATE TRIGGER trg_update_stock_and_journal
    AFTER INSERT ON inventory_transactions
    FOR EACH ROW
    EXECUTE FUNCTION trg_update_stock_and_journal();

-- ---------------------------------------------------------------------
-- Penguatan: stok hanya boleh berubah lewat trigger di atas, dan log
-- transaksi persediaan tidak boleh diubah/dihapus.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_guard_inventory_items() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.stock_qty <> 0 THEN
        RAISE EXCEPTION 'Stok awal harus 0; isi melalui transaksi PURCHASE/ADJUSTMENT agar terjurnal.'
            USING ERRCODE = 'check_violation';
    ELSIF TG_OP = 'UPDATE' AND NEW.stock_qty IS DISTINCT FROM OLD.stock_qty
          AND pg_trigger_depth() < 2 THEN          -- bukan dari trigger transaksi
        RAISE EXCEPTION 'stock_qty tidak boleh diubah langsung; catat melalui inventory_transactions.'
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_inventory_items
    BEFORE INSERT OR UPDATE ON inventory_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_inventory_items();

CREATE TRIGGER trg_inv_trx_append_only
    BEFORE UPDATE OR DELETE ON inventory_transactions
    FOR EACH ROW EXECUTE FUNCTION fn_block_mutation();
CREATE TRIGGER trg_inv_trx_no_truncate
    BEFORE TRUNCATE ON inventory_transactions
    FOR EACH STATEMENT EXECUTE FUNCTION fn_block_mutation();
