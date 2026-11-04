-- =====================================================================
-- Hazır Mahalle — Sunucu veritabanı şeması (PostgreSQL 14+)
-- Proje: Hazır Mahalle afet hazırlık ve dayanışma uygulaması
-- Hazırlayan: Umay Hüma Çetin
--
-- Tasarım ilkeleri
--   1. Offline-first: telefonlar kimlikleri (UUID) kendileri üretir, veri
--      internet gelince gönderilir. Aynı kayıt iki kez gelirse tekrar
--      eklenmez (idempotent).
--   2. KVKK: adres ve destek ihtiyacı şifreli saklanır, her rıza ayrı ve
--      sürümlü kaydedilir, konum geçmişi saklama süresi sonunda silinir.
--   3. Kişisel kod: her kullanıcının HM-XXXX-XXXX biçiminde, karıştırılan
--      karakterler (0/O, 1/I/L) olmadan üretilmiş bir kodu vardır. Aile
--      planına bu kodla katılınır; katılım aile yöneticisinin onayıyla
--      kesinleşir.
--   4. Konum: her ölçüm cihazda zaman damgasıyla tutulur (GPS internetsiz
--      çalışır), sunucuya ulaştığında son_konum tablosu otomatik güncellenir.
--
-- Kurulum:  psql -d hazir_mahalle -f 01_sunucu_sema_postgresql.sql
-- =====================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS hm;
SET search_path TO hm, public;

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid(), pgp_sym_encrypt()
CREATE EXTENSION IF NOT EXISTS citext;     -- büyük/küçük harf duyarsız kod araması

-- ---------------------------------------------------------------------
-- 0. Sabit değer kümeleri (ENUM)
-- ---------------------------------------------------------------------
CREATE TYPE dil_kodu            AS ENUM ('tr', 'ar', 'en');
CREATE TYPE pilot_bolge         AS ENUM ('marmara', 'dogu_anadolu');
CREATE TYPE aile_rolu           AS ENUM ('yonetici', 'uye', 'cocuk');
CREATE TYPE istek_durumu        AS ENUM ('beklemede', 'onaylandi', 'reddedildi', 'iptal', 'suresi_doldu');
CREATE TYPE konum_kaynagi       AS ENUM ('gps', 'ag', 'manuel', 'son_bilinen');
CREATE TYPE iletim_kanali       AS ENUM ('internet', 'sms', 'mesh', 'sakla_ilet');
CREATE TYPE izin_sonucu         AS ENUM ('verildi', 'yalnizca_bu_sefer', 'reddedildi', 'kisitli_yaklasik');
CREATE TYPE riza_turu           AS ENUM ('kvkk_aydinlatma', 'konum_isleme', 'aile_konum_paylasimi',
                                         'destek_bilgisi', 'mahalle_panosu', 'bildirim');
CREATE TYPE alan_turu           AS ENUM ('toplanma', 'gecici_barinma', 'konteyner_kent', 'saglik', 'dagitim');
CREATE TYPE durum_turu          AS ENUM ('guvende', 'yardim_gerekli', 'mahsur', 'bulusma_noktasinda');
CREATE TYPE ilan_turu           AS ENUM ('ihtiyac', 'teklif', 'duyuru');
CREATE TYPE ilan_durumu         AS ENUM ('acik', 'ustlenildi', 'karsilandi', 'iptal', 'kaldirildi');
CREATE TYPE ilan_kategori       AS ENUM ('su', 'battaniye', 'ilac', 'bebek', 'gida', 'barinma', 'isinma', 'diger');
CREATE TYPE birim_turu          AS ENUM ('adet', 'kisilik');
CREATE TYPE mesaj_turu          AS ENUM ('guvendeyim', 'bulusma', 'yardim', 'serbest');

-- ---------------------------------------------------------------------
-- 1. Yardımcı fonksiyonlar
-- ---------------------------------------------------------------------

-- İki koordinat arası mesafe (metre, haversine). Uzantı gerektirmez.
CREATE OR REPLACE FUNCTION mesafe_m(enlem1 double precision, boylam1 double precision,
                                    enlem2 double precision, boylam2 double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT 2 * 6371000 * asin(sqrt(
           power(sin(radians(enlem2 - enlem1) / 2), 2) +
           cos(radians(enlem1)) * cos(radians(enlem2)) *
           power(sin(radians(boylam2 - boylam1) / 2), 2)));
$$;

-- Yön (derece, kuzey = 0) — pusula oku için.
CREATE OR REPLACE FUNCTION yon_derece(enlem1 double precision, boylam1 double precision,
                                      enlem2 double precision, boylam2 double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT mod((degrees(atan2(
           sin(radians(boylam2 - boylam1)) * cos(radians(enlem2)),
           cos(radians(enlem1)) * sin(radians(enlem2)) -
           sin(radians(enlem1)) * cos(radians(enlem2)) * cos(radians(boylam2 - boylam1))
         )) + 360)::numeric, 360)::double precision;
$$;

-- Kişisel kod üretimi: HM-XXXX-XXXX (31 karakterlik alfabe, ~852 milyar olasılık).
CREATE OR REPLACE FUNCTION kisisel_kod_uret() RETURNS citext LANGUAGE plpgsql AS $$
DECLARE
  alfabe constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  kod text;
  b bytea;
BEGIN
  LOOP
    b := gen_random_bytes(8);
    kod := 'HM-';
    FOR i IN 0..7 LOOP
      IF i = 4 THEN kod := kod || '-'; END IF;
      kod := kod || substr(alfabe, (get_byte(b, i) % length(alfabe)) + 1, 1);
    END LOOP;
    EXIT WHEN NOT EXISTS (SELECT 1 FROM hm.kullanici WHERE kisisel_kod = kod::citext);
  END LOOP;
  RETURN kod::citext;
END $$;

-- Telefon numarasını +90XXXXXXXXXX biçimine getirir.
CREATE OR REPLACE FUNCTION telefon_normalle(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
           WHEN d ~ '^90[0-9]{10}$' THEN '+' || d
           WHEN d ~ '^0[0-9]{10}$'  THEN '+9' || d
           WHEN d ~ '^[0-9]{10}$'   THEN '+90' || d
           ELSE NULL END
  FROM (SELECT regexp_replace(coalesce(t, ''), '[^0-9]', '', 'g') AS d) x;
$$;

-- Şifreleme anahtarı oturum ayarından okunur; anahtar asla tabloda durmaz.
--   SET hm.sifre_anahtari = '...';   (uygulama sunucusu bağlanırken ayarlar)
CREATE OR REPLACE FUNCTION sifrele(metin text) RETURNS bytea LANGUAGE sql AS $$
  SELECT CASE WHEN metin IS NULL THEN NULL
              ELSE pgp_sym_encrypt(metin, current_setting('hm.sifre_anahtari')) END;
$$;
CREATE OR REPLACE FUNCTION coz(veri bytea) RETURNS text LANGUAGE sql AS $$
  SELECT CASE WHEN veri IS NULL THEN NULL
              ELSE pgp_sym_decrypt(veri, current_setting('hm.sifre_anahtari')) END;
$$;

-- guncelleme_zamani sütununu otomatik yeniler.
CREATE OR REPLACE FUNCTION guncelleme_damgasi() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.guncelleme_zamani := now(); RETURN NEW; END $$;

-- ---------------------------------------------------------------------
-- 2. Yer bilgisi: il / ilçe / mahalle
-- ---------------------------------------------------------------------
CREATE TABLE il (
  id            smallint PRIMARY KEY,                 -- plaka kodu
  ad            text NOT NULL UNIQUE,
  bolge         pilot_bolge                           -- pilot bölgelerden biri değilse NULL
);

CREATE TABLE ilce (
  id            serial PRIMARY KEY,
  il_id         smallint NOT NULL REFERENCES il(id),
  ad            text NOT NULL,
  UNIQUE (il_id, ad)
);

CREATE TABLE mahalle (
  id            serial PRIMARY KEY,
  ilce_id       integer NOT NULL REFERENCES ilce(id),
  ad            text NOT NULL,
  merkez_enlem  double precision CHECK (merkez_enlem BETWEEN 35 AND 43),
  merkez_boylam double precision CHECK (merkez_boylam BETWEEN 25 AND 45),
  nufus_tahmini integer CHECK (nufus_tahmini >= 0),
  pilot         boolean NOT NULL DEFAULT false,
  UNIQUE (ilce_id, ad)
);

-- ---------------------------------------------------------------------
-- 3. Kullanıcı, adres, cihaz
-- ---------------------------------------------------------------------
CREATE TABLE kullanici (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kisisel_kod         citext NOT NULL UNIQUE DEFAULT kisisel_kod_uret()
                      CHECK (kisisel_kod ~* '^HM-[A-HJKMNP-Z2-9]{4}-[A-HJKMNP-Z2-9]{4}$'),
  ad                  text NOT NULL CHECK (length(trim(ad)) BETWEEN 2 AND 60),
  soyad               text NOT NULL CHECK (length(trim(soyad)) BETWEEN 2 AND 60),
  telefon             text NOT NULL UNIQUE CHECK (telefon ~ '^\+90[0-9]{10}$'),
  telefon_dogrulandi  boolean NOT NULL DEFAULT false,
  mahalle_id          integer REFERENCES mahalle(id),
  dil                 dil_kodu NOT NULL DEFAULT 'tr',
  buyuk_yazi          boolean NOT NULL DEFAULT false,
  sade_mod            boolean NOT NULL DEFAULT false,    -- yaşlılar için 4 butonlu arayüz
  olusturma_zamani    timestamptz NOT NULL DEFAULT now(),
  guncelleme_zamani   timestamptz NOT NULL DEFAULT now(),
  son_giris_zamani    timestamptz,
  silinme_talebi      timestamptz                        -- KVKK silme talebi; iş kuralıyla anonimleştirilir
);
CREATE TRIGGER trg_kullanici_guncelleme BEFORE UPDATE ON kullanici
  FOR EACH ROW EXECUTE FUNCTION guncelleme_damgasi();

-- Telefon her yazımda normal biçime getirilir.
CREATE OR REPLACE FUNCTION kullanici_telefon_normalle() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.telefon := coalesce(telefon_normalle(NEW.telefon), NEW.telefon);
  NEW.ad := initcap(trim(NEW.ad));
  NEW.soyad := initcap(trim(NEW.soyad));  -- büyük harf dönüşümü uygulamada yapılır (Türkçe İ/I kuralı)
  RETURN NEW;
END $$;
CREATE TRIGGER trg_kullanici_normalle BEFORE INSERT OR UPDATE OF telefon, ad, soyad ON kullanici
  FOR EACH ROW EXECUTE FUNCTION kullanici_telefon_normalle();

-- Açık adres şifreli. Panoda ve haritada yalnızca ~100 m'ye yuvarlanmış konum kullanılır.
CREATE TABLE kullanici_adres (
  kullanici_id      uuid PRIMARY KEY REFERENCES kullanici(id) ON DELETE CASCADE,
  mahalle_id        integer NOT NULL REFERENCES mahalle(id),
  acik_adres_sifreli bytea NOT NULL,                    -- sokak, bina no, daire (pgp_sym_encrypt)
  bina_kat_sayisi   smallint CHECK (bina_kat_sayisi BETWEEN 1 AND 60),
  daire_kati        smallint CHECK (daire_kati BETWEEN -3 AND 60),
  yaklasik_enlem    numeric(7,4),                       -- 4 basamak ≈ 11 m; görüntülemede 3 basamağa yuvarlanır
  yaklasik_boylam   numeric(7,4),
  guncelleme_zamani timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_adres_guncelleme BEFORE UPDATE ON kullanici_adres
  FOR EACH ROW EXECUTE FUNCTION guncelleme_damgasi();

CREATE TABLE cihaz (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kullanici_id      uuid NOT NULL REFERENCES kullanici(id) ON DELETE CASCADE,
  platform          text NOT NULL CHECK (platform IN ('android', 'ios')),
  uygulama_surumu   text NOT NULL,
  mesh_kimligi      text UNIQUE,                        -- Bridgefy vb. SDK'nın cihaz kimliği
  bildirim_jetonu   text,
  harita_paketi_surumu date,                           -- telefona indirilmiş çevrimdışı harita
  son_gorulme       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_cihaz_kullanici ON cihaz(kullanici_id);

-- ---------------------------------------------------------------------
-- 4. KVKK: rıza ve konum izni kayıtları (yalnızca ekleme yapılır)
-- ---------------------------------------------------------------------
CREATE TABLE riza (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kullanici_id    uuid NOT NULL REFERENCES kullanici(id) ON DELETE CASCADE,
  tur             riza_turu NOT NULL,
  metin_surumu    text NOT NULL,                        -- örn. 'aydinlatma-2026-11'
  verildi         boolean NOT NULL,                     -- false = geri çekildi
  zaman           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_riza_son ON riza(kullanici_id, tur, zaman DESC);

-- Uygulama her açıldığında sorulan konum izninin sonucu.
CREATE TABLE konum_izni_olayi (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kullanici_id    uuid NOT NULL REFERENCES kullanici(id) ON DELETE CASCADE,
  cihaz_id        uuid REFERENCES cihaz(id) ON DELETE SET NULL,
  sonuc           izin_sonucu NOT NULL,
  afet_modu       boolean NOT NULL DEFAULT false,
  cihaz_zamani    timestamptz NOT NULL,
  alinma_zamani   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_izin_kullanici ON konum_izni_olayi(kullanici_id, cihaz_zamani DESC);

-- ---------------------------------------------------------------------
-- 5. Konum
-- ---------------------------------------------------------------------
-- Ölçümler telefonda zaman damgasıyla kaydedilir; internet/SMS/mesh ile
-- sunucuya ulaşır. olcum_kimligi telefonda üretilir, tekrar gönderimi engeller.
CREATE TABLE konum_kaydi (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  olcum_kimligi   uuid NOT NULL UNIQUE,
  kullanici_id    uuid NOT NULL REFERENCES kullanici(id) ON DELETE CASCADE,
  cihaz_id        uuid REFERENCES cihaz(id) ON DELETE SET NULL,
  enlem           double precision NOT NULL CHECK (enlem BETWEEN -90 AND 90),
  boylam          double precision NOT NULL CHECK (boylam BETWEEN -180 AND 180),
  dogruluk_m      real CHECK (dogruluk_m >= 0),
  kaynak          konum_kaynagi NOT NULL DEFAULT 'gps',
  kanal           iletim_kanali NOT NULL DEFAULT 'internet',
  pil_yuzdesi     smallint CHECK (pil_yuzdesi BETWEEN 0 AND 100),
  olcum_zamani    timestamptz NOT NULL,                -- telefonun saati
  alinma_zamani   timestamptz NOT NULL DEFAULT now(),  -- sunucuya ulaştığı an
  afet_modu       boolean NOT NULL DEFAULT false
);
CREATE INDEX ix_konum_kullanici_zaman ON konum_kaydi(kullanici_id, olcum_zamani DESC);
CREATE INDEX ix_konum_saklama ON konum_kaydi(alinma_zamani) WHERE NOT afet_modu;

-- Her kullanıcının en güncel konumu (sorgular için hızlı erişim).
CREATE TABLE son_konum (
  kullanici_id    uuid PRIMARY KEY REFERENCES kullanici(id) ON DELETE CASCADE,
  enlem           double precision NOT NULL,
  boylam          double precision NOT NULL,
  dogruluk_m      real,
  kaynak          konum_kaynagi NOT NULL,
  kanal           iletim_kanali NOT NULL,
  pil_yuzdesi     smallint,
  olcum_zamani    timestamptz NOT NULL
);

-- Yeni ölçüm, eldeki son konumdan daha yeniyse son_konum'u günceller.
-- (Mesh ile geç gelen eski ölçüm son konumu ezmez.)
CREATE OR REPLACE FUNCTION son_konumu_guncelle() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO son_konum AS s (kullanici_id, enlem, boylam, dogruluk_m, kaynak, kanal, pil_yuzdesi, olcum_zamani)
  VALUES (NEW.kullanici_id, NEW.enlem, NEW.boylam, NEW.dogruluk_m, NEW.kaynak, NEW.kanal, NEW.pil_yuzdesi, NEW.olcum_zamani)
  ON CONFLICT (kullanici_id) DO UPDATE
     SET enlem = EXCLUDED.enlem, boylam = EXCLUDED.boylam, dogruluk_m = EXCLUDED.dogruluk_m,
         kaynak = EXCLUDED.kaynak, kanal = EXCLUDED.kanal, pil_yuzdesi = EXCLUDED.pil_yuzdesi,
         olcum_zamani = EXCLUDED.olcum_zamani
   WHERE s.olcum_zamani < EXCLUDED.olcum_zamani;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_son_konum AFTER INSERT ON konum_kaydi
  FOR EACH ROW EXECUTE FUNCTION son_konumu_guncelle();

-- ---------------------------------------------------------------------
-- 6. Toplanma alanları (çevrimdışı paket olarak telefona indirilir)
-- ---------------------------------------------------------------------
CREATE TABLE toplanma_alani (
  id                 serial PRIMARY KEY,
  mahalle_id         integer NOT NULL REFERENCES mahalle(id),
  ad                 text NOT NULL,
  ad_ar              text,
  ad_en              text,
  tur                alan_turu NOT NULL DEFAULT 'toplanma',
  enlem              double precision NOT NULL CHECK (enlem BETWEEN 35 AND 43),
  boylam             double precision NOT NULL CHECK (boylam BETWEEN 25 AND 45),
  alan_m2            integer CHECK (alan_m2 > 0),
  kapasite_kisi      integer GENERATED ALWAYS AS (alan_m2 / 2) STORED,  -- kişi başı ~2 m² varsayımı
  erisilebilir       boolean NOT NULL DEFAULT false,   -- tekerlekli sandalye ile ulaşılabilir
  kaynak             text NOT NULL,                    -- 'afad', 'ibb_acik_veri', 'muhtarlik', 'ornek_veri'
  dogrulama_tarihi   date,
  aktif              boolean NOT NULL DEFAULT true,
  paket_surumu       date NOT NULL DEFAULT current_date
);
CREATE INDEX ix_alan_mahalle ON toplanma_alani(mahalle_id) WHERE aktif;
CREATE INDEX ix_alan_koordinat ON toplanma_alani(enlem, boylam) WHERE aktif;

-- ---------------------------------------------------------------------
-- 7. Aile planı ve kodla katılım
-- ---------------------------------------------------------------------
CREATE TABLE aile (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ad                  text NOT NULL CHECK (length(ad) BETWEEN 2 AND 60),
  olusturan_id        uuid NOT NULL REFERENCES kullanici(id),
  bulusma_alani_id    integer REFERENCES toplanma_alani(id),
  ikinci_bulusma_alani_id integer REFERENCES toplanma_alani(id),   -- İstanbul: diğer yaka
  sehir_disi_kisi_ad  text,
  sehir_disi_kisi_tel text CHECK (sehir_disi_kisi_tel IS NULL OR sehir_disi_kisi_tel ~ '^\+90[0-9]{10}$'),
  olusturma_zamani    timestamptz NOT NULL DEFAULT now(),
  guncelleme_zamani   timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_aile_guncelleme BEFORE UPDATE ON aile
  FOR EACH ROW EXECUTE FUNCTION guncelleme_damgasi();

CREATE TABLE aile_uye (
  aile_id             uuid NOT NULL REFERENCES aile(id) ON DELETE CASCADE,
  kullanici_id        uuid NOT NULL REFERENCES kullanici(id) ON DELETE CASCADE,
  rol                 aile_rolu NOT NULL DEFAULT 'uye',
  yakinlik            text,                             -- 'anne', 'kardeş', 'amca' …
  konum_paylasimi     boolean NOT NULL DEFAULT true,    -- aile içinde son konumunu paylaşır
  katilma_zamani      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (aile_id, kullanici_id)
);
CREATE INDEX ix_aile_uye_kullanici ON aile_uye(kullanici_id);
-- Her ailede en az bir yönetici: oluşturan otomatik yönetici olur (aile_olustur fonksiyonu).

-- Kodla katılım isteği. İki yön desteklenir:
--   basvuru : kullanıcı, ailedeki birinin kodunu girer → yönetici onaylar
--   davet   : yönetici, eklemek istediği kişinin kodunu girer → kişi onaylar
CREATE TABLE aile_istek (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  aile_id             uuid NOT NULL REFERENCES aile(id) ON DELETE CASCADE,
  yon                 text NOT NULL CHECK (yon IN ('basvuru', 'davet')),
  isteyen_id          uuid NOT NULL REFERENCES kullanici(id) ON DELETE CASCADE,
  hedef_kullanici_id  uuid NOT NULL REFERENCES kullanici(id) ON DELETE CASCADE,
  girilen_kod         citext NOT NULL,
  durum               istek_durumu NOT NULL DEFAULT 'beklemede',
  yanitlayan_id       uuid REFERENCES kullanici(id),
  olusturma_zamani    timestamptz NOT NULL DEFAULT now(),
  son_gecerlilik      timestamptz NOT NULL DEFAULT now() + interval '7 days',
  yanit_zamani        timestamptz,
  CHECK (isteyen_id <> hedef_kullanici_id)
);
-- Aynı kişi aynı aileye aynı anda tek bekleyen istek açabilir.
CREATE UNIQUE INDEX ux_aile_istek_bekleyen
  ON aile_istek(aile_id, LEAST(isteyen_id, hedef_kullanici_id), GREATEST(isteyen_id, hedef_kullanici_id))
  WHERE durum = 'beklemede';

-- ---------------------------------------------------------------------
-- 8. Deprem çantası
-- ---------------------------------------------------------------------
CREATE TABLE canta_maddesi (
  id              serial PRIMARY KEY,
  kod             text NOT NULL UNIQUE,
  ad_tr           text NOT NULL,
  ad_ar           text NOT NULL,
  ad_en           text NOT NULL,
  agirlik         smallint NOT NULL CHECK (agirlik BETWEEN 1 AND 20),  -- hazırlık skoruna katkısı
  bolge           pilot_bolge,                                        -- NULL = herkese
  son_kullanma_takibi boolean NOT NULL DEFAULT false,
  sira            smallint NOT NULL DEFAULT 100
);

CREATE TABLE aile_canta (
  aile_id           uuid NOT NULL REFERENCES aile(id) ON DELETE CASCADE,
  madde_id          integer NOT NULL REFERENCES canta_maddesi(id),
  var_mi            boolean NOT NULL DEFAULT false,
  son_kullanma      date,
  guncelleyen_id    uuid REFERENCES kullanici(id),
  guncelleme_zamani timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (aile_id, madde_id)
);
CREATE TRIGGER trg_canta_guncelleme BEFORE UPDATE ON aile_canta
  FOR EACH ROW EXECUTE FUNCTION guncelleme_damgasi();

-- ---------------------------------------------------------------------
-- 9. Afet anı: durum bildirimi ve mesajlaşma
-- ---------------------------------------------------------------------
CREATE TABLE durum_bildirimi (
  id              uuid PRIMARY KEY,                     -- telefonda üretilir
  kullanici_id    uuid NOT NULL REFERENCES kullanici(id) ON DELETE CASCADE,
  durum           durum_turu NOT NULL,
  kisi_sayisi     smallint CHECK (kisi_sayisi BETWEEN 1 AND 50),
  enlem           double precision,
  boylam          double precision,
  kanal           iletim_kanali NOT NULL,
  olcum_zamani    timestamptz NOT NULL,
  alinma_zamani   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_durum_kullanici ON durum_bildirimi(kullanici_id, olcum_zamani DESC);

CREATE TABLE mesaj (
  id              uuid PRIMARY KEY,                     -- telefonda üretilir; mesh tekrarlarını eler
  gonderen_id     uuid NOT NULL REFERENCES kullanici(id) ON DELETE CASCADE,
  aile_id         uuid REFERENCES aile(id) ON DELETE CASCADE,
  alici_id        uuid REFERENCES kullanici(id) ON DELETE CASCADE,
  tur             mesaj_turu NOT NULL,
  metin           text NOT NULL CHECK (length(metin) <= 280),
  oncelik         smallint NOT NULL DEFAULT 2 CHECK (oncelik BETWEEN 1 AND 3),  -- 1: Güvendeyim
  olusturma_zamani timestamptz NOT NULL,
  CHECK ((aile_id IS NOT NULL) <> (alici_id IS NOT NULL))
);

-- Her alıcıya hangi kanaldan, kaç sıçramayla ulaştı.
CREATE TABLE mesaj_teslim (
  mesaj_id        uuid NOT NULL REFERENCES mesaj(id) ON DELETE CASCADE,
  alici_id        uuid NOT NULL REFERENCES kullanici(id) ON DELETE CASCADE,
  kanal           iletim_kanali NOT NULL,
  sicrama_sayisi  smallint NOT NULL DEFAULT 0 CHECK (sicrama_sayisi BETWEEN 0 AND 16),
  teslim_zamani   timestamptz NOT NULL DEFAULT now(),
  okundu_zamani   timestamptz,
  PRIMARY KEY (mesaj_id, alici_id)
);

-- ---------------------------------------------------------------------
-- 10. Mahalle panosu
-- ---------------------------------------------------------------------
CREATE TABLE ilan (
  id              uuid PRIMARY KEY,                     -- telefonda üretilir (offline kuyruk)
  mahalle_id      integer NOT NULL REFERENCES mahalle(id),
  olusturan_id    uuid NOT NULL REFERENCES kullanici(id),
  tur             ilan_turu NOT NULL,
  kategori        ilan_kategori,
  adet            smallint CHECK (adet BETWEEN 1 AND 999),
  birim           birim_turu NOT NULL DEFAULT 'adet',
  aciklama        text CHECK (length(aciklama) <= 280),
  yaklasik_enlem  numeric(6,3),                          -- ~100 m hassasiyet, tam adres değil
  yaklasik_boylam numeric(6,3),
  durum           ilan_durumu NOT NULL DEFAULT 'acik',
  ustlenen_id     uuid REFERENCES kullanici(id),
  dogrulanmis     boolean NOT NULL DEFAULT false,       -- muhtar / resmî kaynak
  olusturma_zamani timestamptz NOT NULL,
  son_teyit_zamani timestamptz NOT NULL,                -- "hâlâ geçerli mi?" yanıtı
  kanal           iletim_kanali NOT NULL DEFAULT 'internet',
  CHECK (tur = 'duyuru' OR kategori IS NOT NULL),
  CHECK (NOT dogrulanmis OR tur = 'duyuru'),
  CHECK (durum <> 'ustlenildi' OR ustlenen_id IS NOT NULL)
);
CREATE INDEX ix_ilan_mahalle_acik ON ilan(mahalle_id, kategori) WHERE durum IN ('acik', 'ustlenildi');

CREATE TABLE ilan_hareket (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ilan_id         uuid NOT NULL REFERENCES ilan(id) ON DELETE CASCADE,
  kullanici_id    uuid REFERENCES kullanici(id),
  eski_durum      ilan_durumu,
  yeni_durum      ilan_durumu NOT NULL,
  zaman           timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ilan_bildirim (                            -- "bildir" butonu (yanlış / kötüye kullanım)
  ilan_id         uuid NOT NULL REFERENCES ilan(id) ON DELETE CASCADE,
  bildiren_id     uuid NOT NULL REFERENCES kullanici(id) ON DELETE CASCADE,
  neden           text NOT NULL CHECK (neden IN ('yanlis', 'tekrar', 'gecersiz', 'uygunsuz')),
  zaman           timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (ilan_id, bildiren_id)
);

-- İş kuralları: geçerli durum geçişleri ve gönüllü başına en fazla 3 aktif ilan.
CREATE OR REPLACE FUNCTION ilan_kurallari() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE aktif int;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.durum <> OLD.durum THEN
    IF NOT ((OLD.durum = 'acik'       AND NEW.durum IN ('ustlenildi', 'karsilandi', 'iptal', 'kaldirildi'))
         OR (OLD.durum = 'ustlenildi' AND NEW.durum IN ('acik', 'karsilandi', 'iptal', 'kaldirildi'))) THEN
      RAISE EXCEPTION 'Geçersiz ilan durumu geçişi: % → %', OLD.durum, NEW.durum;
    END IF;
    IF NEW.durum = 'acik' THEN NEW.ustlenen_id := NULL; END IF;
  END IF;
  IF NEW.durum = 'ustlenildi' AND (TG_OP = 'INSERT' OR OLD.ustlenen_id IS DISTINCT FROM NEW.ustlenen_id) THEN
    SELECT count(*) INTO aktif FROM ilan WHERE ustlenen_id = NEW.ustlenen_id AND durum = 'ustlenildi' AND id <> NEW.id;
    IF aktif >= 3 THEN
      RAISE EXCEPTION 'Bir gönüllü aynı anda en fazla 3 ilan üstlenebilir';
    END IF;
    IF NEW.ustlenen_id = NEW.olusturan_id THEN
      RAISE EXCEPTION 'Kişi kendi ilanını üstlenemez';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_ilan_kurallari BEFORE INSERT OR UPDATE ON ilan
  FOR EACH ROW EXECUTE FUNCTION ilan_kurallari();

CREATE OR REPLACE FUNCTION ilan_hareket_yaz() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO ilan_hareket(ilan_id, kullanici_id, eski_durum, yeni_durum) VALUES (NEW.id, NEW.olusturan_id, NULL, NEW.durum);
  ELSIF NEW.durum <> OLD.durum THEN
    INSERT INTO ilan_hareket(ilan_id, kullanici_id, eski_durum, yeni_durum)
    VALUES (NEW.id, coalesce(NEW.ustlenen_id, OLD.ustlenen_id, NEW.olusturan_id), OLD.durum, NEW.durum);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_ilan_hareket AFTER INSERT OR UPDATE ON ilan
  FOR EACH ROW EXECUTE FUNCTION ilan_hareket_yaz();

-- ---------------------------------------------------------------------
-- 11. Hassas veri: destek ihtiyacı (KVKK özel nitelikli — ayrı tablo, şifreli)
-- ---------------------------------------------------------------------
CREATE TABLE destek_ihtiyaci (
  kullanici_id      uuid PRIMARY KEY REFERENCES kullanici(id) ON DELETE CASCADE,
  aciklama_sifreli  bytea NOT NULL,                     -- örn. "tekerlekli sandalye kullanıyor"
  muhtar_gorebilir  boolean NOT NULL DEFAULT false,
  guncelleme_zamani timestamptz NOT NULL DEFAULT now()
);

-- Hassas tablolara her erişim/değişiklik kaydı.
CREATE TABLE denetim_kaydi (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tablo           text NOT NULL,
  islem           text NOT NULL,
  kayit_kimligi   text,
  islem_yapan     text NOT NULL DEFAULT current_user,
  zaman           timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION denetle() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO denetim_kaydi(tablo, islem, kayit_kimligi)
  VALUES (TG_TABLE_NAME, TG_OP, coalesce(NEW.kullanici_id, OLD.kullanici_id)::text);
  RETURN coalesce(NEW, OLD);
END $$;
CREATE TRIGGER trg_denetim_adres   AFTER INSERT OR UPDATE OR DELETE ON kullanici_adres  FOR EACH ROW EXECUTE FUNCTION denetle();
CREATE TRIGGER trg_denetim_destek  AFTER INSERT OR UPDATE OR DELETE ON destek_ihtiyaci  FOR EACH ROW EXECUTE FUNCTION denetle();

-- ---------------------------------------------------------------------
-- 12. İş akışı fonksiyonları
-- ---------------------------------------------------------------------

-- Kayıt: kullanıcı + şifreli adres + zorunlu rızalar tek işlemde.
CREATE OR REPLACE FUNCTION kullanici_kaydet(p_ad text, p_soyad text, p_telefon text, p_mahalle_id integer,
                                            p_acik_adres text, p_dil dil_kodu DEFAULT 'tr',
                                            p_enlem numeric DEFAULT NULL, p_boylam numeric DEFAULT NULL,
                                            p_riza_surumu text DEFAULT 'aydinlatma-2026-11')
RETURNS TABLE (kullanici_id uuid, kisisel_kod citext) LANGUAGE plpgsql AS $$
DECLARE yeni uuid; kod citext;
BEGIN
  IF telefon_normalle(p_telefon) IS NULL THEN
    RAISE EXCEPTION 'Telefon numarası geçersiz: 10 haneli cep numarası girin (5XX XXX XX XX)';
  END IF;
  INSERT INTO kullanici(ad, soyad, telefon, mahalle_id, dil)
  VALUES (p_ad, p_soyad, p_telefon, p_mahalle_id, p_dil)
  RETURNING id, kullanici.kisisel_kod INTO yeni, kod;

  INSERT INTO kullanici_adres(kullanici_id, mahalle_id, acik_adres_sifreli, yaklasik_enlem, yaklasik_boylam)
  VALUES (yeni, p_mahalle_id, sifrele(p_acik_adres), round(p_enlem, 4), round(p_boylam, 4));

  INSERT INTO riza(kullanici_id, tur, metin_surumu, verildi) VALUES
    (yeni, 'kvkk_aydinlatma', p_riza_surumu, true),
    (yeni, 'konum_isleme',    p_riza_surumu, true);
  RETURN QUERY SELECT yeni, kod;
END $$;

-- Aile oluşturma: oluşturan yönetici olarak eklenir.
CREATE OR REPLACE FUNCTION aile_olustur(p_kullanici uuid, p_ad text, p_bulusma integer DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE yeni uuid;
BEGIN
  INSERT INTO aile(ad, olusturan_id, bulusma_alani_id) VALUES (p_ad, p_kullanici, p_bulusma) RETURNING id INTO yeni;
  INSERT INTO aile_uye(aile_id, kullanici_id, rol) VALUES (yeni, p_kullanici, 'yonetici');
  RETURN yeni;
END $$;

-- Kodla katılma: kullanıcı, ailedeki birinin kodunu girer.
-- Kodun sahibi tek bir ailedeyse istek o aileye açılır; yöneticiler onaylar.
CREATE OR REPLACE FUNCTION kodla_aileye_katil(p_isteyen uuid, p_kod text)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE hedef uuid; hedef_aile uuid; istek uuid; aile_sayisi int;
BEGIN
  SELECT id INTO hedef FROM kullanici WHERE kisisel_kod = upper(trim(p_kod))::citext AND silinme_talebi IS NULL;
  IF hedef IS NULL THEN RAISE EXCEPTION 'Bu koda ait kullanıcı bulunamadı. Kodu kontrol edin (HM-XXXX-XXXX).'; END IF;
  IF hedef = p_isteyen THEN RAISE EXCEPTION 'Kendi kodunuzu girdiniz. Ailenizdeki kişinin kodunu girin.'; END IF;

  SELECT count(*), min(aile_id::text)::uuid INTO aile_sayisi, hedef_aile FROM aile_uye WHERE kullanici_id = hedef;
  IF aile_sayisi = 0 THEN
    -- Kod sahibi henüz bir ailede değil: ikisi için yeni aile kurulur, kod sahibi onaylar.
    hedef_aile := aile_olustur(hedef, (SELECT soyad FROM kullanici WHERE id = hedef) || ' Ailesi');
  ELSIF aile_sayisi > 1 THEN
    -- Birden fazla ailesi varsa en eski aile seçilir (uygulama kullanıcıya seçtirir).
    SELECT aile_id INTO hedef_aile FROM aile_uye WHERE kullanici_id = hedef ORDER BY katilma_zamani LIMIT 1;
  END IF;

  IF EXISTS (SELECT 1 FROM aile_uye WHERE aile_id = hedef_aile AND kullanici_id = p_isteyen) THEN
    RAISE EXCEPTION 'Zaten bu ailenin üyesisiniz.';
  END IF;

  INSERT INTO aile_istek(aile_id, yon, isteyen_id, hedef_kullanici_id, girilen_kod)
  VALUES (hedef_aile, 'basvuru', p_isteyen, hedef, upper(trim(p_kod))::citext)
  RETURNING id INTO istek;
  RETURN istek;
END $$;

-- Yönetici, bir kişiyi koduyla aileye davet eder; kişi onaylar.
CREATE OR REPLACE FUNCTION kodla_davet_et(p_yonetici uuid, p_aile uuid, p_kod text)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE hedef uuid; istek uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM aile_uye WHERE aile_id = p_aile AND kullanici_id = p_yonetici AND rol = 'yonetici') THEN
    RAISE EXCEPTION 'Yalnızca aile yöneticisi davet gönderebilir.';
  END IF;
  SELECT id INTO hedef FROM kullanici WHERE kisisel_kod = upper(trim(p_kod))::citext AND silinme_talebi IS NULL;
  IF hedef IS NULL THEN RAISE EXCEPTION 'Bu koda ait kullanıcı bulunamadı.'; END IF;
  INSERT INTO aile_istek(aile_id, yon, isteyen_id, hedef_kullanici_id, girilen_kod)
  VALUES (p_aile, 'davet', p_yonetici, hedef, upper(trim(p_kod))::citext)
  RETURNING id INTO istek;
  RETURN istek;
END $$;

-- İsteği yanıtlama. Başvuruyu ailenin bir yöneticisi, daveti davet edilen kişi yanıtlar.
CREATE OR REPLACE FUNCTION istegi_yanitla(p_istek uuid, p_yanitlayan uuid, p_onay boolean,
                                          p_rol aile_rolu DEFAULT 'uye', p_yakinlik text DEFAULT NULL)
RETURNS istek_durumu LANGUAGE plpgsql AS $$
DECLARE r aile_istek; yetkili boolean; katilan uuid;
BEGIN
  SELECT * INTO r FROM aile_istek WHERE id = p_istek FOR UPDATE;
  IF r.id IS NULL THEN RAISE EXCEPTION 'İstek bulunamadı.'; END IF;
  IF r.durum <> 'beklemede' THEN RAISE EXCEPTION 'Bu istek zaten yanıtlanmış (%).', r.durum; END IF;
  IF r.son_gecerlilik < now() THEN
    UPDATE aile_istek SET durum = 'suresi_doldu' WHERE id = p_istek;
    RETURN 'suresi_doldu';
  END IF;

  IF r.yon = 'basvuru' THEN
    yetkili := EXISTS (SELECT 1 FROM aile_uye WHERE aile_id = r.aile_id AND kullanici_id = p_yanitlayan AND rol = 'yonetici');
    katilan := r.isteyen_id;
  ELSE
    yetkili := (p_yanitlayan = r.hedef_kullanici_id);
    katilan := r.hedef_kullanici_id;
  END IF;
  IF NOT yetkili THEN RAISE EXCEPTION 'Bu isteği yanıtlama yetkiniz yok.'; END IF;

  UPDATE aile_istek SET durum = CASE WHEN p_onay THEN 'onaylandi' ELSE 'reddedildi' END::istek_durumu,
                        yanitlayan_id = p_yanitlayan, yanit_zamani = now()
   WHERE id = p_istek;
  IF p_onay THEN
    INSERT INTO aile_uye(aile_id, kullanici_id, rol, yakinlik) VALUES (r.aile_id, katilan, p_rol, p_yakinlik)
    ON CONFLICT DO NOTHING;
    INSERT INTO riza(kullanici_id, tur, metin_surumu, verildi)
    VALUES (katilan, 'aile_konum_paylasimi', 'aile-2026-11', true);
  END IF;
  RETURN CASE WHEN p_onay THEN 'onaylandi' ELSE 'reddedildi' END::istek_durumu;
END $$;

-- En yakın n toplanma alanı (mesafe + yön).
CREATE OR REPLACE FUNCTION en_yakin_alanlar(p_enlem double precision, p_boylam double precision, p_adet int DEFAULT 3)
RETURNS TABLE (alan_id int, ad text, tur alan_turu, mesafe_metre int, yon int, yurume_dk int, kapasite_kisi int)
LANGUAGE sql STABLE AS $$
  SELECT a.id, a.ad, a.tur,
         round(mesafe_m(p_enlem, p_boylam, a.enlem, a.boylam))::int,
         round(yon_derece(p_enlem, p_boylam, a.enlem, a.boylam))::int,
         greatest(1, round(mesafe_m(p_enlem, p_boylam, a.enlem, a.boylam) / 75))::int,  -- ~4,5 km/sa
         a.kapasite_kisi
  FROM toplanma_alani a
  WHERE a.aktif
    AND a.enlem  BETWEEN p_enlem  - 0.05 AND p_enlem  + 0.05     -- ön eleme (~5 km), indeksi kullanır
    AND a.boylam BETWEEN p_boylam - 0.07 AND p_boylam + 0.07
  ORDER BY mesafe_m(p_enlem, p_boylam, a.enlem, a.boylam)
  LIMIT p_adet;
$$;

-- KVKK saklama süresi: afet modu dışındaki konum kayıtları 30 gün sonra silinir.
CREATE OR REPLACE FUNCTION eski_konumlari_sil(p_gun int DEFAULT 30) RETURNS bigint LANGUAGE sql AS $$
  WITH silinen AS (
    DELETE FROM konum_kaydi WHERE NOT afet_modu AND alinma_zamani < now() - make_interval(days => p_gun) RETURNING 1
  ) SELECT count(*) FROM silinen;
$$;

-- ---------------------------------------------------------------------
-- 13. Görünümler (raporlama ve ekranlar)
-- ---------------------------------------------------------------------

-- Aile ekranı: her üyenin son durumu, son konumu ve buluşma noktasına uzaklığı.
CREATE OR REPLACE VIEW v_aile_durumu AS
SELECT au.aile_id, a.ad AS aile_adi, k.id AS kullanici_id, k.ad || ' ' || k.soyad AS ad_soyad,
       k.kisisel_kod, au.rol, au.yakinlik,
       d.durum AS son_durum, d.olcum_zamani AS durum_zamani, d.kanal AS durum_kanali,
       CASE WHEN au.konum_paylasimi THEN sk.enlem  END AS son_enlem,
       CASE WHEN au.konum_paylasimi THEN sk.boylam END AS son_boylam,
       sk.olcum_zamani AS konum_zamani, sk.pil_yuzdesi,
       round(extract(epoch FROM now() - sk.olcum_zamani) / 60)::int AS konum_yasi_dk,
       CASE WHEN au.konum_paylasimi AND ta.id IS NOT NULL
                 AND mesafe_m(sk.enlem, sk.boylam, ta.enlem, ta.boylam) < 50000   -- şehir dışındakiler için gösterilmez
            THEN round(mesafe_m(sk.enlem, sk.boylam, ta.enlem, ta.boylam))::int END AS bulusmaya_mesafe_m,
       ta.ad AS bulusma_noktasi
FROM aile_uye au
JOIN aile a        ON a.id = au.aile_id
JOIN kullanici k   ON k.id = au.kullanici_id
LEFT JOIN son_konum sk ON sk.kullanici_id = k.id
LEFT JOIN toplanma_alani ta ON ta.id = a.bulusma_alani_id
LEFT JOIN LATERAL (SELECT durum, olcum_zamani, kanal FROM durum_bildirimi db
                   WHERE db.kullanici_id = k.id ORDER BY olcum_zamani DESC LIMIT 1) d ON true;

-- Aile hazırlık skoru (0–100): çanta %70, aile planı %30.
CREATE OR REPLACE VIEW v_hazirlik_skoru AS
WITH canta AS (
  SELECT a.id AS aile_id,
         sum(m.agirlik) FILTER (WHERE ac.var_mi) AS sahip,
         sum(m.agirlik) AS toplam
  FROM aile a
  CROSS JOIN canta_maddesi m
  LEFT JOIN aile_canta ac ON ac.aile_id = a.id AND ac.madde_id = m.id
  JOIN aile_uye yon ON yon.aile_id = a.id AND yon.rol = 'yonetici'
  JOIN kullanici k ON k.id = yon.kullanici_id
  LEFT JOIN mahalle mh ON mh.id = k.mahalle_id
  LEFT JOIN ilce ic ON ic.id = mh.ilce_id
  LEFT JOIN il ON il.id = ic.il_id
  WHERE m.bolge IS NULL OR m.bolge = il.bolge
  GROUP BY a.id
), plan AS (
  SELECT a.id AS aile_id,
         (CASE WHEN a.bulusma_alani_id IS NOT NULL THEN 10 ELSE 0 END) +
         (CASE WHEN a.sehir_disi_kisi_tel IS NOT NULL THEN 10 ELSE 0 END) +
         (CASE WHEN (SELECT count(*) FROM aile_uye u WHERE u.aile_id = a.id) >= 2 THEN 10 ELSE 0 END) AS puan
  FROM aile a
)
SELECT a.id AS aile_id, a.ad,
       round(coalesce(c.sahip, 0)::numeric / nullif(c.toplam, 0) * 70 + p.puan)::int AS skor,
       coalesce(c.sahip, 0) AS canta_puani, c.toplam AS canta_toplam, p.puan AS plan_puani
FROM aile a
JOIN canta c ON c.aile_id = a.id
JOIN plan p  ON p.aile_id = a.id;

-- Muhtar özeti: kişisel veri içermez, yalnızca sayılar.
CREATE OR REPLACE VIEW v_mahalle_ihtiyac_ozeti AS
SELECT m.id AS mahalle_id, m.ad AS mahalle, i.kategori,
       count(*) FILTER (WHERE i.durum = 'acik')        AS acik,
       count(*) FILTER (WHERE i.durum = 'ustlenildi')  AS ustlenildi,
       count(*) FILTER (WHERE i.durum = 'karsilandi')  AS karsilandi,
       sum(i.adet) FILTER (WHERE i.durum = 'acik')     AS acik_adet,
       count(*) FILTER (WHERE i.durum = 'acik' AND i.son_teyit_zamani < now() - interval '12 hours') AS teyit_bekleyen,
       min(i.olusturma_zamani) FILTER (WHERE i.durum = 'acik') AS en_eski_acik
FROM ilan i
JOIN mahalle m ON m.id = i.mahalle_id
WHERE i.tur = 'ihtiyac'
GROUP BY m.id, m.ad, i.kategori;

-- Pano: telefona gönderilen ilan listesi (tam adres yok, eskiyen ilan işaretli).
CREATE OR REPLACE VIEW v_pano AS
SELECT i.id, i.mahalle_id, i.tur, i.kategori, i.adet, i.birim, i.aciklama, i.durum, i.dogrulanmis,
       i.yaklasik_enlem, i.yaklasik_boylam, i.olusturma_zamani,
       (i.durum = 'acik' AND i.son_teyit_zamani < now() - interval '12 hours') AS teyit_gerekli,
       (SELECT count(*) FROM ilan_bildirim b WHERE b.ilan_id = i.id) AS bildirim_sayisi
FROM ilan i
WHERE i.durum IN ('acik', 'ustlenildi')
   OR (i.durum = 'karsilandi' AND i.olusturma_zamani > now() - interval '24 hours');

-- Mesaj ulaşım analizi (pilot KPI): kanal başına teslim süresi ve sıçrama sayısı.
CREATE OR REPLACE VIEW v_mesaj_ulasim AS
SELECT t.kanal, count(*) AS teslim_sayisi,
       round(avg(t.sicrama_sayisi), 1) AS ort_sicrama,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM t.teslim_zamani - m.olusturma_zamani))::numeric / 60, 1) AS medyan_dk
FROM mesaj_teslim t JOIN mesaj m ON m.id = t.mesaj_id
GROUP BY t.kanal;

-- Konum izni uyumu: kaç kullanıcı son açılışta izni reddetti (destek ekibi için).
CREATE OR REPLACE VIEW v_konum_izni_son AS
SELECT DISTINCT ON (kullanici_id) kullanici_id, sonuc, cihaz_zamani
FROM konum_izni_olayi ORDER BY kullanici_id, cihaz_zamani DESC;

COMMIT;
