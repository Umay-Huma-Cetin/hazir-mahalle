-- =====================================================================
-- Hazır Mahalle — Örnek veri (PostgreSQL)
-- Kişiler, telefonlar ve adresler UYDURMADIR. Toplanma alanı koordinatları
-- örnektir (kaynak = 'ornek_veri'); gerçek alanlar AFAD / belediye
-- verisinden alınmalıdır.
-- Çalıştırma: psql -d hazir_mahalle -f 02_ornek_veri_postgresql.sql
-- =====================================================================
SET search_path TO hm, public;
-- Yalnızca geliştirme ortamı için örnek anahtar. Üretimde anahtar bir
-- gizli anahtar kasasından (vault) okunur, dosyaya yazılmaz.
SET hm.sifre_anahtari = 'GELISTIRME-ANAHTARI-degistir';

BEGIN;

-- İller ve pilot bölgeler
INSERT INTO il (id, ad, bolge) VALUES
  (34, 'İstanbul', 'marmara'),
  (44, 'Malatya',  'dogu_anadolu'),
  (31, 'Hatay',    'dogu_anadolu');

INSERT INTO ilce (il_id, ad) VALUES
  (44, 'Yeşilyurt'), (44, 'Battalgazi'),
  (34, 'Bahçelievler'), (34, 'Kadıköy'),
  (31, 'Antakya');

INSERT INTO mahalle (ilce_id, ad, merkez_enlem, merkez_boylam, nufus_tahmini, pilot)
SELECT i.id, v.ad, v.e, v.b, v.n, v.p
FROM (VALUES
  ('Yeşilyurt',    'Örnek Çarşı Mahallesi', 38.3550, 38.3100, 9200, true),
  ('Battalgazi',   'Örnek Kale Mahallesi',  38.3990, 38.3620, 6100, false),
  ('Bahçelievler', 'Örnek Park Mahallesi',  41.0000, 28.8560, 31000, true),
  ('Kadıköy',      'Örnek Sahil Mahallesi', 40.9850, 29.0300, 18000, false),
  ('Antakya',      'Örnek Nehir Mahallesi', 36.2030, 36.1600, 7400, false)
) AS v(ilce, ad, e, b, n, p)
JOIN ilce i ON i.ad = v.ilce;

-- Toplanma alanları (örnek koordinatlar)
INSERT INTO toplanma_alani (mahalle_id, ad, ad_ar, ad_en, tur, enlem, boylam, alan_m2, erisilebilir, kaynak, dogrulama_tarihi)
SELECT m.id, v.ad, v.ad_ar, v.ad_en, v.tur::alan_turu, v.e, v.b, v.m2, v.er, 'ornek_veri', DATE '2026-10-28'
FROM (VALUES
  ('Örnek Çarşı Mahallesi', 'Pazar Alanı',          'ساحة السوق',        'Market Square',      'toplanma',       38.3532, 38.3071, 6400, true),
  ('Örnek Çarşı Mahallesi', 'Okul Bahçesi',         'ساحة المدرسة',      'School Yard',        'toplanma',       38.3581, 38.3138, 3800, true),
  ('Örnek Çarşı Mahallesi', 'Konteyner Kent Girişi','مدخل مجمع الحاويات','Container Site Gate','konteyner_kent', 38.3519, 38.3152, 9000, true),
  ('Örnek Park Mahallesi',  'Çınar Parkı',          'حديقة تشينار',      'Çınar Park',         'toplanma',       41.0021, 28.8534, 900,  false),
  ('Örnek Park Mahallesi',  'Spor Sahası',          'الملعب الرياضي',     'Sports Field',       'toplanma',       41.0030, 28.8601, 7200, true),
  ('Örnek Park Mahallesi',  'Okul Bahçesi',         'ساحة المدرسة',      'School Yard',        'toplanma',       40.9972, 28.8552, 4100, true)
) AS v(mah, ad, ad_ar, ad_en, tur, e, b, m2, er)
JOIN mahalle m ON m.ad = v.mah;

-- Deprem çantası maddeleri
INSERT INTO canta_maddesi (kod, ad_tr, ad_ar, ad_en, agirlik, bolge, son_kullanma_takibi, sira) VALUES
  ('su',       'Kişi başı en az 3 günlük içme suyu', 'مياه شرب لثلاثة أيام لكل شخص', 'Drinking water for 3 days per person', 10, NULL, true, 10),
  ('gida',     'Bozulmayan, pişirme gerektirmeyen yiyecek', 'طعام لا يفسد ولا يحتاج إلى طهي', 'Non-perishable food', 8, NULL, true, 20),
  ('ilkyardim','İlk yardım çantası', 'حقيبة إسعافات أولية', 'First aid kit', 8, NULL, false, 30),
  ('ilac',     'Düzenli kullanılan ilaçlar ve reçete fotokopisi', 'الأدوية المعتادة ونسخة من الوصفات', 'Regular medicines and prescriptions', 8, NULL, true, 40),
  ('fener',    'El feneri ve yedek pil', 'مصباح يدوي وبطاريات احتياطية', 'Torch and spare batteries', 6, NULL, false, 50),
  ('powerbank','Dolu powerbank ve kablo', 'شاحن محمول مشحون وكابل', 'Charged power bank and cable', 6, NULL, false, 60),
  ('radyo',    'Pilli radyo', 'راديو يعمل بالبطاريات', 'Battery radio', 4, NULL, false, 70),
  ('duduk',    'Düdük', 'صافرة', 'Whistle', 4, NULL, false, 80),
  ('belge',    'Kimlik ve belge fotokopileri (su geçirmez poşet)', 'نسخ الهوية والوثائق', 'Copies of ID and documents', 6, NULL, false, 90),
  ('nakit',    'Bir miktar nakit para', 'بعض النقود', 'Some cash', 3, NULL, false, 100),
  ('giysi',    'Yedek giysi ve sağlam ayakkabı', 'ملابس احتياطية وحذاء متين', 'Spare clothes and sturdy shoes', 4, NULL, false, 110),
  ('hijyen',   'Islak mendil, hijyen malzemesi, maske', 'مناديل مبللة ومستلزمات نظافة', 'Wipes, hygiene items, masks', 3, NULL, false, 120),
  ('yatak_yani','Ayakkabı ve fener yatağın yanında', 'حذاء ومصباح بجانب السرير', 'Shoes and torch by the bed', 4, 'marmara', false, 130),
  ('ikinci_canta','İş/okul için ikinci küçük çanta', 'حقيبة صغيرة ثانية للعمل أو المدرسة', 'Second small bag for work/school', 4, 'marmara', false, 140),
  ('termal',   'Termal battaniye, bere, eldiven', 'بطانية حرارية وقبعة وقفازات', 'Thermal blanket, hat, gloves', 4, 'dogu_anadolu', false, 150),
  ('soba_kurali','Sobalı ortamda havalandırma kuralı okundu', 'قاعدة التهوية عند استخدام المدفأة', 'Ventilation rule for stoves read', 4, 'dogu_anadolu', false, 160);

-- ---------------------------------------------------------------------
-- Kullanıcılar, aile ve kodla katılım akışı
-- ---------------------------------------------------------------------
DO $$
DECLARE
  m_malatya int := (SELECT id FROM mahalle WHERE ad = 'Örnek Çarşı Mahallesi');
  m_ist     int := (SELECT id FROM mahalle WHERE ad = 'Örnek Park Mahallesi');
  pazar     int := (SELECT id FROM toplanma_alani WHERE ad = 'Pazar Alanı');
  spor      int := (SELECT id FROM toplanma_alani WHERE ad = 'Spor Sahası');
  elif uuid; mert uuid; hasan uuid; deniz uuid; zeynep uuid; ahmet uuid; selin uuid;
  aile_demir uuid; aile_yilmaz uuid; istek uuid; cihaz_elif uuid; cihaz_mert uuid;
  kod_elif text;
BEGIN
  SELECT kullanici_id INTO elif   FROM kullanici_kaydet('elif',   'demir', '0555 111 22 33', m_malatya, 'Örnek Sok. No:12 D:4 (uydurma adres)',  'tr', 38.3561, 38.3112);
  SELECT kullanici_id INTO mert   FROM kullanici_kaydet('mert',   'demir', '0555 111 22 34', m_malatya, 'Örnek Sok. No:12 D:4 (uydurma adres)',  'tr', 38.3561, 38.3112);
  SELECT kullanici_id INTO deniz  FROM kullanici_kaydet('deniz',  'demir', '0555 111 22 35', m_malatya, 'Örnek Sok. No:12 D:4 (uydurma adres)',  'tr', 38.3561, 38.3112);
  SELECT kullanici_id INTO hasan  FROM kullanici_kaydet('hasan',  'demir', '0532 444 55 66', m_ist,     'Örnek Cad. No:5 D:9 (uydurma adres)',   'tr', 41.0005, 28.8570);
  SELECT kullanici_id INTO zeynep FROM kullanici_kaydet('zeynep', 'kaya',  '0544 777 88 99', m_malatya, 'Örnek Bulvarı No:3 (uydurma adres)',    'tr', 38.3540, 38.3090);
  SELECT kullanici_id INTO ahmet  FROM kullanici_kaydet('ahmet',  'yılmaz','0533 222 33 44', m_ist,     'Örnek Sok. No:21 D:2 (uydurma adres)',  'ar', 41.0010, 28.8555);
  SELECT kullanici_id INTO selin  FROM kullanici_kaydet('selin',  'yılmaz','0533 222 33 45', m_ist,     'Örnek Sok. No:21 D:2 (uydurma adres)',  'tr', 41.0010, 28.8555);

  INSERT INTO cihaz (kullanici_id, platform, uygulama_surumu, mesh_kimligi, harita_paketi_surumu)
  VALUES (elif, 'android', '0.1.0', 'mesh-elif-01', DATE '2026-10-28') RETURNING id INTO cihaz_elif;
  INSERT INTO cihaz (kullanici_id, platform, uygulama_surumu, mesh_kimligi, harita_paketi_surumu)
  VALUES (mert, 'ios', '0.1.0', 'mesh-mert-01', DATE '2026-10-28') RETURNING id INTO cihaz_mert;

  -- Elif aileyi kurar; Mert, Elif'in kodunu girerek başvurur; Elif onaylar.
  aile_demir := aile_olustur(elif, 'Demir Ailesi', pazar);
  UPDATE aile SET sehir_disi_kisi_ad = 'Hasan Demir', sehir_disi_kisi_tel = '+905324445566' WHERE id = aile_demir;
  SELECT kisisel_kod INTO kod_elif FROM kullanici WHERE id = elif;
  istek := kodla_aileye_katil(mert, kod_elif);
  PERFORM istegi_yanitla(istek, elif, true, 'uye', 'kardeş');

  -- Elif, kızı Deniz'i ve şehir dışındaki Hasan'ı kodlarıyla davet eder.
  istek := kodla_davet_et(elif, aile_demir, (SELECT kisisel_kod FROM kullanici WHERE id = deniz));
  PERFORM istegi_yanitla(istek, deniz, true, 'cocuk', 'kızı');
  istek := kodla_davet_et(elif, aile_demir, (SELECT kisisel_kod FROM kullanici WHERE id = hasan));
  PERFORM istegi_yanitla(istek, hasan, true, 'uye', 'amca');

  -- İstanbul'daki Yılmaz ailesi: Selin, Ahmet'in kodunu girer; istek beklemede kalır.
  aile_yilmaz := aile_olustur(ahmet, 'Yılmaz Ailesi', spor);
  PERFORM kodla_aileye_katil(selin, (SELECT kisisel_kod FROM kullanici WHERE id = ahmet));

  -- Çanta durumu
  INSERT INTO aile_canta (aile_id, madde_id, var_mi, son_kullanma, guncelleyen_id)
  SELECT aile_demir, id, kod IN ('su', 'ilkyardim', 'fener', 'belge', 'duduk', 'termal'),
         CASE WHEN kod = 'su' THEN DATE '2027-03-01' END, elif
  FROM canta_maddesi WHERE bolge IS NULL OR bolge = 'dogu_anadolu';

  -- Konum izni: her açılışta sorulur
  INSERT INTO konum_izni_olayi (kullanici_id, cihaz_id, sonuc, cihaz_zamani) VALUES
    (elif, cihaz_elif, 'verildi',           now() - interval '2 days'),
    (elif, cihaz_elif, 'verildi',           now() - interval '50 minutes'),
    (mert, cihaz_mert, 'yalnizca_bu_sefer', now() - interval '45 minutes');

  -- Afet senaryosu: sarsıntı 40 dk önce. İnternet kesik; konumlar mesh ve SMS ile geliyor.
  INSERT INTO konum_kaydi (olcum_kimligi, kullanici_id, cihaz_id, enlem, boylam, dogruluk_m, kaynak, kanal, pil_yuzdesi, olcum_zamani, afet_modu) VALUES
    (gen_random_uuid(), elif, cihaz_elif, 38.3561, 38.3112, 8,  'gps', 'internet', 81, now() - interval '50 minutes', false),
    (gen_random_uuid(), elif, cihaz_elif, 38.3534, 38.3075, 6,  'gps', 'mesh',     74, now() - interval '22 minutes', true),
    (gen_random_uuid(), mert, cihaz_mert, 38.3548, 38.3130, 15, 'gps', 'mesh',     38, now() - interval '31 minutes', true),
    (gen_random_uuid(), hasan, NULL,      41.0005, 28.8570, 12, 'gps', 'internet', 92, now() - interval '35 minutes', false);
  -- Mesh ile geç gelen ESKİ bir ölçüm: son_konum'u ezmemeli
  INSERT INTO konum_kaydi (olcum_kimligi, kullanici_id, cihaz_id, enlem, boylam, dogruluk_m, kaynak, kanal, olcum_zamani, afet_modu)
  VALUES (gen_random_uuid(), elif, cihaz_elif, 38.3555, 38.3100, 10, 'gps', 'mesh', now() - interval '35 minutes', true);

  INSERT INTO durum_bildirimi (id, kullanici_id, durum, kisi_sayisi, enlem, boylam, kanal, olcum_zamani) VALUES
    (gen_random_uuid(), elif,  'bulusma_noktasinda', 2, 38.3534, 38.3075, 'mesh', now() - interval '22 minutes'),
    (gen_random_uuid(), mert,  'guvende',            1, 38.3548, 38.3130, 'mesh', now() - interval '31 minutes'),
    (gen_random_uuid(), hasan, 'guvende',            1, NULL, NULL,       'internet', now() - interval '35 minutes');

  -- Güvendeyim mesajı ve teslim kayıtları
  INSERT INTO mesaj (id, gonderen_id, aile_id, tur, metin, oncelik, olusturma_zamani)
  VALUES ('0b2f7f0e-1111-4c7a-9a1e-000000000001', mert, aile_demir, 'guvendeyim', 'Güvendeyim, buluşma noktasına gidiyorum.', 1, now() - interval '31 minutes');
  INSERT INTO mesaj_teslim (mesaj_id, alici_id, kanal, sicrama_sayisi, teslim_zamani) VALUES
    ('0b2f7f0e-1111-4c7a-9a1e-000000000001', elif,  'mesh', 3, now() - interval '27 minutes'),
    ('0b2f7f0e-1111-4c7a-9a1e-000000000001', hasan, 'sms',  0, now() - interval '30 minutes');

  -- Mahalle panosu
  INSERT INTO ilan (id, mahalle_id, olusturan_id, tur, kategori, adet, birim, aciklama, yaklasik_enlem, yaklasik_boylam, olusturma_zamani, son_teyit_zamani, kanal, dogrulanmis) VALUES
    (gen_random_uuid(), m_malatya, zeynep, 'duyuru', NULL, NULL, 'adet', 'İl AFAD: Pazar Alanı''nda çadır ve ısıtıcı dağıtımı var. Kimlik yanınızda olsun.', 38.353, 38.307, now() - interval '55 minutes', now() - interval '55 minutes', 'internet', true);
  INSERT INTO ilan (id, mahalle_id, olusturan_id, tur, kategori, adet, birim, aciklama, yaklasik_enlem, yaklasik_boylam, olusturma_zamani, son_teyit_zamani, kanal) VALUES
    ('7a1d0c55-2222-4f0b-8c3e-000000000001', m_malatya, elif, 'ihtiyac', 'battaniye', 5, 'kisilik', 'Gece çok soğuk, çadırda 5 kişiyiz', 38.353, 38.307, now() - interval '30 minutes', now() - interval '30 minutes', 'mesh'),
    ('7a1d0c55-2222-4f0b-8c3e-000000000002', m_malatya, mert, 'ihtiyac', 'ilac', 1, 'adet', 'Tansiyon ilacı, reçetesi var', 38.355, 38.313, now() - interval '14 hours', now() - interval '13 hours', 'internet'),
    ('7a1d0c55-2222-4f0b-8c3e-000000000003', m_malatya, elif, 'ihtiyac', 'su', 10, 'adet', 'Okul bahçesindeki aileler', 38.358, 38.314, now() - interval '3 hours', now() - interval '3 hours', 'internet');

  -- Zeynep battaniye ilanını üstlenir; su ilanını üstlenip teslim eder.
  UPDATE ilan SET durum = 'ustlenildi', ustlenen_id = zeynep WHERE id = '7a1d0c55-2222-4f0b-8c3e-000000000001';
  UPDATE ilan SET durum = 'ustlenildi', ustlenen_id = zeynep WHERE id = '7a1d0c55-2222-4f0b-8c3e-000000000003';
  UPDATE ilan SET durum = 'karsilandi' WHERE id = '7a1d0c55-2222-4f0b-8c3e-000000000003';

  -- Hassas veri örneği (şifreli)
  INSERT INTO destek_ihtiyaci (kullanici_id, aciklama_sifreli, muhtar_gorebilir)
  VALUES (hasan, sifrele('Merdiven inemiyor, yardımla tahliye gerekir'), true);
  INSERT INTO riza (kullanici_id, tur, metin_surumu, verildi) VALUES (hasan, 'destek_bilgisi', 'destek-2026-11', true);
END $$;

COMMIT;
