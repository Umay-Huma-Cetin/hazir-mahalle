-- =====================================================================
-- Hazır Mahalle — Telefon veritabanı örnek verisi (Elif'in telefonu)
-- Senaryo: Malatya, sarsıntıdan 40 dk sonra. İnternet yok; mesajlar
-- yakın telefonlar (mesh) ve SMS ile gidip geliyor. Kişiler uydurmadır.
-- =====================================================================
PRAGMA foreign_keys = ON;

INSERT INTO ben (tek, kullanici_id, kisisel_kod, ad, soyad, telefon, telefon_dogrulandi, il, ilce, mahalle_id, mahalle_adi,
                 acik_adres, dil, kvkk_onay_surumu, konum_onay_surumu, sunucuya_gonderildi)
VALUES (1, '5e1f0a8e-0000-4000-8000-000000000001', 'HM-7K3P-Q9WD', 'Elif', 'Demir', '+905551112233', 1,
        'Malatya', 'Yeşilyurt', 1, 'Örnek Çarşı Mahallesi', 'Örnek Sok. No:12 D:4 (uydurma adres)', 'tr',
        'aydinlatma-2026-11', 'konum-2026-11', 1);

INSERT INTO toplanma_alani (id, ad, ad_ar, ad_en, tur, enlem, boylam, kapasite_kisi, erisilebilir, kaynak, paket_surumu) VALUES
  (1, 'Pazar Alanı',           'ساحة السوق',         'Market Square',       'toplanma',       38.3532, 38.3071, 3200, 1, 'ornek_veri', '2026-10-28'),
  (2, 'Okul Bahçesi',          'ساحة المدرسة',       'School Yard',         'toplanma',       38.3581, 38.3138, 1900, 1, 'ornek_veri', '2026-10-28'),
  (3, 'Konteyner Kent Girişi', 'مدخل مجمع الحاويات', 'Container Site Gate', 'konteyner_kent', 38.3519, 38.3152, 4500, 1, 'ornek_veri', '2026-10-28');

INSERT INTO konum_izni_olayi (sonuc, zaman, gonderildi) VALUES
  ('verildi', strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-2 days'), 1),
  ('verildi', strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-50 minutes'), 0);

INSERT INTO konum_kaydi (olcum_kimligi, enlem, boylam, dogruluk_m, kaynak, pil_yuzdesi, afet_modu, olcum_zamani, gonderildi, gonderim_kanali) VALUES
  ('k-0001', 38.3561, 38.3112, 8, 'gps', 81, 0, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-50 minutes'), 1, 'internet'),
  ('k-0002', 38.3549, 38.3093, 7, 'gps', 77, 1, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-35 minutes'), 1, 'mesh'),
  ('k-0003', 38.3534, 38.3075, 6, 'gps', 74, 1, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-22 minutes'), 0, NULL);

INSERT INTO aile (aile_id, ad, benim_rolum, bulusma_alani_id, sehir_disi_kisi_ad, sehir_disi_kisi_tel, guncelleme_zamani)
VALUES ('a-demir', 'Demir Ailesi', 'yonetici', 1, 'Hasan Demir', '+905324445566', strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day'));

INSERT INTO aile_uye (aile_id, kullanici_id, ad_soyad, kisisel_kod, rol, yakinlik, telefon) VALUES
  ('a-demir', '5e1f0a8e-0000-4000-8000-000000000001', 'Elif Demir',  'HM-7K3P-Q9WD', 'yonetici', NULL,    '+905551112233'),
  ('a-demir', '5e1f0a8e-0000-4000-8000-000000000002', 'Mert Demir',  'HM-4TNA-8XRE', 'uye',      'kardeş', '+905551112234'),
  ('a-demir', '5e1f0a8e-0000-4000-8000-000000000003', 'Deniz Demir', 'HM-C2VB-M7HU', 'cocuk',    'kızı',   '+905551112235'),
  ('a-demir', '5e1f0a8e-0000-4000-8000-000000000004', 'Hasan Demir', 'HM-Y5GS-K3PZ', 'uye',      'amca',   '+905324445566');

-- Kodla katılım: Selin, Elif'in kodunu girdi; Elif'in onayını bekliyor.
INSERT INTO aile_istek (id, aile_id, yon, girilen_kod, karsi_taraf_adi, durum)
VALUES ('i-0001', 'a-demir', 'basvuru', 'HM-7K3P-Q9WD', 'Selin Yılmaz', 'beklemede');

INSERT INTO canta_maddesi (id, kod, ad_tr, ad_ar, ad_en, agirlik, bolge, sira) VALUES
  (1, 'su', 'Kişi başı en az 3 günlük içme suyu', 'مياه شرب لثلاثة أيام لكل شخص', 'Drinking water for 3 days per person', 10, NULL, 10),
  (2, 'gida', 'Bozulmayan, pişirme gerektirmeyen yiyecek', 'طعام لا يفسد ولا يحتاج إلى طهي', 'Non-perishable food', 8, NULL, 20),
  (3, 'ilkyardim', 'İlk yardım çantası', 'حقيبة إسعافات أولية', 'First aid kit', 8, NULL, 30),
  (4, 'ilac', 'Düzenli kullanılan ilaçlar ve reçete fotokopisi', 'الأدوية المعتادة ونسخة من الوصفات', 'Regular medicines and prescriptions', 8, NULL, 40),
  (5, 'fener', 'El feneri ve yedek pil', 'مصباح يدوي وبطاريات احتياطية', 'Torch and spare batteries', 6, NULL, 50),
  (6, 'powerbank', 'Dolu powerbank ve kablo', 'شاحن محمول مشحون وكابل', 'Charged power bank and cable', 6, NULL, 60),
  (7, 'radyo', 'Pilli radyo', 'راديو يعمل بالبطاريات', 'Battery radio', 4, NULL, 70),
  (8, 'duduk', 'Düdük', 'صافرة', 'Whistle', 4, NULL, 80),
  (9, 'belge', 'Kimlik ve belge fotokopileri', 'نسخ الهوية والوثائق', 'Copies of ID and documents', 6, NULL, 90),
  (10, 'nakit', 'Bir miktar nakit para', 'بعض النقود', 'Some cash', 3, NULL, 100),
  (11, 'giysi', 'Yedek giysi ve sağlam ayakkabı', 'ملابس احتياطية وحذاء متين', 'Spare clothes and sturdy shoes', 4, NULL, 110),
  (12, 'hijyen', 'Islak mendil, hijyen malzemesi, maske', 'مناديل مبللة ومستلزمات نظافة', 'Wipes, hygiene items, masks', 3, NULL, 120),
  (13, 'yatak_yani', 'Ayakkabı ve fener yatağın yanında', 'حذاء ومصباح بجانب السرير', 'Shoes and torch by the bed', 4, 'marmara', 130),
  (14, 'ikinci_canta', 'İş/okul için ikinci küçük çanta', 'حقيبة صغيرة ثانية', 'Second small bag', 4, 'marmara', 140),
  (15, 'termal', 'Termal battaniye, bere, eldiven', 'بطانية حرارية وقبعة وقفازات', 'Thermal blanket, hat, gloves', 4, 'dogu_anadolu', 150),
  (16, 'soba_kurali', 'Sobalı ortamda havalandırma kuralı okundu', 'قاعدة التهوية عند استخدام المدفأة', 'Ventilation rule read', 4, 'dogu_anadolu', 160);

INSERT INTO aile_canta (madde_id, var_mi, son_kullanma) VALUES
  (1, 1, '2027-03-01'), (3, 1, NULL), (5, 1, NULL), (8, 1, NULL), (9, 1, NULL), (15, 1, NULL);

-- Gelen Güvendeyim mesajları: tetikleyici aile_uye durumunu günceller.
INSERT INTO gelen_mesaj (id, gonderen_id, gonderen_adi, tur, metin, kanal, sicrama_sayisi, olusturma_zamani) VALUES
  ('m-0101', '5e1f0a8e-0000-4000-8000-000000000002', 'Mert Demir',  'guvendeyim', 'Güvendeyim, buluşma noktasına gidiyorum.', 'mesh', 3, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-31 minutes')),
  ('m-0102', '5e1f0a8e-0000-4000-8000-000000000004', 'Hasan Demir', 'guvendeyim', 'Güvendeyim.', 'sms', 0, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-35 minutes'));

-- Elif'in giden kutusu: Güvendeyim mesh ile iletildi; ihtiyaç ilanı internet bekliyor.
INSERT INTO giden_kutusu (id, tur, hedef, yuk, oncelik, durum, iletim_kanali, sicrama_sayisi, olusturma_zamani) VALUES
  ('g-0001', 'guvendeyim', 'aile:a-demir', json_object('metin', 'Güvendeyim, buluşma noktasındayım.', 'enlem', 38.3534, 'boylam', 38.3075), 1,
   'bekliyor', NULL, NULL, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-22 minutes')),
  ('g-0002', 'ilan', 'mahalle:1', json_object('kategori', 'battaniye', 'adet', 5, 'birim', 'kisilik', 'aciklama', 'Gece çok soğuk, çadırda 5 kişiyiz'), 2,
   'bekliyor', NULL, NULL, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-20 minutes'));
UPDATE giden_kutusu SET durum = 'iletildi', iletim_kanali = 'mesh', sicrama_sayisi = 3, deneme_sayisi = 1 WHERE id = 'g-0001';

INSERT INTO ilan (id, tur, kategori, adet, birim, aciklama, durum, dogrulanmis, benim, olusturma_zamani, son_teyit_zamani, senk_durumu) VALUES
  ('l-0001', 'duyuru', NULL, NULL, 'adet', 'İl AFAD: Pazar Alanı''nda çadır ve ısıtıcı dağıtımı var. Kimlik yanınızda olsun.', 'acik', 1, 0,
   strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-55 minutes'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-55 minutes'), 'sunucuda'),
  ('l-0002', 'ihtiyac', 'battaniye', 5, 'kisilik', 'Gece çok soğuk, çadırda 5 kişiyiz', 'acik', 0, 1,
   strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-20 minutes'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-20 minutes'), 'mesh_ile_yayildi'),
  ('l-0003', 'ihtiyac', 'ilac', 1, 'adet', 'Tansiyon ilacı, reçetesi var', 'acik', 0, 0,
   strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-14 hours'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-13 hours'), 'sunucuda');

INSERT INTO senk_durumu (tablo, son_indirme, son_gonderme) VALUES
  ('toplanma_alani', '2026-10-28T09:00:00Z', NULL),
  ('aile_uye', strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-50 minutes'));
