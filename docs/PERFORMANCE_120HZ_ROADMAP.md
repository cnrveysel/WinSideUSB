# 120 Hz akıcılık: bulgular ve yol haritası

**29 Ekim ölçüm sonucu:** iPad callback ritmi yaklaşık 119,85/s; kalan düzensizlik kare gelişinde görülüyor. Canlı %100/%200 DPI ve sanal ekranın hatalı fiziksel boyutu da incelendi. [Yeni log ve boyut bulguları](PERFORMANCE_120HZ_FINDINGS_2026-10-29.md).

**Ritim ölçüm paketi:** 1.1 (5), tamamlanan frame geliş aralıklarını, chunk birleştirme süresini ve Core Animation callback ritmini sınırlı histogramlarla ölçüyor. 28 Ekim'de imzalanıp iPad'e yüklendi. Varsayılan yenileme tercihi korunuyor; callback Hz fiziksel panel Hz veya benzersiz video FPS kanıtı değildir. Ölçüm alanları ve sınırları [iPad istemci belgesinde](IPAD_CLIENT.md#arrival-and-display-rhythm-build-5).

**İlk paket uygulama notu:** 1.1 (4) kaynak sürümünde sample attachment düzeltmesi, sınırlı ayrı log kuyruğu ve iPadOS 17.4+ renderer sayaçlarından hesaplanan gösterim FPS ölçümü eklendi. Aşağıdaki bulgular değişiklik öncesi incelemeyi kaydeder. Windows/protokol ölçümleri, ProMotion tercihi, sender recovery ve async NVENC sonraki paketlerde kalıyor; fiziksel akıcılık sonucu henüz ölçülmedi.

İnceleme: **27 Ekim 2026**, Europe/Berlin. Hedef: `2732×2048 @ 120 Hz` modunda büyük pencere sürükleme ve hareketsiz görüntüden ani harekete geçişte düzenli kare sunumu.

**Sonuç:** Ortalama gönderim 120 FPS'ye yaklaşabiliyor; kısa beklemeler ve toparlanma davranışı hâlâ sorun adayı. Windows loglarında 8,33 ms kare aralığını aşan encode beklemeleri ve toplu kare düşürme olayları var. iPad kodunda sample attachment kullanımı hatalı, senkron log I/O video alımıyla aynı kuyrukta ve gerçek sunulan kareler ölçülmüyor. Tek bir kesin kök neden veya kesintisiz 120 Hz henüz kanıtlanmış değil.

İlk inceleme kod/log analizi ve roadmap içeriyordu; o aşamada uygulama davranışı değiştirilmemişti. Üstteki ilk paket notu sonraki kaynak değişikliklerini kaydeder. Yeni fiziksel iPad performans koşusu yapılmadı.

## Kanıt ve sürüm sınırları

- Windows kaynak tabanı: `57c7dec` / 0.3.9; çalışma ağacındaki mevcut iPad recovery değişiklikleri de incelendi.
- `%LOCALAPPDATA%\WinSideUSB` altındaki son **13 TX CSV** ve `winsideusb_diag.log` okundu. Ham kayıtlar, SHA256 bilgileri, analiz scripti ve sonuçlar yerel, Git dışında kalan `.codex/performance/2026-10-27-audit/` dizininde saklandı.
- Yerel kurulum kayıtları iPad **1.1 build 3** kurulumunu `02:40:31`'de doğruluyor. Kaynak hash'i mevcut iki Swift kopyasıyla eşleşiyor. Canlı uygulama kimliği ayrıca okunmadı.
- Ayrıntılı uzun TX oturumu **01:16–02:25** arasında, bu iPad kurulumundan önce. Sonraki üç kısa oturum yeni kurulumdan sonra; ağırlıkla hareketsiz/pointer güncellemeleri içeriyor.
- İncelenen çalışma alanında iPad RX CSV'si bulunmadı. Windows'ta gönderilmiş bir kare, iPad'de sunulmuş bir kare anlamına gelmiyor.

## Logların gösterdiği

Kaynak: `winsideusb_tx_1793060164.csv`, 4.183,839 saniyelik yazılmış veri.

| Ölçüm | Sonuç | Yorum |
| --- | ---: | --- |
| Yoğun hareket göstergesine uyan süre | 265,053 s / 264 aralık | Kontrollü senaryo etiketi olmadığı için yaklaşık seçim |
| Bu aralıklarda gönderim | 119,13 FPS | Yerel iproxy soketine tamamlanan video kareleri |
| Encode ortalaması / lock ortalaması | 5,482 / 5,334 ms | Ortalamanın büyük bölümü bitstream beklemesinde |
| Yoğun hareket seçiminde encode azamisi | 47,520 ms | 120 Hz kare aralığının yaklaşık 5,7 katı |
| Aynı tepe aralığında capture timestamp boşluğu / pacing gecikmesi | 55,418 / 48,127 ms | Windows tarafında da kısa sıçrama var |
| Encode tepesi 8,33 ms'yi aşan aralık | 27 / 264 | Kare sayısı veya frame p99 değeri değildir |
| Uzun oturumun tamamında sender drop | 38 | Üç aralıkta: 3, 7, 28; hepsinde forced IDR de var |
| İncelenen 13 oturumda `large_dirty` | 0 | Dirty alan kuralının bu olayları tetiklediği gösterilemiyor |

Tekrar kontrol edilebilecek CSV satırları, başlık satırı dahil:

- **1732**, `t=1739.719`: encode max 47,520 ms, pacing max 48,127 ms, sender drop 0. Sıçrama için aktarım kaybı gerekmiyor.
- **590**, `t=591.100`: encode ort/max 5,962/6,470 ms, 107 input, 79 output, 28 drop, kuyruk max 4, forced IDR 2. Encode normal giderken de gönderici/toparlanma kaybı yaşanabiliyor. Saniyelik kayıt nedensel sırayı göstermez.
- **542**, `t=542.835`: karma/düşük hareketli aralıkta encode max **303,141 ms**. Bunu belirli bir idle→motion olayı olarak etiketlemek mümkün değil.
- Hareketsizliğe yakın aralıklarda encode ortalaması **11,443 ms**, yoğun hareket seçiminde **5,482 ms**. GPU güç durumu, sürücü beklemesi ve thread zamanlamasını ayıracak soğuk/sıcak karşılaştırma gerekli.
- Uzun oturumda `capture_errors=200`, yoğun hareket seçiminde 0; diğer 12 oturumda 0. Hangi HRESULT/olayın sayıldığı mevcut CSV'den anlaşılamıyor. Buna duplication yeniden oluşturma denemeleri de girebilir; doğrudan 200 görünür takılma sayılmaz.

Yoğun hareket seçimi: `present_updates / gerçek_aralık_süresi >= 100`, `present_delta_ms_avg <= 12`, `capture_timeouts <= 3`. Bu seçim ağır takılmaları dışarıda bırakabilir; genel takılma oranı değildir. Ortalamalar input sayısıyla ağırlıklandırıldı. Saniyelik kayıtlardan gerçek frame p95/p99 hesaplanamaz. NVENC ölçümü API çağrıları çevresindeki CPU duvar saatidir; GPU işi, sürücü senkronizasyonu ve thread beklemesi ayrışmıyor.

Yeni iPad kurulumundan sonraki kayıtlar:

| TX dosyası | Süre | Encode ort/max | Sender drop / capture error |
| --- | ---: | ---: | ---: |
| `1793065309` | 24,129 s | 7,650 / 31,089 ms | 0 / 0 |
| `1793065342` | 32,223 s | 9,148 / 39,907 ms | 0 / 0 |
| `1793065448` | 2,003 s | 4,676 / 9,430 ms | 0 / 0 |

Bunlar sürekli hızlı hareket koşulları değil. Hareketsiz desktop için mevcut 4 FPS heartbeat normal; düşük toplam FPS hareket performansı kaybını kanıtlamaz.

## Kod bulguları

Satırlar inceleme anındaki dosyalara aittir.

| Bulgu | Kaynak | Kanıt / etkisi |
| --- | --- | --- |
| NVENC synchronous; tek giriş texture'ı ve tek çıktı tamponu, capture thread'inde blocking lock | `WinSideUSB/WinSideUSB.cpp:1608`, `:1617`, `:1633`, `:1733` | Mimari kesin. Uzun API beklemeleri yeni capture'ı geciktirir. |
| Yeni kare bekliyorsa P kare 10 ms, IDR 25 ms yaşından sonra iptal edilebiliyor; sonra IDR'ye kadar zincir düşüyor | `WinSideUSB.cpp:1113`, `:1207`, `:1218`, `:1019` | Mekanizma kesin; 38 drop gözlenmiş. İptal nedenleri ayrılmıyor. |
| Toparlanma IDR'si normal capture yolunda diğer nedenlerle aynı 250 ms kapısından geçiyor | `WinSideUSB.cpp:2521` | Önceki IDR yakınsa toparlanma bekleyebilir. Sürekli harekette reddedilen P kareler isteği tekrar kurar; istek kalıcı kaybolmuş sayılmaz. |
| `DisplayImmediately` ve `NotSync`, sample dictionary yerine `CMSetAttachment` ile buffer'a yazılıyor | `WinSideUSB/swiftclientcode.swift:881` | Apple'ın sample attachment sözleşmesiyle uyuşmuyor. Immediate davranışın çalıştığı varsayılamaz; görünür etki cihazda ölçülmeli. |
| Video alımı/parsing/sample kuyruğunda senkron log yazımı ve yaklaşık saniyelik `synchronize()` var | `swiftclientcode.swift:252`, `:619`, `:683` | Bekleme yolu kesin; gerçek I/O gecikmesi henüz ölçülmedi. |
| Renderer hazır değilken enqueue devam ediyor; yerel yaş/boyut sınırı yok | `swiftclientcode.swift:841`, `:887` | Enqueue güvenli; gecikmeyi sınırlayan politika eksik. Gerçek birikme ölçülmedi. |
| iPad sayacı enqueue sayıyor; PTS sabit `frameIndex / 120`; ProMotion cadence ölçümü yok | `swiftclientcode.swift:266`, `:869`, `:888`, `:1046` | Görünen FPS ve idle→motion davranışı bilinmiyor. iPad'in 60 Hz'e kilitli olduğu kanıtlanmış değil. |
| Ekranın %55'inden fazla dirty alan olduğunda giriş kenarında IDR üretiliyor | `WinSideUSB.cpp:334`, `:2524` | Kod mevcut; incelenen loglarda tetiklenmemiş. İlk kök neden olarak seçilmemeli. |

`send_ms_max`, **4 KB'lık tek chunk'ın yerel sokete yazılmasıdır**; tam kare USB süresi değildir (`WinSideUSB.cpp:1280–1350`). Windows UI FPS de gönderici kuyruğuna eklenen kareyi sayar (`:2345`, `:2546`). Hızlı yerel yazım, iproxy/usbmux veya iPad kuyruğunda bekleme olmadığını göstermez.

## Uygulama sırası

Her değişiklik ayrı deneyle karşılaştırılmalı. Kalite, çözünürlük, bitrate ve pacing aynı anda değiştirilirse kazancın kaynağı anlaşılamaz.

| Sıra | İş paketi | Katkı | Efor / karar ölçütü |
| --- | --- | --- | --- |
| **1 — P0** | iPad sample attachment düzeltmesi; log I/O'yu ayrı seri utility kuyruğuna taşıma; video kuyruğundan per-second fsync kaldırma | Doğruluk hatasını ve önlenebilir alım beklemesini kaldırır | Küçük; iki ayrı karşılaştırma |
| **2 — P0** | Frame bazlı ölçüm, senaryo işaretleri ve gerçek renderer metrikleri | Capture, encode, taşıma ve presentation sorunlarını ayırır | Orta; mimari kararların ön koşulu |
| **3 — P1** | Acil toparlanma IDR'sini isteğe bağlı IDR'den ayır; bekleyen/yolda recovery durumlarını izle; sender iptallerini nedenleriyle kaydet | 250 ms bekleme ve iptal→IDR döngüsünü sınırlar | Orta; recovery gap'i düşmeli, referans hatası oluşmamalı |
| **4 — P1** | Idle→motion GPU/pacing incelemesi; iPad'de streaming süresince 120 Hz tercihi ve gerçek cadence takibi | Soğuk başlangıç ve refresh geçişini ayırır | Orta; güç/sıcaklık kaydıyla karşılaştırma |
| **5 — P2** | Native NVENC için async event, sahipliği belirli texture/bitstream havuzu ve sınırlı bekleyen iş | Capture'ı bitstream sonucu beklemekten ayırır | Büyük; capture aralıkları ve uçtan uca gecikme birlikte iyileşmeli |
| **6 — Koşullu** | Renderer kuyruğuna süre/boyut sınırı ve IDR feedback; ardından parser/kopya optimizasyonu | Ölçülen alıcı birikmesini ve CPU sıçramasını azaltır | Orta/büyük; önce biriken aşama kanıtlanmalı |
| **7 — Koşullu** | GPU BGRA→NV12 karşılaştırması; gerekirse VideoToolbox + Metal sunum prototipi | Kalan encode/presentation darboğazını hedefler | Büyük; önceki işler yetmezse |

### İlk teslimin kapsamı

- Sample anahtarlarını `CMSampleBufferGetSampleAttachmentsArray` üzerinden sample dictionary'ye yaz. Testte dictionary'yi geri okuyarak IDR/P ayrımını ve immediate anahtarını doğrula. [Apple enqueue sözleşmesi](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/enqueue(_:)) iki attachment API'sini ayırıyor.
- Log handle açma/yazma/kapatma sırasını tek log kuyruğunda tut; session generation ile eski callback'leri ayır. Buffer sınırlı olsun, loglama video alımını bekletmesin.
- Windows'ta frame ID ile capture zamanı, encode başlangıç/bitiş, IDR nedeni, kuyruğa giriş/çıkış, tam kare gönderim başlangıç/bitiş ve drop nedeni kaydedilsin. Mevcut `DC2F` frame ID'si tamamlanan frame'in receiver telemetry'sinde de korunsun.
- iPad'de ilk/son chunk zamanı, frame assembly, parser/sample süresi, not-ready süresi ve flush nedeni ölçülsün. `loadVideoPerformanceMetrics`, **iPadOS 17.4+** availability kontrolüyle sunum/drop metriklerini sağlasın; eski sistemde eksik veri açıkça belirtilsin. [Apple renderer metrikleri](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/loadvideoperformancemetrics(completionhandler:)).
- `totalNumberOfFrames` gösterilmesi beklenen toplamdır; tek başına gösterilen FPS değildir. Başlangıç renderer tahmini `Δ(totalNumberOfFrames - numberOfDroppedFrames) / Δt` ile, flush/session sınırları ayrılarak hesaplanmalı; test frame kimliğiyle fiziksel sunum ayrıca doğrulanmalı. [Apple toplam kare tanımı](https://developer.apple.com/documentation/avfoundation/avvideoperformancemetrics/totalnumberofframes).
- `CADisplayLink` callback aralığı, frame-rate tercihi ve power/thermal durumu kaydedilsin. Callback Hz, benzersiz video FPS'si değildir; 120 Hz tercihi sistem garantisi değildir. [Apple ProMotion rehberi](https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays).
- PC QPC ile iPad uptime doğrudan birbirinden çıkarılmamalı. Aşama içi sürelerde yerel monotonic saat; cihazlar arası süre için belirsizliği ölçülmüş saat eşlemesi veya dış kamera kullanılmalı.
- Kaynak piksel/Hz ve timestamp bilgisi sürümlenmiş protokolle iletilsin. Sonraki zamanlanmış presentation deneyleri yalnız `frameIndex / 120` üzerine kurulmasın; mevcut düşük gecikmeli davranış önce ölçülsün.
- `capture_errors` için HRESULT, acquire/recreate ayrımı, toparlanma süresi, renk/topoloji olayları; dirty/move rect sayıları ve sorgu sonuçları eklensin.

### Mimari işlerin sınırları

Recovery isteği IDR üretilip sender tarafından kabul edilene kadar bekleyen durumda tutulmalı; kabulden sonra yolda durumu izlenmeli. Aktarım sırasında her yeni kareyi IDR'ye dönüştürmekten kaçınılmalı. İptalde yeniden istenmeli; mevcut protokolde iPad teslim onayı bulunmadığından yerel gönderim başarısı uçtan uca onay sayılmamalı.

NVENC async tasarımında yalnız blocking lock'u başka thread'e taşımak yeterli değil. NVIDIA, DXGI capture ile başka thread'de synchronous bitstream lock birleşimine özel uyarı veriyor. Async completion event ve doğru GPU kaynak ömrü kullanılmalı; önerilen en az **4 + B-frame sayısı** IO tamponu tahsis edilirken izin verilen bekleyen iş ayrıca sınırlanmalı. Tampon tahsisi, hepsini gecikme kuyruğu olarak doldurmak anlamına gelmez. [NVIDIA threading ve async kılavuzu](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.1/nvenc-video-encoder-api-prog-guide/index.html#threading-model).

Renderer için yalnız `if !ready { return }` eklenmemeli: referans P kareyi rastgele düşürmek H.264 zincirini bozabilir. Referans decode'unu koruyup sunumu atlama veya süre sınırı olan reset + hızlı IDR mekanizması tasarlanmalı. iPad'den IDR istemek mevcut protokole geri bildirim ve uyumluluk yönetimi eklemeyi gerektirir. [Apple readiness belgesi](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/isreadyformoremediadata), hazır değilken enqueue'nun güvenli olduğunu fakat sınırsız birikmenin uygun olmadığını açıklıyor.

GPU güç durumu ölçülmeden genel bir maksimum performans sistem ayarı yapılmamalı. Idle encode ortalamasının yüksekliği saat düşüşünü tek başına kanıtlamaz. Kısa GPU/CPU trace ile sürücü beklemesi, GPU yoğunluğu, clock/power ve scheduling ayrılmalı. Daha yüksek idle keepalive ancak kazanç, güç ve termal maliyet birlikte ölçülerek denenmeli.

Dirty alan IDR kuralının aç/kapat deneyi, tetikleyici gerçekten ölçüldüğünde anlamlı. Düşük çözünürlükte **aynı 120 Hz** karşılaştırması piksel yükünü ayırmak için tanı deneyi olabilir. Global GOP'u kısaltmak veya bitrate yükseltmek ilk çözüm olarak seçilmemeli.

## Kabul senaryoları

Her koşuda PC/iPad build kimliği, kaynak hash'i, mod, güç/sıcaklık ve senaryo kaydedilmeli. Aynı sahne en az üç kez sıcak ve boşta beklemiş koşullarda çalıştırılmalı.

1. Mevcut 18 saniyelik 120 FPS benchmark ile baseline. Şu an iPad sunumunu ölçmüyor.
2. **10 saniye sabit → 5 saniye hızlı hareket**, 20 tekrar. İlk yeni kaynak karesinden ilk sunuma ve ilk saniyedeki sunum aralıklarına bak.
3. Ekranın %70–90'ını kaplayan metinli pencere sürükleme; maximize/restore, resize ve hızlı scroll ayrı senaryolar olsun.
4. Aynı içerikle küçük pencere/tam ekran karşılaştırması; IDR nedeni, frame boyutu ve sender cancel/toparlanma süresini eşleştir.
5. 30 dakikalık kullanımda termal bozulma, sürekli büyüyen kuyruk yaşı, cursor ve reconnect kontrolü.

Başlangıç kabul hedefleri **ölçülmüş sonuç değildir**: 120 güncelleme/s üreten testte iPad renderer metriğiyle en az 118 benzersiz kare/s, sunum boşluğu p99 ≤16,7 ms, 60 saniyelik sürekli harekette 50 ms üzeri açıklanamayan boşluk olmaması; idle→motion ilk yeni kare gecikmesi p95 ≤33,3 ms. Kaynak değişimi→present ve capture→present ayrı raporlansın. Bunlar kusursuz 120 Hz anlamına gelmez; iyileşme sağlandıkça 8,33 ms çevresindeki dağılım daraltılmalı.

Gerçek frame interval p50/p95/p99/max ve 16,7/25/50 ms üzeri boşluk sayıları raporlanmalı. Renderer metriği tek tek sunum zamanını sağlamıyorsa bu açık yazılmalı; benzersiz kaynak frame numarası içeren test ve yüksek hızlı kamera gibi bağımsız doğrulama kullanılmalı. Kaynağın kendisi yeterli güncelleme üretmiyorsa renderer FPS hedefi o koşuya uygulanmamalı.

## Doğrulanan temel ve hazır yerel çalışma

- Bu incelemede `tests/Run-FramePacingTests.ps1`: **12/12 PASS**, high-resolution timer kullanılabilir.
- Bu incelemede `tests/Run-iPadTransportTests.ps1`: **7/7 PASS**, Swift kaynak kopyaları aynı.
- Bunlar zamanlayıcı/yerel socket testleri; fiziksel 120 Hz sunum başarısı değildir.
- MMCSS Capture, yüksek çözünürlüklü timer, sonraki acquire öncesine kadar frame ownership ve timeout sonrası ek beklemenin kaldırılması zaten mevcut.
- `.codex/performance/ipad-performance-pending.patch` daha eski, uygulanmamış bir taslak. Güncel recovery/UI koduna gözden geçirilerek uyarlanmalı.

Önerilen ilk teslim: **sample attachment düzeltmesi + video yolundan log I/O'nun çıkarılması + ölçüm altyapısı**. Ardından senaryo verisine göre sender recovery ve async NVENC çalışması; kalite/renk/cursor/reconnect kontrolleri her aşamada korunmalı.
