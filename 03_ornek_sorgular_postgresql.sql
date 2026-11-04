-- =====================================================================
-- Hazır Mahalle — Örnek sorgular (PostgreSQL)
-- Her sorgu uygulamadaki bir ekrana veya bir raporlama ihtiyacına karşılık gelir.
-- Çalıştırma: psql -d hazir_mahalle -f 03_ornek_sorgular_postgresql.sql
-- =====================================================================
SET search_path TO hm, public;
SET hm.sifre_anahtari = 'GELISTIRME-ANAHTARI-degistir';
\pset border 2

\echo '1) Kayıtlı kullanıcılar ve kişisel kodları'
SELECT ad || ' ' || soyad AS ad_soyad, kisisel_kod, telefon, dil FROM kullanici ORDER BY olusturma_zamani;

\echo '2) Aile ekranı: Demir Ailesi — son durum, son konum, buluşma noktasına uzaklık'
SELECT ad_soyad, rol, yakinlik, son_durum, durum_kanali, konum_yasi_dk, pil_yuzdesi,
       bulusmaya_mesafe_m, bulusma_noktasi
FROM v_aile_durumu WHERE aile_adi = 'Demir Ailesi' ORDER BY rol, ad_soyad;

\echo '3) Haber alınamayan aile üyeleri (30 dk içinde durum bildirmemiş)'
SELECT aile_adi, ad_soyad, coalesce(son_durum::text, 'haber yok') AS durum
FROM v_aile_durumu
WHERE durum_zamani IS NULL OR durum_zamani < now() - interval '30 minutes';

\echo '4) Elif''in son konumuna en yakın 3 toplanma alanı (internetsiz: aynı hesap telefonda yapılır)'
SELECT e.* FROM son_konum s JOIN kullanici k ON k.id = s.kullanici_id,
       LATERAL en_yakin_alanlar(s.enlem, s.boylam, 3) e
WHERE k.ad = 'Elif';

\echo '5) Mesh ile geç gelen eski ölçüm son konumu ezmedi mi? (en yeni ölçüm zamanı = son_konum zamanı olmalı)'
SELECT k.ad, max(kk.olcum_zamani) = s.olcum_zamani AS dogru, count(*) AS olcum_sayisi
FROM konum_kaydi kk JOIN kullanici k ON k.id = kk.kullanici_id JOIN son_konum s ON s.kullanici_id = k.id
GROUP BY k.ad, s.olcum_zamani;

\echo '6) Bekleyen aile katılım istekleri (yöneticinin onay ekranı)'
SELECT a.ad AS aile, i.yon, ist.ad || ' ' || ist.soyad AS isteyen, i.girilen_kod, i.durum,
       to_char(i.son_gecerlilik, 'DD.MM.YYYY') AS son_gun
FROM aile_istek i JOIN aile a ON a.id = i.aile_id JOIN kullanici ist ON ist.id = i.isteyen_id
WHERE i.durum = 'beklemede';

\echo '7) Hazırlık skoru'
SELECT * FROM v_hazirlik_skoru;

\echo '8) Muhtar özeti (kişisel veri yok)'
SELECT mahalle, kategori, acik, ustlenildi, karsilandi, acik_adet, teyit_bekleyen FROM v_mahalle_ihtiyac_ozeti ORDER BY mahalle, kategori;

\echo '9) Pano (12 saattir teyit edilmemiş ilanlar işaretli)'
SELECT tur, kategori, adet, birim, durum, dogrulanmis, teyit_gerekli, left(aciklama, 40) AS aciklama FROM v_pano ORDER BY dogrulanmis DESC, olusturma_zamani DESC;

\echo '10) İlan durum geçmişi'
SELECT left(i.aciklama, 30) AS ilan, h.eski_durum, h.yeni_durum, k.ad AS kisi
FROM ilan_hareket h JOIN ilan i ON i.id = h.ilan_id LEFT JOIN kullanici k ON k.id = h.kullanici_id
ORDER BY h.id;

\echo '11) Mesaj ulaşım KPI (kanal başına)'
SELECT * FROM v_mesaj_ulasim;

\echo '12) Son açılışta konum izni sonucu'
SELECT k.ad, v.sonuc FROM v_konum_izni_son v JOIN kullanici k ON k.id = v.kullanici_id;

\echo '13) Şifreli adres: tabloda okunamaz, yalnızca anahtarla çözülür'
SELECT k.ad, left(encode(a.acik_adres_sifreli, 'hex'), 24) || '…' AS tabloda_gorunen, coz(a.acik_adres_sifreli) AS cozulmus
FROM kullanici_adres a JOIN kullanici k ON k.id = a.kullanici_id WHERE k.ad = 'Elif';

\echo '14) Hassas tablolara erişim denetimi'
SELECT tablo, islem, count(*) FROM denetim_kaydi GROUP BY tablo, islem;

\echo '15) İş kuralı testleri (hepsi hata vermeli)'
DO $$
DECLARE z uuid := (SELECT id FROM kullanici WHERE ad = 'Zeynep'); e uuid := (SELECT id FROM kullanici WHERE ad = 'Elif');
BEGIN
  BEGIN PERFORM kodla_aileye_katil(e, 'HM-ZZZZ-ZZZZ'); RAISE NOTICE 'HATA: olmayan kod kabul edildi';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'Doğru: %', SQLERRM; END;
  BEGIN PERFORM kodla_aileye_katil(e, (SELECT kisisel_kod FROM kullanici WHERE id = e)); RAISE NOTICE 'HATA: kendi kodu kabul edildi';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'Doğru: %', SQLERRM; END;
  BEGIN UPDATE ilan SET durum = 'acik' WHERE durum = 'karsilandi'; RAISE NOTICE 'HATA: karşılanan ilan yeniden açıldı';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'Doğru: %', SQLERRM; END;
  BEGIN PERFORM kullanici_kaydet('Test', 'Kişi', '12345', 1, 'x'); RAISE NOTICE 'HATA: geçersiz telefon kabul edildi';
  EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'Doğru: %', SQLERRM; END;
END $$;
