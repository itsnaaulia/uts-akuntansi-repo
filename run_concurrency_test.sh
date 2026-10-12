#!/usr/bin/env bash
# Bukti nyata 2.2: dua sesi psql berjalan BERSAMAAN pada item yang sama (stok = 1).
# Pemakaian: PGHOST=... PGPORT=... PGUSER=... ./run_concurrency_test.sh <nama_db>
set -u
DB=${1:-uts}
q() { psql -d "$DB" -X -q -v ON_ERROR_STOP=1 "$@"; }

reset_item() {   # buat item baru berstok 1
  q -c "INSERT INTO inventory_items (item_id,item_name,stock_qty,unit_cost) VALUES ('$1','Item uji $1',0,1000)
        ON CONFLICT (item_id) DO NOTHING" -c "INSERT INTO inventory_transactions (item_id,trx_type,qty) VALUES ('$1','PURCHASE',1)"
}
stock() { q -At -c "SELECT stock_qty FROM inventory_items WHERE item_id='$1'"; }
sales() { q -At -c "SELECT count(*) FROM inventory_transactions WHERE item_id='$1' AND trx_type='SALE'"; }

run_pair() {  # $1=label $2=item $3=sql-body (dipakai kasir A dan B)
  echo "=== $1 ==="
  ( psql -d "$DB" -X -q -v ON_ERROR_STOP=1 -c "$3" > /tmp/kasirA.out 2>&1; echo "exit=$?" >> /tmp/kasirA.out ) &
  ( psql -d "$DB" -X -q -v ON_ERROR_STOP=1 -c "$3" > /tmp/kasirB.out 2>&1; echo "exit=$?" >> /tmp/kasirB.out ) &
  wait
  for k in A B; do
    status=$(grep -o 'exit=[0-9]*' /tmp/kasir$k.out); msg=$(grep -m1 -E 'ERROR' /tmp/kasir$k.out | cut -c1-120)
    echo "Kasir $k: $status ${msg:-OK (transaksi COMMIT)}"
  done
  echo "Hasil akhir: stok=$(stock "$2")  jumlah SALE tercatat=$(sales "$2")  (diharapkan stok=0, SALE=1)"
  echo
}

reset_item RACE-1; reset_item RACE-2; reset_item RACE-3

run_pair "Skenario A - Trigger saja (baris dikunci di dalam trigger), READ COMMITTED" RACE-1 \
 "BEGIN; INSERT INTO inventory_transactions (item_id,trx_type,qty) VALUES ('RACE-1','SALE',1); SELECT pg_sleep(2); COMMIT;"

run_pair "Skenario B - SELECT ... FOR UPDATE di aplikasi + trigger" RACE-2 \
 "BEGIN; SELECT stock_qty FROM inventory_items WHERE item_id='RACE-2' FOR UPDATE; SELECT pg_sleep(2); INSERT INTO inventory_transactions (item_id,trx_type,qty) VALUES ('RACE-2','SALE',1); COMMIT;"

run_pair "Skenario C - SERIALIZABLE (satu sesi gagal 40001 lalu harus retry)" RACE-3 \
 "BEGIN ISOLATION LEVEL SERIALIZABLE; SELECT stock_qty FROM inventory_items WHERE item_id='RACE-3'; SELECT pg_sleep(2); INSERT INTO inventory_transactions (item_id,trx_type,qty) VALUES ('RACE-3','SALE',1); COMMIT;"
