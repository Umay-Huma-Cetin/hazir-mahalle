# Hazır Mahalle — Veritabanı

Hazır Mahalle afet hazırlık ve dayanışma uygulamasının veritabanı tasarımı. İki katmandan oluşur:

| Katman | Teknoloji | Görevi |
| --- | --- | --- |
| Sunucu | PostgreSQL 14+ | Tüm kullanıcılar, aileler, mahalle panosu, raporlar |
| Telefon | SQLite (üretimde SQLCipher ile şifreli) | İnternet yokken çalışan her şey: kayıt, aile planı, harita, konum, giden kutusu |

Telefon önce kendi veritabanına yazar. İnternet, SMS veya yakın telefonlar (mesh) üzerinden bağlantı kurulunca kayıtlar sunucuya gider. Her kayıt telefonda üretilmiş bir UUID taşıdığı için aynı kayıt iki kez gelse bile sunucuda tekrar oluşmaz.

## Dosyalar

| Dosya | İçerik |
| --- | --- |
| `01_sunucu_sema_postgresql.sql` | 24 tablo, 6 görünüm, iş kuralı tetikleyicileri ve fonksiyonlar |
| `02_ornek_veri_postgresql.sql` | Malatya ve İstanbul pilot mahalleleri, 7 örnek kullanıcı, kodla aile kurma akışı, afet senaryosu |
| `03_ornek_sorgular_postgresql.sql` | Ekranlara karşılık gelen 15 sorgu ve iş kuralı testleri |
| `04_cihaz_sema_sqlite.sql` | Telefon veritabanı şeması |
| `05_cihaz_ornek_veri_sqlite.sql` | Elif'in telefonu: deprem sonrası 40. dakika, internet yok |
| `hazir_mahalle_telefon.db` | 04 ve 05 çalıştırılmış, açılmaya hazır SQLite dosyası |
| `er.mmd` (görsel: `../docs/er_diyagrami.png`) | Varlık-ilişki diyagramı |

Tüm kişiler, telefonlar ve adresler uydurmadır. Toplanma alanı koordinatları örnektir (`kaynak = 'ornek_veri'`); gerçek uygulamada AFAD, İBB açık verisi veya muhtarlıktan doğrulanmış veri kullanılmalıdır.

## Hızlı başlangıç

**Telefon veritabanını incelemek (kurulum gerektirmez):**
1. [DB Browser for SQLite](https://sqlitebrowser.org/) programını kur.
2. `hazir_mahalle_telefon.db` dosyasını aç.
3. "Execute SQL" sekmesinde dene: `SELECT * FROM v_son_konum;`, `SELECT * FROM v_hazirlik_skoru;`, `SELECT * FROM aile_uye;`

**Sunucu veritabanını kurmak:**
1. [PostgreSQL](https://www.postgresql.org/download/windows/) kur (pgAdmin birlikte gelir).
2. pgAdmin'de `hazir_mahalle` adında bir veritabanı oluştur.
3. Query Tool ile sırasıyla `01`, `02`, `03` dosyalarını aç ve çalıştır. Komut satırından:
   ```
   psql -U postgres -d hazir_mahalle -f 01_sunucu_sema_postgresql.sql
   psql -U postgres -d hazir_mahalle -f 02_ornek_veri_postgresql.sql
   psql -U postgres -d hazir_mahalle -f 03_ornek_sorgular_postgresql.sql
   ```
   `03` dosyası `psql` komutları (`\echo`) içerir; pgAdmin'de bu satırları atlayıp sorguları tek tek çalıştır.

## Temel akışlar

### 1. Kayıt
`kullanici_kaydet(ad, soyad, telefon, mahalle_id, acik_adres, dil, enlem, boylam)` tek işlemde şunları yapar:
- Telefonu `+90XXXXXXXXXX` biçimine getirir, geçersizse anlaşılır bir hata verir.
- Kişiye benzersiz bir kod üretir: `HM-7K3P-Q9WD`. Karıştırılan karakterler (0/O, 1/I/L) kullanılmaz.
- Açık adresi şifreli kaydeder (`pgcrypto`). Haritada ve panoda yalnızca yuvarlanmış konum kullanılır.
- KVKK aydınlatma ve konum işleme rızalarını sürüm numarasıyla kaydeder.

### 2. Kodla aileye katılma
İki yön vardır:
- **Başvuru:** Kullanıcı, ailedeki birinin kodunu girer → `kodla_aileye_katil()` → aile yöneticisi `istegi_yanitla()` ile onaylar.
- **Davet:** Yönetici, eklemek istediği kişinin kodunu girer → `kodla_davet_et()` → kişi kendisi onaylar.

Onay gerekmesinin nedeni şudur: kod ele geçirilse bile kimse izinsiz bir ailenin konumunu göremez. İstekler 7 gün geçerlidir ve aynı kişi için aynı anda tek bekleyen istek olabilir.

### 3. Konum (internet olmadan da)
- Uygulama her açıldığında konum izni ister ve sonucu `konum_izni_olayi` tablosuna yazar.
- GPS uydu sinyaliyle çalıştığı için internet gerekmez. Ölçümler telefonda `konum_kaydi` tablosunda tutulur, `v_son_konum` görünümü son konumu internetsiz gösterir.
- Ölçüm sunucuya ulaştığında tetikleyici `son_konum` tablosunu günceller. Mesh ile geç gelen eski bir ölçüm yeni konumun üzerine yazılmaz.
- `en_yakin_alanlar(enlem, boylam)` mesafeyi, pusula yönünü ve yürüme süresini döndürür. Telefonda aynı hesap uygulama kodunda yapılır.
- Afet modu dışındaki konum kayıtları `eski_konumlari_sil()` ile 30 gün sonra silinir (KVKK saklama süresi).

### 4. Afet anında mesajlaşma
- Telefondaki `giden_kutusu`, mesajı sırasıyla internet → SMS → yakın telefonlar → sakla-ilet yoluyla göndermeye çalışır. Güvendeyim mesajları önceliklidir (öncelik 1).
- Güvendeyim mesajı 5 saniye boyunca geri alınabilir (`geri_al_bitis`).
- `mesh_gorulen` tablosu başkaları adına taşınan mesajların iki kez iletilmesini engeller ve 24 saat sonra kendini temizler.
- Sunucudaki `mesaj_teslim` tablosu her mesajın kime, hangi kanaldan ve kaç sıçramayla ulaştığını kaydeder. `v_mesaj_ulasim` görünümü pilot ölçümü (KPI) için kullanılır.

### 5. Mahalle panosu
- İlan durumları yalnızca geçerli yollarla değişir: açık → üstlenildi → karşılandı. Karşılanmış ilan yeniden açılamaz.
- Bir gönüllü aynı anda en fazla 3 ilan üstlenebilir; bu kural hem sunucuda hem telefonda tetikleyiciyle uygulanır.
- 12 saattir teyit edilmemiş ilanlar `teyit_gerekli` olarak işaretlenir.
- `v_mahalle_ihtiyac_ozeti` muhtar için yalnızca sayıları gösterir, kişisel veri içermez.

## KVKK ve güvenlik

| Veri | Önlem |
| --- | --- |
| Açık adres | `pgp_sym_encrypt` ile şifreli. Anahtar oturum ayarından okunur (`SET hm.sifre_anahtari`), tabloda durmaz. |
| Destek ihtiyacı (engellilik vb.) | Özel nitelikli kişisel veri: ayrı tabloda, şifreli, isteğe bağlı rızayla tutulur. |
| Konum | Aile içinde paylaşım üye bazında kapatılabilir (`konum_paylasimi`). Panoda ~100 m'ye yuvarlanır. 30 gün saklanır. |
| Rıza | Her rıza ayrı satırda ve sürümlü tutulur. Geri çekme yeni bir satır olarak eklenir, geçmiş silinmez. |
| Erişim | Adres ve destek tablolarındaki her değişiklik `denetim_kaydi` tablosuna yazılır. |
| Telefon dosyası | Üretimde SQLCipher ile şifrelenir; anahtar Android Keystore / iOS Keychain'de tutulur. |

`02_ornek_veri_postgresql.sql` içindeki şifreleme anahtarı yalnızca geliştirme içindir. Gerçek anahtar bir gizli anahtar kasasında tutulmalı ve hiçbir dosyaya yazılmamalıdır.

## Test edilenler

Bu şema PostgreSQL 16 ve SQLite 3.53 üzerinde baştan sona çalıştırıldı:
- Kayıt, kod üretimi, kodla başvuru ve davet akışları çalışıyor; bekleyen istek listeleniyor.
- Mesh ile geç gelen eski ölçüm son konumun üzerine yazmıyor.
- En yakın toplanma alanı, mesafe, yön ve yürüme süresi doğru hesaplanıyor.
- Hazırlık skoru sunucuda ve telefonda aynı çıkıyor (örnek ailede 64).
- Geçersiz kod, kendi kodunu girme, karşılanmış ilanı yeniden açma, geçersiz telefon ve 4. ilanı üstlenme hata veriyor.
- Şifreli adres tabloda okunamıyor, yalnızca anahtarla çözülüyor.

Hazırlayan: Umay Hüma Çetin
