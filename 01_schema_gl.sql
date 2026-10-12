-- =====================================================================
-- SOAL 1 : Skema General Ledger + kekangan integritas (PostgreSQL 14+)
-- =====================================================================

CREATE TABLE chart_of_accounts (
    account_id            SERIAL        PRIMARY KEY,
    account_code          VARCHAR(10)   NOT NULL UNIQUE,
    account_name          VARCHAR(100)  NOT NULL,
    normal_balance        VARCHAR(6)    NOT NULL
        CONSTRAINT chk_coa_normal_balance CHECK (normal_balance IN ('DEBIT', 'CREDIT')),
    report_classification VARCHAR(20)   NOT NULL
        CONSTRAINT chk_coa_report_class
        CHECK (report_classification IN ('ASET', 'LIABILITAS', 'EKUITAS', 'PENDAPATAN', 'BEBAN'))
);

CREATE TABLE journal_headers (
    header_id      BIGSERIAL     PRIMARY KEY,
    trx_date       DATE          NOT NULL,
    ref_no         VARCHAR(40)   NOT NULL UNIQUE,          -- nomor bukti / voucher
    description    TEXT          NOT NULL,
    posting_status VARCHAR(10)   NOT NULL DEFAULT 'DRAFT'
        CONSTRAINT chk_jh_status CHECK (posting_status IN ('DRAFT', 'POSTED'))
);

CREATE TABLE journal_lines (
    line_id    BIGSERIAL      PRIMARY KEY,
    header_id  BIGINT         NOT NULL
        REFERENCES journal_headers (header_id) ON DELETE RESTRICT,
    account_id INT            NOT NULL
        REFERENCES chart_of_accounts (account_id) ON DELETE RESTRICT,
    debit      NUMERIC(18, 2) NOT NULL DEFAULT 0,
    credit     NUMERIC(18, 2) NOT NULL DEFAULT 0,
    CONSTRAINT chk_jl_non_negative  CHECK (debit >= 0 AND credit >= 0),
    CONSTRAINT chk_jl_not_both_zero CHECK (NOT (debit = 0 AND credit = 0)),
    -- Penguatan (di luar syarat soal): satu baris hanya boleh satu sisi.
    CONSTRAINT chk_jl_one_side      CHECK (debit = 0 OR credit = 0)
);

CREATE INDEX idx_jl_header  ON journal_lines (header_id);
CREATE INDEX idx_jl_account ON journal_lines (account_id);

COMMENT ON TABLE journal_headers IS 'Kepala jurnal: 1 baris per transaksi/voucher';
COMMENT ON TABLE journal_lines   IS 'Rincian jurnal: >= 2 baris per header, SUM(debit) = SUM(credit) saat POSTED';
