# WinSideUSB iPad uygulaması

Bu proje iPadOS 17 ve sonrası için hazırlanmıştır ve Swift 5 dil modunu kullanır. Asıl istemci kaynağı [`../WinSideUSB/swiftclientcode.swift`](../WinSideUSB/swiftclientcode.swift) dosyasıdır. Swift Playgrounds ve kurulum paketleri de aynı dosyayı kullanır.

`Sources/WinSideUSBClient/App.swift` bu kaynağın yerel uygulama kopyasıdır. İstemciyi asıl dosyada düzenleyin ve depo kökünden eşitleyin:

```powershell
.\scripts\Sync-iPadClient.ps1
```

## iPad'de kullanım

Ana ekrandan **WinSideUSB** uygulamasını açın. **İkinci ekranınız hazır.** paneli bekleme sırasında açık kalır. iPad'i USB ile bilgisayara bağlayıp Windows'ta WinSideUSB'yi açın; Windows uygulaması istemciyi bulunca bağlantıyı otomatik kurar.

İlk görüntü gelince video tam ekran gösterilir. Kontrol paneli yayın sırasında beş saniye sonra gizlenir; normal dokunmatik kullanımda köşede kalıcı bir ayar düğmesi bırakılmaz. Görüntüye dokunarak kontroller tekrar açılır. **Ayrıntılar** açıkken ve VoiceOver kullanılırken panel otomatik gizlenmez. VoiceOver ile panel elle kapatılırsa kontrolleri tekrar açmak için erişilebilir düğme kalır. Arayüz açık/koyu görünümü, büyük yazıyı, azaltılmış hareketi ve azaltılmış saydamlığı destekler.

Bağlantı kesildiğinde istemci oturumu temizleyip yeni bağlantıyı bekler; uygulamayı kapatıp açmak gerekmez. Dinleyici açılamazsa 1, 2, 4 ve ardından en fazla 8 saniyelik aralıklarla yeniden denenir. Yeni bir PC bağlantısı, takılı kalmış eski bağlantının yerini alabilir. Sabit masaüstünde video verisi gelmemesi tek başına bağlantıyı kesmez.

**Yenile**, hem bekleme sırasında hem ilk görüntü beklenirken alıcıyı yeniden hazırlar. Bağlantı kesildiğinde veya hata olduğunda aynı işlem **Yeniden dene** düğmesiyle yapılır. Düğmeler kısa bir bekleme süresiyle art arda basılmayı sınırlar. Uygulama arka plana geçince bağlantı kapatılır; ön plana dönünce alıcı yeniden başlatılır.

**Ayrıntılar** bölümünde durum, işlenen kare sayısı, son toparlanma nedeni ve kayıt dosyası görünür. **Kaydı paylaş** oluşan CSV kaydını dışarı aktarır. Protokol, portlar ve ek tanılama bilgileri için [`../docs/IPAD_CLIENT.md`](../docs/IPAD_CLIENT.md) dosyasına bakın.

**1.1 (4)** kaynak sürümü, **İşlenen kare** sayacından ayrı **Gösterim FPS** ölçümünü ekler. iPadOS 17.4+ görüntüleyicisinin toplam ve düşen kare sayaçlarından yaklaşık saniyelik gösterim hızı hesaplanır; bu panelin Hz ölçümü değildir. İlk ölçümde, bağlantı yenilenirken, ölçüm geciktiğinde veya eski iPadOS sürümünde **—** gösterilir. Log I/O ayrı kuyrukta çalışır ve video alımı disk yazımını beklemez.

**1.1 (5)** ayrıca **Kare geliş aralığı** ve **Ekran callback ritmi** ölçümlerini ekler. Tanılamada p95 üst sınırı ve en uzun aralık, CSV'de ayrıntılı aralık istatistikleri, chunk birleştirme süresi ve güç/sıcaklık durumu bulunur. Ekran ölçümü Core Animation callback ritmidir; her callback yeni video karesi veya fiziksel panel taraması anlamına gelmez. Sistem yenileme tercihi varsayılan bırakılmıştır. Sabit görüntüde kare geliş aralıklarının uzaması normaldir.

## Derleme ve paketleme

Depo kökünden, bu bilgisayardaki Ubuntu ve xtool ile imzasız release derlemesi:

```powershell
.\scripts\Build-iPadClient.ps1
```

Betik kaynağı önce eşitler, ardından WSL içindeki projeyi güncelleyip derler. Varsayılanlar `Ubuntu-24.04`, `veysel` kullanıcısı ve `/home/veysel/projects/WinSideUSBClient` klasörüdür; `-Distribution`, `-User` ve `-LinuxProjectPath` ile değiştirilebilir.

Mevcut yerel Apple imzalama ayarlarıyla IPA hazırlamak için:

```powershell
.\scripts\Build-iPadClient.ps1 -Sign -Ipa
```

Paket `artifacts/WinSideUSBClient-recovery.ipa` dosyasına kopyalanır. `artifacts/` ve Linux derleme çıktıları Git dışında tutulur. Derleme betiği iPad'e kendiliğinden kurulum yapmaz.

USB bağlı, iPad'in kilidi açık ve bilgisayara güvenilmişken, bu bilgisayarda kullanılan iPad'e hazırlanan paketi yükleme komutu:

```powershell
wsl.exe -d Ubuntu-24.04 --user veysel -- bash -lc 'env -u USBMUXD_SOCKET_ADDRESS xtool install --usb --udid 00008112-001505042608C01E /mnt/c/Users/Veysel/Desktop/WinSideUSB/iPadClient/artifacts/WinSideUSBClient-recovery.ipa'
```

WSL'in iPad'e erişebilmesi için cihazın USB paylaşımı açık olmalıdır. `usbipd list` içindeki Apple cihazının güncel BUSID değerini kullanın; 27 Ekim kontrolünde bu değer `2-6` idi. Paylaşımı ilk kez açan `usbipd bind --busid 2-6` komutu **yönetici PowerShell** gerektirir. Ardından normal PowerShell'de `usbipd attach --wsl --busid 2-6` çalıştırıp yukarıdaki yükleme komutunu kullanın. `USBMUXD_SOCKET_ADDRESS` değişkenini komutta kaldırmak, eski Windows yönlendirmesi yerine WSL'in yerel usbmuxd bağlantısının kullanılmasını sağlar. Kurulumdan sonra `usbipd detach --busid 2-6` ile cihazı Windows'a geri bırakın; Windows yayını için cihazın WSL'e bağlı kalmaması gerekir.

Güvenilmeyen geliştirici uyarısı çıkarsa **Ayarlar → Genel → VPN ve Aygıt Yönetimi** bölümünde Apple hesabına ait geliştirici profiline güvenin. Kişisel geliştirme imzasının süresi dolunca paketi yeniden imzalayıp yükleyin.

## Doğrulama

Ritim ölçüm paketi **1.1 (5)**, 28 Ekim 2026'da dokuz küçük yardımcı kontrolden ve düşük öncelikli, tek mantıksal işlemciyle sınırlı Release derlemesinden geçti. İmzalı `artifacts/WinSideUSBClient-performance2.ipa` Windows USB yoluyla iPad'e yüklendi; kurulu build **5** doğrulandı. Paketleme/kurulum kayıtları `artifacts/performance2-package.log` ve `artifacts/performance2-install.log` dosyalarındadır. Hareket benchmarkı veya fiziksel ekran ritmi testi çalıştırılmadı.

İlk performans paketi **1.1 (4)** için 27 Ekim 2026'da altı kısa logger/FPS kontrolü geçti. Kısa bağlantı sonrasında log paylaşımını da koruyan son kaynak, 28 Ekim'de imzasız arm64 iPadOS Release derlemesinden geçti. Derleme düşük CPU/I/O önceliğinde, tek mantıksal işlemciyle sınırlandı. CoreMedia işaretlerini çalışırken geri okuyan test Apple çalışma ortamı gerektirdiği için WSL'de atlandı. 28 Ekim'de aynı kaynak mevcut Apple hesabıyla imzalanıp Windows USB bağlantısından iPad'e yüklendi; kurulu sürüm 1.1 (4) olarak doğrulandı. Gerçek görüntü/FPS denemesi kullanıcı tarafından yapılacak. `artifacts/WinSideUSBClient-recovery.ipa` önceki imzalı pakettir; build 4 IPA'sı olarak değerlendirilmemeli. Güncel imzalı paket `artifacts/WinSideUSBClient-performance1.ipa`, kurulum kaydı `artifacts/performance1-install.log` dosyasıdır. Kısa test: `..\tests\Run-iPadPerformanceTests.ps1`; derleme kaydı: `artifacts/performance1-build.log`.

Kaynak eşitliğini ve üretimdeki BSD dinleyicisini gerçek yerel soketlerle sınamak için:

```powershell
.\scripts\Sync-iPadClient.ps1
.\tests\Run-iPadTransportTests.ps1
```

27 Ekim 2026 tarihinde **1.1 (3)** sürümünün iPadOS release derlemesi uyarısız tamamlandı, mevcut Apple hesabıyla imzalanıp `artifacts/WinSideUSBClient-recovery.ipa` olarak paketlendi. Taşıma testleri **7/7 geçti**. Paket bütünlüğü, arm64 çalıştırılabilir dosyası ve imza kaynakları denetlendi. Kişisel profilin son geçerlilik zamanı ve ayrıntılı yerel doğrulama kaydı `artifacts/recovery-validation.txt` dosyasındadır.

27 Ekim 2026 tarihinde yeni paket Windows'taki mevcut Apple USB bağlantısı üzerinden iPad'e yüklendi. Cihazın kurulum verilerinden **1.1 (3)** sürümü doğrulandı; yükleme kaydı `artifacts/recovery-install-build3.log` dosyasındadır. Bu sürüm normal dokunmatik kullanımda kontroller gizlenince sağ üstte kalıcı düğme bırakmaz. WSL üzerinden xtool yükleme denemesi USB aktarımında takıldığı için bu cihazda Windows üzerinden yükleme kullanıldı. USB paylaşımı kaldırıldı ve Apple Mobile Device Service tekrar çalışır duruma getirildi.

Cihazda arayüz, gerçek Windows görüntü aktarımı, kabloyu çıkarıp takma ve arka plandan dönüş kontrolleri ayrıca doğrulanmalıdır.
