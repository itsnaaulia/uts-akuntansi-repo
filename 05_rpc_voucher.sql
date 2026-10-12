-- =====================================================================
-- SOAL 3.2 : Supabase RPC untuk Voucher Kas Keluar (satu transaksi atomik)
-- Prasyarat: 01, 02 (dan akun dari 03). Dipanggil dari web:
--   POST {SUPABASE_URL}/rest/v1/rpc/fn_create_cash_out_voucher
-- Semua validasi diulang di sini; validasi frontend hanya kenyamanan pengguna.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_create_cash_out_voucher(
    p_trx_date    DATE,
    p_ref_no      TEXT,
    p_description TEXT,
    p_lines       JSONB            -- [{"account_code":"6101","debit":1000,"credit":0}, ...]
) RETURNS BIGINT
LANGUAGE plpgsql AS
$$
DECLARE
    v_hdr BIGINT; v_missing TEXT; v_cash_credit NUMERIC; v_cash_debit NUMERIC;
BEGIN
    IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) < 2 THEN
        RAISE EXCEPTION 'Voucher minimal memiliki 2 baris.' USING ERRCODE = 'check_violation';
    END IF;

    -- seluruh akun harus dikenal
    SELECT string_agg(DISTINCT x ->> 'account_code', ', ') INTO v_missing
      FROM jsonb_array_elements(p_lines) x
      LEFT JOIN chart_of_accounts a ON a.account_code = x ->> 'account_code'
     WHERE a.account_id IS NULL;
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Kode akun tidak dikenal: %', v_missing USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- aturan khusus kas keluar: kas hanya boleh BERKURANG (kredit)
    SELECT COALESCE(sum((x ->> 'credit')::numeric), 0), COALESCE(sum((x ->> 'debit')::numeric), 0)
      INTO v_cash_credit, v_cash_debit
      FROM jsonb_array_elements(p_lines) x
     WHERE x ->> 'account_code' LIKE '11%';          -- kelompok Kas & Setara Kas
    IF v_cash_credit <= 0 OR v_cash_debit > 0 THEN
        RAISE EXCEPTION 'Voucher kas keluar harus mengkredit akun Kas/Bank (kelompok 11xx) dan tidak boleh mendebitnya.'
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO journal_headers (trx_date, ref_no, description)
    VALUES (p_trx_date, p_ref_no, p_description)
    RETURNING header_id INTO v_hdr;

    INSERT INTO journal_lines (header_id, account_id, debit, credit)
    SELECT v_hdr, a.account_id,
           COALESCE((x ->> 'debit')::numeric, 0), COALESCE((x ->> 'credit')::numeric, 0)
      FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS t(x, n)
      JOIN chart_of_accounts a ON a.account_code = x ->> 'account_code'
     ORDER BY n;

    UPDATE journal_headers SET posting_status = 'POSTED' WHERE header_id = v_hdr;  -- seimbang? dicek trigger
    RETURN v_hdr;
END;
$$;

-- Rekomendasi Supabase (produksi): RLS aktif, klien hanya boleh memanggil RPC, bukan menulis tabel.
--   ALTER TABLE journal_headers ENABLE ROW LEVEL SECURITY;  -- idem journal_lines, audit_log
--   REVOKE INSERT, UPDATE, DELETE ON journal_headers, journal_lines FROM anon, authenticated;
--   GRANT EXECUTE ON FUNCTION fn_create_cash_out_voucher(DATE,TEXT,TEXT,JSONB),
--                             fn_reverse_journal(BIGINT,TEXT,DATE) TO authenticated;
--   -- fungsi dibuat SECURITY DEFINER bila tabel dicabut hak tulisnya; set search_path = public.
