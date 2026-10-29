# 29 Ekim 2026: 120 Hz ritmi ve ekranlar arası pencere boyutu

iPad **1.1 (5)** ile normal kullanım sırasında oluşan yeni kayıtlar okundu. İlk log incelemesinde benchmark, derleme, uygulama yeniden başlatma veya ekran ayarı değişikliği yapılmadı. USB'den yalnız WinSideUSB uygulamasının CSV logları alındı. Sonraki fiziksel boyut uygulaması ve kısa doğrulama aşağıda ayrıca kayıtlı.

## Yeni ritim kaydı

Kaynak iPad kaydı: `winsideusb_rx_1793232052_5465A9CF.csv`, ilk yaklaşık 130 saniye. Aynı Windows oturumu: `winsideusb_tx_1793232053.csv`. Çalışan TX dosyasının dizin kaydı boyutu 0 görünüyordu; paylaşılmış okuma handle'ıyla gerçek içerik alındı. Yayını durdurmak gerekmedi. TX snapshot 247,398 saniyeye kadar veri içeriyor; iPad karşılaştırması ilk 130 saniyelik önekle sınırlandı. Saat başlangıçları ve rapor pencereleri tam eşzamanlı değil.

| Ölçüm | Sonuç | Anlamı |
| --- | --- | --- |
| Core Animation callback ritmi | 128 raporda ağırlıklı **119,849/s**; raporlar 117,929–119,933/s | Bu kayıtta 60 veya 90 callback/s sınırı görünmüyor |
| Bildirilen callback çevrimi | **8,338 ms**, yaklaşık 119,929 Hz | Fiziksel panel taraması veya benzersiz video FPS ölçümü değil |
| Callback aralıkları | Pencere bazlı p95 üst sınırı **8,338–8,5 ms**; max **21,764 ms** | 16,667 ms üzerinde 2 aralık; 25 ms üzerinde yok |
| 115/s üzeri gelen kareler | 6 pencere / 6,007 s içinde **720 kare = 119,86/s** | Kısa sürelerde alıcı yaklaşık 120'yi karşılıyor |
| Bu pencerelerde frame geliş aralıkları | P95 üst sınırları **10,5–12,25 ms**, p99 üst sınırları **11,5–16,5 ms** | Geliş ritmi 8,33 ms çevresinde henüz eşit değil |
| Frame birleştirme | Hızlı pencerelerde ortalama **0,472 ms**; tüm kayıtta max **8,558 ms** | Ölçülen chunk birleştirme süreleri büyük bir kuyruk göstermiyor |
| Renderer | Düşen/bozuk kare, not-ready, flush ve RX hataları **0** | Zamanı hizalanabilen 127 renderer artışı enqueue artışıyla eşleşiyor |
| Güç/sıcaklık | Low Power 0, thermal 0 | Bu kayıtta termal/güç kısıtı göstergesi yok |
| Eşleşen Windows öneğinde yoğun güncelleme | 4 pencere / 4,018 s, **119,71 FPS**; encode ort/max **4,019/5,718 ms** | Bu kısa hareket kesitinde encoder bütçeyi karşılıyor |
| Eşleşen Windows öneğinde gönderici | Drop ve capture hatası **0** | Bu önekte gönderici kaybı gözlenmedi |

**Daraltılan sorun:** iPad callback ritmi 120'ye çok yakın; renderer kaybı veya termal kısıt kanıtı yok. Düzensizlik tamamlanmış kareler uygulamaya gelirken zaten mevcut. Kalan adaylar Windows kaynak güncellemeleri/capture pacing, encoder senkronizasyonu ve aktarım/read-batch zamanlaması. Mevcut saniyelik kayıtlar bunları tek bir kesin nedene ayırmıyor. Yoğun güncellemede encode ortalaması iyi olduğundan yalnız ortalama encode süresini düşürmenin tek başına çözüm olduğu söylenemez.

Seyrek/hareketsiz Windows aralıklarında encode tepeleri 31,926 ms'ye çıkıyor; tamamen statik seçilen aralıklarda ortalama 11,092 ms, yoğun güncellemede 4,019 ms. Idle→motion soğuk yol araştırması geçerli bir aday; GPU saatleri, sürücü ve CPU scheduling henüz ayrışmıyor.

Statik masaüstünün yaklaşık 250 ms heartbeat aralığı normal. Büyük bir gap önceki duruştan taşabiliyor: örneğin önceki satırın son karesi 87,813 ms önce gelmişken sonraki satırda 90,491 ms gap görünmesi, kesintisiz hareket sırasında 90 ms duruş kanıtı değildir. P95/p99 sayıları ayrı rapor pencerelerinin yaklaşık üst sınır aralıklarıdır; tüm oturumun birleştirilmiş percentilleri değildir. Yaklaşık 6 saniyelik yüksek hız kesiti kesintisiz uzun süreli 120 FPS garantisi vermez.

**Sonraki ölçüm işi:** Frame ID'yi capture timestamp, encode başlangıç/bitiş ve tam-frame gönderim zamanıyla eşleştirmek; iPad'deki tamamlanma aralığıyla karşılaştırmak. Cihaz saatleri arasında belirsizlik içeren eşleme veya yalnız aynı cihaz içindeki süreler kullanılmalı. Bu veriden önce USB hızını, iPad yenileme tercihini veya encoder mimarisini kesin suçlu seçmemek gerekir.

Ham veriler ve hesap özeti Git dışında `.codex/performance-packet2/audit-2026-10-29/` altında, dosya hash'leriyle saklandı.

## Ekranlar arası boyut geçişi

Canlı API sorgusu, yalnız sorgulama yapan Python sürecinin DPI awareness'ını ayarlayarak gerçekleştirildi; masaüstü ayarları değiştirilmedi.

| Ekran | Piksel modu | Windows UI ölçeği | Mantıksal masaüstü |
| --- | --- | --- | --- |
| 17,3 inç laptop | 1920×1080 @ 360 Hz | **%100**, 96 effective DPI | 1920×1080 |
| 12,9 inç iPad | 2732×2048 @ 120 Hz | **%200**, 192 effective DPI | 1366×1024 |

Laptop yaklaşık 127 PPI, iPad yaklaşık 264 PPI. %200/%100 geçişi normal bir pencerenin piksel ölçülerini yaklaşık yarıya indirerek fiziksel boyutu zaten birbirine yaklaştırıyor; ideal DPI-aware davranışta kalan yoğunluk farkı yaklaşık %4. Bu nedenle mevcut devleşmeyi yalnız yanlış UI ölçeği açıklamıyor. 4:3 iPad'in yüksekliği yaklaşık 19,7 cm, 16:9 laptopunki yaklaşık 21,5 cm: diyagonaller farklı olsa da yükseklikler yakın. iPad'de tam ekran bir pencerenin laptopta yüksekliğin çoğunu kaplaması bu açıdan şaşırtıcı değil.

Kullanıcı Chrome'un hemen, Spotify ve ChatGPT'nin daha geç düzeldiğini; pencere iki ekrana yayıldığında davranışın bozulduğunu bildirdi. Bu tarif, farklı DPI'lı monitörler arasında uygulamanın pencere ölçeğini değiştirmesiyle uyumlu. Windows pencereye yeni DPI ve önerilen boyutu bildirir; uygulama yeniden boyutlandırma/çizimi işler. Tek pencere iki ekrana yayılırken her iki tarafta eşzamanlı kusursuz fiziksel boyut korunması garanti değildir. [Microsoft DPI geçiş sözleşmesi](https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged), [Microsoft'un ekran sınırındaki ölçek geçişi açıklaması](https://blogs.windows.com/windowsdeveloper/2017/04/04/high-dpi-scaling-improvements-desktop-applications-windows-10-creators-update/).

Tam ekrandan başlık çubuğuyla sürükleme ayrıca uygulamanın kayıtlı normal pencere boyutuna dönmesini içerebilir. Hangi boyut geçişinin baskın olduğunu kanıtlamak için uygulama penceresinin rect, normal placement, maximize durumu ve DPI değerlerini geçiş öncesi/sonrasında izlemek gerekir. Bu incelemede kullanıcı pencereleri taşınmadı veya boyutlandırılmadı.

### WinSideUSB'nin fiziksel boyut bilgisindeki eksik

İlk sorguda WMI sanal `MTT1337` ekranı **50×31 cm** olarak bildiriyordu. Hazır imzalı vendor sürücüsünün varsayılan descriptor'ı bu boyutu taşıyor; o sırada config `CustomEdid=false` idi. Bu, eski `IddSampleDriver` Dell EDID yoluyla karıştırılmamalı. 2732×2048 ve 264 PPI bilgisinden hesaplanan görüntü alanı yaklaşık **26,3×19,7 cm**. Windows fiziksel boyut descriptor'ını DPI hesaplarında kullanır. [Microsoft display descriptor gereksinimleri](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/display/).

Modelin gerçek fiziksel boyutunu özel EDID/config ile bildirmek kalıcı bir iyileştirme olur. Mevcut UI ölçeği zaten %200 olduğu için bunun uygulamaların %200→%100 yeniden çizim davranışını tek başına ortadan kaldırması beklenmemeli. İmzalı DLL değiştirilmeden desteklenen özel descriptor yolu değerlendirilebilir; kimlik, kullanıcı ekran tercihleri, native çözünürlük, 120 Hz ve SDR ayrıca korunmalı.

Olası ürün seçenekleri: native 2732×2048 / %200 ile keskinliği korumak; veya mevcut modlara eklenmesi/doğrulanması gereken 1366×1024 / %100 gibi bir uyumluluk profiliyle iki ekranda aynı UI DPI'ı kullanmak. İkinci seçenek iPad'de görüntünün 2× büyütülmesini gerektirip yazı keskinliğini azaltabilir. Bunlar bu incelemede uygulanmadı; tüm uygulamalar için kusursuz geçiş sözü verilmemeli.

## Uygulanan fiziksel boyut düzeltmesi

Kullanıcının isteğiyle bağlı **iPad14,5 / 12,9 inç M2** için desteklenen özel EDID yolu etkinleştirildi. Kurulu imzalı sürücü dosyaları değiştirilmedi. Mevcut 256 bayt EDID'de yalnız beş bayt değişti: taban boyut alanları 50×31→26×20 cm, gerçek detailed timing görüntü alanı 355×200→**263×197 mm** ve taban checksum. Üretici/ürün/seri kimliği, monitör adı, piksel saatleri ve diğer zamanlamalar korundu; CTA uzantısı bayt düzeyinde aynı kaldı. Aktif EDID'nin SHA256 değeri hazırlanan dosyayla eşleşti: `AEBDB9853E1CB22425437AB326BA6BD871A618A5EBCC677E6848C25145D951DD`.

XML'de yalnız `CustomEdid` etkinleştirildi; registry `CUSTOMEDID=1` ile tutarlı hale getirildi. Kurulum durumundaki XML hash'i ve ilgili sahiplik kaydı güncellendi. Kurulu WinSideUSB normal çıkışla kapatıldı; yalnız sahip olunan `ROOT\MTTVDD\0000` devre dışı kaldı ve uygulama yeniden açılınca otomatik bağlandı. Broker ve Apple servisi yeniden başlatılmadı.

| Kısa doğrulama | Önce | Sonra |
| --- | --- | --- |
| iPad WMI fiziksel boyutu, cm'ye yuvarlanmış | 50×31 cm | **26×20 cm** |
| iPad aktif EDID detailed timing boyutu | 355×200 mm | **263×197 mm** |
| Windows raw DPI bildirimi | 138×167 | **263×264** |
| iPad aktif mod / UI ölçeği | 2732×2048 @120 Hz / %200 | **Aynı** |
| Laptop aktif mod / UI ölçeği | 1920×1080 @360 Hz / %100 | **Aynı** |
| Laptop ve iPad ekran konumları | [0,0] / [1920,0] | **Aynı** |

Bu doğrulama monitörün aktif modunu ölçer; yeni bir video FPS veya akıcılık benchmark'ı değildir. EDID hazırlayıcısının dört küçük testi 0,010 saniyede geçti. Ağır test veya derleme çalıştırılmadı. %200→%100 geçişinde uygulamaların DPI yeniden çizim davranışı ayrıca sürer; bu boyut düzeltmesi tüm pencere sıçramalarını giderdiğini kanıtlamaz.

Eski XML, EDID ve kurulum durumu `C:\ProgramData\WinSideUSB\edid-backup-2026-10-29` altında saklandı. Yerel hazırlık, önce/sonra sorguları ve işlem sonucu Git dışında `.codex/edid-size-2026-10-29/` altında. Geri alma gerektiğinde aynı dizindeki `apply-profile.ps1 -Action Restore` yönetici olarak çalıştırılır; güncel hash'leri doğrulamadan dosyaların üstüne yazmaz. Ardından yalnız WinSideUSB normal çıkışla kapatılıp yeniden açılır. Profil bu iPad modeline özgüdür; başka modele geçişte veya yapılandırmayı yeniden üreten kurulum güncellemesinde yeniden değerlendirilmelidir.

## Native çözünürlük korunarak iki ekrana yayılan pencere

Kullanıcı fiziksel boyut düzeltmesinden sonra aynı pencerenin laptopta kalan kısmının büyük göründüğünü doğruladı; 2732×2048 ve 120 Hz'in korunmasını istiyor. Yeniden okunan ayarlar laptop %100 / iPad %200 idi. Tek seferlik, yalnız metadata okuyan pencere sorgusunda sorunlu uygulama pencere sınırında değildi; bu nedenle belirli uygulamanın davranışı henüz ölçümle kanıtlanmış değil. Microsoft, pencere farklı DPI'lı ekranlara yayılırken bir parçasının yanlış DPI'da görünmesini açıkça tarif ediyor. [Microsoft: Dragging Windows](https://blogs.windows.com/windowsdeveloper/2017/04/04/high-dpi-scaling-improvements-desktop-applications-windows-10-creators-update/).

Mevcut kod yalnız sanal ekranın bitmiş DXGI görüntüsünü NVENC'e gönderiyor; iPad tek video katmanı çiziyor. Laptopun scanout'unu veya Chrome/Spotify/ChatGPT'nin pencerelerini ayrı parçalar halinde yeniden çizmiyor. İmzalı IDD'nin fiziksel boyutunu ya da yalnız WinSideUSB'nin DPI awareness'ını değiştirmek bu sınırı kaldırmıyor. İki ekranı da mevcut modlarında bırakıp keyfi üçüncü taraf pencerenin iki parçasını farklı fiziksel yoğunluklarda yeniden çizecek belgelenmiş bir API bulunamadı.

Çözünürlüğü düşürmeyen koşullu bir araştırma yolu **laptop tarafında supersampling/downsampling**: masaüstü 3840×2160 çizilir, GPU 1920×1080 panele küçültür, iki ekran da %200 UI ölçeği kullanır. Böylece iPad native 2732×2048 kalırken çizim pikselinin fiziksel boyutları yaklaşık eşleşebilir; 17,3 inç ve 12,9 inç bilgilerine göre yine yaklaşık %4 fark kalır. Bu bir fizibilite çıkarımıdır, bu makinede doğrulanmış çözüm değildir. NVIDIA DSR'nin yüksek çözünürlükten küçültme mekanizmasını açıklar; dizüstü kullanılabilirliği ekranın GPU bağlantısına bağlıdır. [NVIDIA DSR](https://www.nvidia.com/en-us/geforce/news/dynamic-super-resolution-instantly-improves-your-games-with-4k-quality-graphics/), [NVIDIA yetkilisinin dizüstü bağlantısı açıklaması](https://forums.developer.nvidia.com/t/dsr-on-my-laptop-gpu/248787).

Salt okunur mod listesinde laptop için 80 mod sorgulandı; en büyük mod 1920×1080 ve daha yüksek masaüstü modu şu anda listelenmiyor. Bu, DSR'nin donanımda kesin desteklenmediğini kanıtlamaz; etkinleştirilmemiş olabilir. DSR ayarı değiştirilmedi. Bu yaklaşım laptopun masaüstü yapılandırmasını ve GPU yükünü etkiler; 360 Hz laptop sinyali, yazı görünümü ve video akıcılığı ayrıca doğrulanmadan uygulanmamalı.

Diğer ayrım: Windows/IddCx, küçük masaüstünü büyük hedef görüntüsüne ölçekleyebilir. 1366×1024 masaüstünü 2732×2048 @120 hedefe büyütmek mümkün bir araştırma yoludur, fakat kaynak görüntünün native ayrıntısını korumaz. Mevcut uygulama kaynak/hedef/capture boyutlarını aynı beklediğinden ayrıca kod değişikliği gerekir. [IddCx sanal modlar](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/iddcx/ne-iddcx-iddcx_adapter_flags#constants), [Windows masaüstü ölçekleme](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/scaling-the-desktop-image). Bu kullanıcı isteğini, yalnız video dosyasının boyutunu native tutarak karşılanmış saymamak gerekir. Özel bir pencere compositor'ü ise görüntü, giriş koordinatları, odak ve z-order yönetimi gerektiren ayrı bir geliştirme olur; mevcut araştırma bunun tüm uygulamalarda native ayrıntı ve 120 FPS ile çalışacağını kanıtlamıyor.

Bu aşamada ayar/driver değişikliği veya performans testi yapılmadı; iPad 2732×2048 @120, laptop 1920×1080 @360 kaldı.

## Uygulamaya eklenen çözünürlük profilleri

Kullanıcı daha sonra uygulamadan daha düşük çözünürlük seçerek karşılaştırmayı istedi. Windows menüsüne **Native 2732×2048**, **Balanced 2048×1536** ve **Laptop-size 1366×1024** eklendi; bağlı 120 Hz modelde her profilin 60/120 Hz seçeneği var. Diğer modellerde native boyuttan türetilir, 60 Hz cihazlar sınırlandırılır ve çok küçük masaüstleri çıkarılır. Seçim uygulamanın kendi HKCU anahtarında model bazında saklanır. Değiştirme akışı **Stop display → profil seç → Start display**; yayın sırasında encoder boyutu değiştirilmez. Windows scaling kısayolu ve önerilen %100/%150 ölçek açıklamaları eklendi.

Dokuz küçük C++ davranış kontrolü geçti; 12 farklı native model/bant sınırı için üretilen 49 modun tamamı paket XML'inde bulundu. Yalnız Windows uygulaması tek mantıksal işlemci/düşük öncelikte Release derlendi; iPad, servis veya sürücü derlenmedi, benchmark çalıştırılmadı. Kurulu EXE ve XML, korumalı yedek alınarak güncellendi. XML'e yalnız eksik boyutlar eklendi; global 60/120 değerleri, özel EDID ve fiziksel boyut ayarları korundu. Kurulumun kayıtlı XML hash'i güncellendi.

Kısa gerçek bağlantı kontrolünde log `signed display configured 1366x1024@120Hz` bildirdi. Windows API sorgusu aktif iPad'i **1366×1024 @120 Hz, %100, effective DPI 96** olarak doğruladı; bu oturumda Windows ölçeği kendiliğinden %100'e uydu. Bunun her bilgisayarda otomatik gerçekleşeceği varsayılmamalı. Laptop **1920×1080 @360 Hz, %100**, aynı primary/konum/ham DPI değerlerinde kaldı. Bu kontrol videonun sürekli 120 FPS olduğunu veya pencere geçişinin kullanıcı açısından düzeldiğini kanıtlamaz; kullanıcı karşılaştırmasına bırakıldı.

Dağıtım/sorgu kayıtları Git dışında `.codex/resolution-profiles-2026-10-29/`, önceki kurulu EXE/XML/kurulum durumu/EDID ise `C:\ProgramData\WinSideUSB\resolution-backup-2026-10-29` altında. Geri alma gerektiğinde normal app çıkışından sonra aynı yerel `deploy-app.ps1 -Action Restore` yönetici olarak çalıştırılır; yalnız gözden geçirilmiş hash'lerle eşleşen dosyaları değiştirir. Eski iPad fiziksel boyut yedeği ayrıca korunur. Bu aşamada tam dağıtım kurulum paketi yeniden oluşturulmadı; bu bilgisayardaki kurulu uygulama ve kaynaklar güncellendi.
