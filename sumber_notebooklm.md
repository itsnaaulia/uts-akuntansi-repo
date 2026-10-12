# Sumber aturan bisnis: Modul Voucher Kas Keluar dan Persediaan Perpetual
(Unggah berkas ini ke NotebookLM bersama teks PSAK 201, 202, 207, 208.)

## Voucher kas keluar
1. Voucher minimal 2 baris. Setiap baris hanya memuat satu sisi (debit atau kredit), nominal > 0.
2. Total debit harus sama dengan total kredit sebelum voucher dapat diposting.
3. Akun kelompok 11xx (Kas dan Setara Kas) harus dikredit dan tidak boleh didebit pada voucher kas keluar.
4. Jurnal berstatus POSTED tidak dapat diubah atau dihapus. Koreksi dilakukan dengan jurnal pembalik yang menukar sisi debit dan kredit, mencantumkan alasan, dan hanya boleh dilakukan satu kali per jurnal.
5. Setiap jurnal POSTED menyimpan pembuat, waktu, dan checksum SHA-256.
6. Voucher belum mengklasifikasikan arus kas (operasi, investasi, pendanaan).

## Persediaan perpetual
1. PURCHASE: Dr Persediaan (1301) / Kr Utang Usaha (2101), nilai = qty x unit_cost.
2. SALE: Dr Beban Pokok Pendapatan (5101) / Kr Persediaan (1301), nilai = qty x unit_cost. Stok tidak boleh negatif.
3. ADJUSTMENT: selisih terhadap akun Selisih Persediaan (5901).
4. Biaya per unit memakai satu nilai unit_cost per barang; belum ada pembaruan biaya rata-rata/FIFO saat pembelian dan belum ada penurunan nilai ke nilai realisasi neto.
