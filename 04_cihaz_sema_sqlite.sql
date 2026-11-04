-- =====================================================================
-- Hazır Mahalle — Telefon (cihaz) veritabanı şeması (SQLite 3.35+)
--
-- Telefondaki veritabanı internet olmadan çalışacak her şeyi tutar:
-- kullanıcının kendi kaydı, aile planı, çevrimdışı toplanma alanları,
-- konum geçmişi ve gönderilmeyi bekleyen mesajlar (giden kutusu).
-- Bağlantı geldiğinde giden kutusu sunucuya (PostgreSQL) aktarılır.
--
-- Üretimde dosya SQLCipher ile şifrelenir; anahtar Android Keystore /
-- iOS Keychain'de tutulur.
-- =====================================================================
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- ---------------------------------------------------------------------
-- 1. Kullanıcının kendisi (tek satır)
-- ---------------------------------------------------------------------
CREATE TABLE ben (
  tek               INTEGER PRIMARY KEY CHECK (tek = 1),          -- yalnızca bir satır olabilir
  kullanici_id      TEXT NOT NULL,                                -- UUID, kayıtta telefonda üretilir
  kisisel_kod       TEXT UNIQUE CHECK (kisisel_kod IS NULL OR kisisel_kod GLOB 'HM-[A-Z2-9][A-Z2-9][A-Z2-9][A-Z2-9]-[A-Z2-9][A-Z2-9][A-Z2-9][A-Z2-9]'),
  ad                TEXT NOT NULL CHECK (length(trim(ad)) BETWEEN 2 AND 60),
  soyad             TEXT NOT NULL CHECK (length(trim(soyad)) BETWEEN 2 AND 60),
  telefon           TEXT NOT NULL CHECK (telefon GLOB '+90[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'),
  telefon_dogrulandi INTEGER NOT NULL DEFAULT 0 CHECK (telefon_dogrulandi IN (0, 1)),
  il                TEXT NOT NULL,
  ilce              TEXT NOT NULL,
  mahalle_id        INTEGER,
  mahalle_adi       TEXT NOT NULL,
  acik_adres        TEXT NOT NULL,                                -- SQLCipher ile dosya düzeyinde şifreli
  dil               TEXT NOT NULL DEFAULT 'tr' CHECK (dil IN ('tr', 'ar', 'en')),
  buyuk_yazi        INTEGER NOT NULL DEFAULT 0 CHECK (buyuk_yazi IN (0, 1)),
  sade_mod          INTEGER NOT NULL DEFAULT 0 CHECK (sade_mod IN (0, 1)),
  kvkk_onay_surumu  TEXT NOT NULL,
  konum_onay_surumu TEXT NOT NULL,
  kayit_zamani      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  sunucuya_gonderildi INTEGER NOT NULL DEFAULT 0 CHECK (sunucuya_gonderildi IN (0, 1))
);

-- ---------------------------------------------------------------------
-- 2. Konum izni (her açılışta sorulur) ve konum ölçümleri
-- ---------------------------------------------------------------------
CREATE TABLE konum_izni_olayi (
  id            INTEGER PRIMARY KEY,
  sonuc         TEXT NOT NULL CHECK (sonuc IN ('verildi', 'yalnizca_bu_sefer', 'reddedildi', 'kisitli_yaklasik')),
  afet_modu     INTEGER NOT NULL DEFAULT 0 CHECK (afet_modu IN (0, 1)),
  zaman         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  gonderildi    INTEGER NOT NULL DEFAULT 0
);

-- GPS uydu sinyaliyle çalışır; internet gerekmez. Her ölçüm burada saklanır.
CREATE TABLE konum_kaydi (
  olcum_kimligi TEXT PRIMARY KEY,                                 -- UUID; sunucuda tekrar eklemeyi önler
  enlem         REAL NOT NULL CHECK (enlem BETWEEN -90 AND 90),
  boylam        REAL NOT NULL CHECK (boylam BETWEEN -180 AND 180),
  dogruluk_m    REAL CHECK (dogruluk_m >= 0),
  kaynak        TEXT NOT NULL DEFAULT 'gps' CHECK (kaynak IN ('gps', 'ag', 'manuel', 'son_bilinen')),
  pil_yuzdesi   INTEGER CHECK (pil_yuzdesi BETWEEN 0 AND 100),
  afet_modu     INTEGER NOT NULL DEFAULT 0 CHECK (afet_modu IN (0, 1)),
  olcum_zamani  TEXT NOT NULL,
  gonderildi    INTEGER NOT NULL DEFAULT 0 CHECK (gonderildi IN (0, 1)),
  gonderim_kanali TEXT CHECK (gonderim_kanali IN ('internet', 'sms', 'mesh'))
);
CREATE INDEX ix_konum_zaman ON konum_kaydi(olcum_zamani DESC);
CREATE INDEX ix_konum_bekleyen ON konum_kaydi(gonderildi) WHERE gonderildi = 0;

-- İnternet yokken bile ekranda gösterilen son konum.
CREATE VIEW v_son_konum AS
SELECT enlem, boylam, dogruluk_m, kaynak, pil_yuzdesi, olcum_zamani,
       CAST((julianday('now') - julianday(olcum_zamani)) * 1440 AS INTEGER) AS yas_dk
FROM konum_kaydi ORDER BY olcum_zamani DESC LIMIT 1;

-- ---------------------------------------------------------------------
-- 3. Çevrimdışı harita paketi: toplanma alanları
-- ---------------------------------------------------------------------
CREATE TABLE toplanma_alani (
  id            INTEGER PRIMARY KEY,                              -- sunucudaki kimlik
  ad            TEXT NOT NULL,
  ad_ar         TEXT,
  ad_en         TEXT,
  tur           TEXT NOT NULL CHECK (tur IN ('toplanma', 'gecici_barinma', 'konteyner_kent', 'saglik', 'dagitim')),
  enlem         REAL NOT NULL,
  boylam        REAL NOT NULL,
  kapasite_kisi INTEGER,
  erisilebilir  INTEGER NOT NULL DEFAULT 0,
  kaynak        TEXT NOT NULL,
  paket_surumu  TEXT NOT NULL                                     -- ekranda "son güncelleme" olarak gösterilir
);
CREATE INDEX ix_alan_koordinat ON toplanma_alani(enlem, boylam);

-- Son konuma göre toplanma alanları, yakından uzağa.
-- Kesin mesafe ve pusula yönü uygulamada (Dart) haversine ile hesaplanır;
-- burada sıralama için hızlı yaklaşık değer kullanılır (39° enlemde boylam × 0,777).
CREATE VIEW v_yakin_alanlar AS
SELECT a.id, a.ad, a.ad_ar, a.ad_en, a.tur, a.kapasite_kisi, a.erisilebilir, a.enlem, a.boylam,
       CAST(111320 * ((a.enlem - s.enlem) * (a.enlem - s.enlem) +
                      (a.boylam - s.boylam) * 0.777 * (a.boylam - s.boylam) * 0.777) * 111320 AS INTEGER) AS mesafe_kare_m2,
       a.paket_surumu
FROM toplanma_alani a, v_son_konum s
ORDER BY mesafe_kare_m2;

-- ---------------------------------------------------------------------
-- 4. Aile planı (sunucudan önbellek + kodla katılma)
-- ---------------------------------------------------------------------
CREATE TABLE aile (
  aile_id           TEXT PRIMARY KEY,
  ad                TEXT NOT NULL,
  benim_rolum       TEXT NOT NULL CHECK (benim_rolum IN ('yonetici', 'uye', 'cocuk')),
  bulusma_alani_id  INTEGER REFERENCES toplanma_alani(id),
  ikinci_bulusma_alani_id INTEGER REFERENCES toplanma_alani(id),
  sehir_disi_kisi_ad  TEXT,
  sehir_disi_kisi_tel TEXT,
  guncelleme_zamani TEXT NOT NULL
);

CREATE TABLE aile_uye (
  aile_id           TEXT NOT NULL REFERENCES aile(aile_id) ON DELETE CASCADE,
  kullanici_id      TEXT NOT NULL,
  ad_soyad          TEXT NOT NULL,
  kisisel_kod       TEXT NOT NULL,
  rol               TEXT NOT NULL CHECK (rol IN ('yonetici', 'uye', 'cocuk')),
  yakinlik          TEXT,
  telefon           TEXT,                                         -- SMS yedeği için
  son_durum         TEXT CHECK (son_durum IN ('guvende', 'yardim_gerekli', 'mahsur', 'bulusma_noktasinda')),
  son_durum_zamani  TEXT,
  son_durum_kanali  TEXT CHECK (son_durum_kanali IN ('internet', 'sms', 'mesh')),
  son_enlem         REAL,
  son_boylam        REAL,
  son_konum_zamani  TEXT,
  pil_yuzdesi       INTEGER,
  PRIMARY KEY (aile_id, kullanici_id)
);

-- Kullanıcının girdiği kodlar ve onay bekleyen istekler.
-- Kod internet yokken de girilebilir; istek giden kutusuna düşer.
CREATE TABLE aile_istek (
  id                TEXT PRIMARY KEY,                             -- UUID
  aile_id           TEXT,
  yon               TEXT NOT NULL CHECK (yon IN ('basvuru', 'davet')),
  girilen_kod       TEXT NOT NULL CHECK (girilen_kod GLOB 'HM-????-????'),
  karsi_taraf_adi   TEXT,
  durum             TEXT NOT NULL DEFAULT 'beklemede' CHECK (durum IN ('beklemede', 'onaylandi', 'reddedildi', 'iptal', 'suresi_doldu')),
  olusturma_zamani  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- ---------------------------------------------------------------------
-- 5. Deprem çantası
-- ---------------------------------------------------------------------
CREATE TABLE canta_maddesi (
  id        INTEGER PRIMARY KEY,
  kod       TEXT NOT NULL UNIQUE,
  ad_tr     TEXT NOT NULL,
  ad_ar     TEXT NOT NULL,
  ad_en     TEXT NOT NULL,
  agirlik   INTEGER NOT NULL,
  bolge     TEXT CHECK (bolge IN ('marmara', 'dogu_anadolu')),
  sira      INTEGER NOT NULL DEFAULT 100
);
CREATE TABLE aile_canta (
  madde_id          INTEGER PRIMARY KEY REFERENCES canta_maddesi(id),
  var_mi            INTEGER NOT NULL DEFAULT 0 CHECK (var_mi IN (0, 1)),
  son_kullanma      TEXT,
  guncelleme_zamani TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  gonderildi        INTEGER NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------------
-- 6. Giden kutusu: internet → SMS → yakın telefonlar (mesh) → sakla-ilet
-- ---------------------------------------------------------------------
CREATE TABLE giden_kutusu (
  id                TEXT PRIMARY KEY,                             -- UUID, sunucuda ve mesh'te aynı kalır
  tur               TEXT NOT NULL CHECK (tur IN ('guvendeyim', 'durum', 'mesaj', 'ilan', 'ilan_guncelle', 'aile_istek', 'konum')),
  hedef             TEXT NOT NULL,                                -- 'aile:<id>', 'kullanici:<id>', 'mahalle:<id>', 'sunucu'
  yuk               TEXT NOT NULL CHECK (json_valid(yuk)),        -- gönderilecek içerik (JSON)
  oncelik           INTEGER NOT NULL DEFAULT 2 CHECK (oncelik BETWEEN 1 AND 3),   -- 1 = Güvendeyim
  durum             TEXT NOT NULL DEFAULT 'geri_alinabilir'
                    CHECK (durum IN ('geri_alinabilir', 'bekliyor', 'gonderiliyor', 'iletildi', 'iptal')),
  geri_al_bitis     TEXT,                                         -- 5 sn boyunca "Geri al"
  deneme_sayisi     INTEGER NOT NULL DEFAULT 0,
  son_deneme_kanali TEXT CHECK (son_deneme_kanali IN ('internet', 'sms', 'mesh')),
  iletim_kanali     TEXT CHECK (iletim_kanali IN ('internet', 'sms', 'mesh')),
  sicrama_sayisi    INTEGER,
  olusturma_zamani  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  iletilme_zamani   TEXT
);
CREATE INDEX ix_giden_sira ON giden_kutusu(durum, oncelik, olusturma_zamani);

-- Gönderim sırası: önce Güvendeyim, sonra eski olan.
CREATE VIEW v_gonderim_sirasi AS
SELECT * FROM giden_kutusu
WHERE durum = 'bekliyor'
   OR (durum = 'geri_alinabilir' AND geri_al_bitis <= strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
ORDER BY oncelik, olusturma_zamani;

CREATE TRIGGER trg_giden_iletildi AFTER UPDATE OF durum ON giden_kutusu
WHEN NEW.durum = 'iletildi' AND OLD.durum <> 'iletildi'
BEGIN
  UPDATE giden_kutusu SET iletilme_zamani = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = NEW.id;
END;

-- Mesh ağında başkaları adına taşınan mesajlar: aynı mesaj iki kez iletilmez.
CREATE TABLE mesh_gorulen (
  mesaj_id      TEXT PRIMARY KEY,
  ilk_gorulme   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  sicrama       INTEGER NOT NULL CHECK (sicrama BETWEEN 0 AND 16),
  aktarildi     INTEGER NOT NULL DEFAULT 0,
  sifreli_yuk   BLOB NOT NULL                                     -- uçtan uca şifreli; taşıyan telefon okuyamaz
);
-- 24 saatten eski taşınan mesajlar silinir (yer ve pil tasarrufu).
CREATE TRIGGER trg_mesh_temizle AFTER INSERT ON mesh_gorulen
BEGIN
  DELETE FROM mesh_gorulen WHERE ilk_gorulme < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day');
END;

CREATE TABLE gelen_mesaj (
  id              TEXT PRIMARY KEY,
  gonderen_id     TEXT NOT NULL,
  gonderen_adi    TEXT NOT NULL,
  tur             TEXT NOT NULL,
  metin           TEXT NOT NULL,
  kanal           TEXT NOT NULL CHECK (kanal IN ('internet', 'sms', 'mesh')),
  sicrama_sayisi  INTEGER NOT NULL DEFAULT 0,
  olusturma_zamani TEXT NOT NULL,
  alinma_zamani   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  okundu          INTEGER NOT NULL DEFAULT 0
);

-- Gelen Güvendeyim mesajı aile üyesinin durumunu günceller.
CREATE TRIGGER trg_gelen_durum AFTER INSERT ON gelen_mesaj
WHEN NEW.tur = 'guvendeyim'
BEGIN
  UPDATE aile_uye
     SET son_durum = 'guvende', son_durum_zamani = NEW.olusturma_zamani, son_durum_kanali = NEW.kanal
   WHERE kullanici_id = NEW.gonderen_id
     AND (son_durum_zamani IS NULL OR son_durum_zamani < NEW.olusturma_zamani);
END;

-- ---------------------------------------------------------------------
-- 7. Mahalle panosu (önbellek)
-- ---------------------------------------------------------------------
CREATE TABLE ilan (
  id              TEXT PRIMARY KEY,
  tur             TEXT NOT NULL CHECK (tur IN ('ihtiyac', 'teklif', 'duyuru')),
  kategori        TEXT CHECK (kategori IN ('su', 'battaniye', 'ilac', 'bebek', 'gida', 'barinma', 'isinma', 'diger')),
  adet            INTEGER,
  birim           TEXT NOT NULL DEFAULT 'adet' CHECK (birim IN ('adet', 'kisilik')),
  aciklama        TEXT,
  durum           TEXT NOT NULL CHECK (durum IN ('acik', 'ustlenildi', 'karsilandi', 'iptal', 'kaldirildi')),
  dogrulanmis     INTEGER NOT NULL DEFAULT 0,
  benim           INTEGER NOT NULL DEFAULT 0,                     -- kullanıcının kendi ilanı
  ben_ustlendim   INTEGER NOT NULL DEFAULT 0,
  olusturma_zamani TEXT NOT NULL,
  son_teyit_zamani TEXT NOT NULL,
  senk_durumu     TEXT NOT NULL DEFAULT 'sunucuda' CHECK (senk_durumu IN ('telefonda', 'mesh_ile_yayildi', 'sunucuda'))
);

-- Bir gönüllü aynı anda en fazla 3 ilan üstlenebilir (sunucudaki kuralın telefondaki eşi).
CREATE TRIGGER trg_ustlenme_siniri BEFORE UPDATE OF ben_ustlendim ON ilan
WHEN NEW.ben_ustlendim = 1 AND OLD.ben_ustlendim = 0
 AND (SELECT count(*) FROM ilan WHERE ben_ustlendim = 1 AND durum = 'ustlenildi') >= 3
BEGIN
  SELECT RAISE(ABORT, 'Aynı anda en fazla 3 ilan üstlenebilirsiniz. Önce birini teslim edin.');
END;

-- ---------------------------------------------------------------------
-- 8. Senkronizasyon durumu
-- ---------------------------------------------------------------------
CREATE TABLE senk_durumu (
  tablo           TEXT PRIMARY KEY,
  son_indirme     TEXT,                                           -- sunucudan son çekilen zaman
  son_gonderme    TEXT
);

-- Hazırlık skoru (telefonda, internetsiz).
CREATE VIEW v_hazirlik_skoru AS
WITH bolge AS (
  SELECT CASE WHEN il IN ('İstanbul', 'Kocaeli', 'Sakarya', 'Yalova', 'Tekirdağ', 'Bursa') THEN 'marmara'
              ELSE 'dogu_anadolu' END AS b FROM ben
), canta AS (
  SELECT sum(CASE WHEN ac.var_mi = 1 THEN m.agirlik ELSE 0 END) AS sahip, sum(m.agirlik) AS toplam,
         sum(CASE WHEN ac.var_mi = 1 THEN 1 ELSE 0 END) AS hazir_madde, count(*) AS toplam_madde
  FROM canta_maddesi m LEFT JOIN aile_canta ac ON ac.madde_id = m.id, bolge
  WHERE m.bolge IS NULL OR m.bolge = bolge.b
), plan AS (
  SELECT (CASE WHEN max(bulusma_alani_id) IS NOT NULL THEN 10 ELSE 0 END) +
         (CASE WHEN max(sehir_disi_kisi_tel) IS NOT NULL THEN 10 ELSE 0 END) +
         (CASE WHEN (SELECT count(*) FROM aile_uye) >= 2 THEN 10 ELSE 0 END) AS puan
  FROM aile
)
SELECT CAST(round(coalesce(canta.sahip, 0) * 70.0 / canta.toplam + plan.puan) AS INTEGER) AS skor,
       canta.hazir_madde, canta.toplam_madde, plan.puan AS plan_puani
FROM canta, plan;
