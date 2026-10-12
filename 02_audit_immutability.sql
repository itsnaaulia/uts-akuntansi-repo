-- =====================================================================
-- SOAL 3.2 : Jejak audit, immutability jurnal POSTED, jurnal pembalik
-- Prasyarat: 01_schema_gl.sql
-- Semua aturan ditegakkan DI DATABASE, sehingga tidak bisa dilewati lewat API.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Identitas pengguna aplikasi.
--    Backend mengeset:  SELECT set_config('app.user', '<user-id>', true);
--    (di Supabase dapat diganti auth.uid() / request.jwt.claims).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app_user() RETURNS TEXT
LANGUAGE sql STABLE AS
$$ SELECT COALESCE(NULLIF(current_setting('app.user', true), ''), session_user::text) $$;

-- ---------------------------------------------------------------------
-- 1. Kolom audit & integritas pada journal_headers
-- ---------------------------------------------------------------------
ALTER TABLE journal_headers
    ADD COLUMN created_by         TEXT        NOT NULL DEFAULT app_user(),
    ADD COLUMN created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    ADD COLUMN posted_by          TEXT,
    ADD COLUMN posted_at          TIMESTAMPTZ,
    ADD COLUMN hash_checksum      CHAR(64),                       -- SHA-256 hex
    ADD COLUMN reverses_header_id BIGINT
        REFERENCES journal_headers (header_id) ON DELETE RESTRICT;

-- Satu jurnal hanya boleh dibalik satu kali.
CREATE UNIQUE INDEX uq_jh_reverses ON journal_headers (reverses_header_id)
    WHERE reverses_header_id IS NOT NULL;

-- Jurnal POSTED wajib punya checksum, pembuat, dan waktu posting.
ALTER TABLE journal_headers ADD CONSTRAINT chk_jh_posted_complete CHECK (
    posting_status = 'DRAFT'
    OR (hash_checksum IS NOT NULL AND posted_at IS NOT NULL AND posted_by IS NOT NULL)
);

-- ---------------------------------------------------------------------
-- 2. Checksum SHA-256 atas isi jurnal (header + seluruh baris, berurutan)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_journal_hash(h journal_headers) RETURNS CHAR(64)
LANGUAGE sql STABLE AS
$$
    SELECT encode(sha256(convert_to(
        concat_ws('|',
            h.ref_no,
            h.trx_date::text,
            h.description,
            h.created_by,
            to_char(h.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
            COALESCE(h.reverses_header_id::text, ''),
            COALESCE((SELECT string_agg(l.account_id || ':' || l.debit || ':' || l.credit,
                                        ';' ORDER BY l.line_id)
                      FROM journal_lines l WHERE l.header_id = h.header_id), '')
        ), 'UTF8')), 'hex')::CHAR(64)
$$;

-- ---------------------------------------------------------------------
-- 3. Guard pada journal_headers
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_jh_guard() RETURNS trigger
LANGUAGE plpgsql AS
$$
DECLARE
    v_cnt INT; v_debit NUMERIC(18,2); v_credit NUMERIC(18,2);
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.posting_status <> 'DRAFT' THEN
            RAISE EXCEPTION 'Jurnal harus dibuat berstatus DRAFT lalu diposting (header %).', NEW.ref_no
                USING ERRCODE = 'check_violation';
        END IF;
        -- Kolom audit tidak boleh dipalsukan oleh klien.
        NEW.created_by    := app_user();
        NEW.created_at    := now();
        NEW.posted_by     := NULL;
        NEW.posted_at     := NULL;
        NEW.hash_checksum := NULL;
        RETURN NEW;

    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.posting_status = 'POSTED' THEN
            RAISE EXCEPTION 'Jurnal % berstatus POSTED dan tidak dapat diubah. Gunakan jurnal pembalik (fn_reverse_journal).',
                OLD.ref_no USING ERRCODE = 'restrict_violation';
        END IF;
        NEW.created_by := OLD.created_by;       -- jejak pembuat tidak boleh diubah
        NEW.created_at := OLD.created_at;
        NEW.hash_checksum := NULL;
        NEW.posted_by := NULL;
        NEW.posted_at := NULL;

        IF NEW.posting_status = 'POSTED' THEN   -- transisi DRAFT -> POSTED
            SELECT count(*), COALESCE(sum(debit),0), COALESCE(sum(credit),0)
              INTO v_cnt, v_debit, v_credit
              FROM journal_lines WHERE header_id = NEW.header_id;
            IF v_cnt < 2 THEN
                RAISE EXCEPTION 'Jurnal % minimal memiliki 2 baris (ditemukan %).', NEW.ref_no, v_cnt
                    USING ERRCODE = 'check_violation';
            END IF;
            IF v_debit <> v_credit THEN
                RAISE EXCEPTION 'Jurnal % tidak seimbang: total debit % <> total kredit %.',
                    NEW.ref_no, v_debit, v_credit USING ERRCODE = 'check_violation';
            END IF;
            NEW.posted_by     := app_user();
            NEW.posted_at     := now();
            NEW.hash_checksum := fn_journal_hash(NEW);
        END IF;
        RETURN NEW;

    ELSE -- DELETE
        IF OLD.posting_status = 'POSTED' THEN
            RAISE EXCEPTION 'Jurnal % berstatus POSTED dan tidak dapat dihapus. Gunakan jurnal pembalik (fn_reverse_journal).',
                OLD.ref_no USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN OLD;
    END IF;
END;
$$;

CREATE TRIGGER trg_jh_guard
    BEFORE INSERT OR UPDATE OR DELETE ON journal_headers
    FOR EACH ROW EXECUTE FUNCTION fn_jh_guard();

-- ---------------------------------------------------------------------
-- 4. Guard pada journal_lines: baris milik jurnal POSTED terkunci
--    FOR SHARE pada header menyerialkan baris baru vs proses posting.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_jl_guard() RETURNS trigger
LANGUAGE plpgsql AS
$$
DECLARE
    v_status TEXT; v_hid BIGINT;
BEGIN
    FOR v_hid IN
        SELECT DISTINCT h FROM unnest(ARRAY[
            CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN OLD.header_id END,
            CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN NEW.header_id END]) AS h
        WHERE h IS NOT NULL
    LOOP
        SELECT posting_status INTO v_status
          FROM journal_headers WHERE header_id = v_hid FOR SHARE;
        IF v_status = 'POSTED' THEN
            RAISE EXCEPTION 'Baris jurnal milik header % (POSTED) tidak dapat di-% . Gunakan jurnal pembalik.',
                v_hid, TG_OP USING ERRCODE = 'restrict_violation';
        END IF;
    END LOOP;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER trg_jl_guard
    BEFORE INSERT OR UPDATE OR DELETE ON journal_lines
    FOR EACH ROW EXECUTE FUNCTION fn_jl_guard();

-- ---------------------------------------------------------------------
-- 5. Audit log append-only
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    log_id     BIGSERIAL   PRIMARY KEY,
    table_name TEXT        NOT NULL,
    action     TEXT        NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
    record_id  TEXT        NOT NULL,
    old_data   JSONB,
    new_data   JSONB,
    changed_by TEXT        NOT NULL DEFAULT app_user(),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    txid       BIGINT      NOT NULL DEFAULT txid_current()
);

CREATE OR REPLACE FUNCTION fn_audit() RETURNS trigger
LANGUAGE plpgsql AS
$$
DECLARE
    v_old JSONB := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
    v_new JSONB := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
BEGIN
    INSERT INTO audit_log (table_name, action, record_id, old_data, new_data)
    VALUES (TG_TABLE_NAME, TG_OP,
            COALESCE(v_new, v_old) ->> TG_ARGV[0], v_old, v_new);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_audit_jh AFTER INSERT OR UPDATE OR DELETE ON journal_headers
    FOR EACH ROW EXECUTE FUNCTION fn_audit('header_id');
CREATE TRIGGER trg_audit_jl AFTER INSERT OR UPDATE OR DELETE ON journal_lines
    FOR EACH ROW EXECUTE FUNCTION fn_audit('line_id');
CREATE TRIGGER trg_audit_coa AFTER INSERT OR UPDATE OR DELETE ON chart_of_accounts
    FOR EACH ROW EXECUTE FUNCTION fn_audit('account_id');

CREATE OR REPLACE FUNCTION fn_block_mutation() RETURNS trigger
LANGUAGE plpgsql AS
$$
BEGIN
    RAISE EXCEPTION '% bersifat append-only: % ditolak.', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'restrict_violation';
END;
$$;

CREATE TRIGGER trg_audit_append_only BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION fn_block_mutation();
CREATE TRIGGER trg_audit_no_truncate BEFORE TRUNCATE ON audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION fn_block_mutation();
CREATE TRIGGER trg_jh_no_truncate BEFORE TRUNCATE ON journal_headers
    FOR EACH STATEMENT EXECUTE FUNCTION fn_block_mutation();
CREATE TRIGGER trg_jl_no_truncate BEFORE TRUNCATE ON journal_lines
    FOR EACH STATEMENT EXECUTE FUNCTION fn_block_mutation();

-- ---------------------------------------------------------------------
-- 6. Jurnal pembalik (reversing entry / storno)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_reverse_journal(
    p_header_id BIGINT,
    p_reason    TEXT,
    p_date      DATE DEFAULT CURRENT_DATE
) RETURNS BIGINT
LANGUAGE plpgsql AS
$$
DECLARE
    v_orig journal_headers%ROWTYPE;
    v_new  BIGINT;
BEGIN
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'Alasan pembalikan wajib diisi.';
    END IF;

    SELECT * INTO v_orig FROM journal_headers WHERE header_id = p_header_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Jurnal % tidak ditemukan.', p_header_id;
    END IF;
    IF v_orig.posting_status <> 'POSTED' THEN
        RAISE EXCEPTION 'Hanya jurnal POSTED yang dapat dibalik (status saat ini: %).', v_orig.posting_status;
    END IF;
    IF EXISTS (SELECT 1 FROM journal_headers WHERE reverses_header_id = p_header_id) THEN
        RAISE EXCEPTION 'Jurnal % sudah pernah dibalik.', v_orig.ref_no;
    END IF;

    INSERT INTO journal_headers (trx_date, ref_no, description, reverses_header_id)
    VALUES (p_date, 'REV-' || v_orig.ref_no,
            'Jurnal pembalik ' || v_orig.ref_no || ': ' || p_reason, p_header_id)
    RETURNING header_id INTO v_new;

    INSERT INTO journal_lines (header_id, account_id, debit, credit)
    SELECT v_new, account_id, credit, debit        -- sisi debit/kredit ditukar
      FROM journal_lines WHERE header_id = p_header_id ORDER BY line_id;

    UPDATE journal_headers SET posting_status = 'POSTED' WHERE header_id = v_new;
    RETURN v_new;
END;
$$;

-- ---------------------------------------------------------------------
-- 7. Verifikasi integritas: bandingkan checksum tersimpan vs hitung ulang
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_journal_integrity AS
SELECT h.header_id, h.ref_no, h.hash_checksum AS stored_hash,
       fn_journal_hash(h) AS recomputed_hash,
       (h.hash_checksum = fn_journal_hash(h)) AS is_intact
  FROM journal_headers h
 WHERE h.posting_status = 'POSTED';

-- Rekomendasi hardening produksi (butuh role terpisah, tidak dijalankan di sini):
--   REVOKE UPDATE, DELETE, TRUNCATE ON journal_headers, journal_lines, audit_log FROM app_role;
--   GRANT  EXECUTE ON FUNCTION fn_reverse_journal(BIGINT, TEXT, DATE) TO app_role;
