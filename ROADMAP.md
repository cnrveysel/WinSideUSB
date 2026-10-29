# WinSideUSB Roadmap

Güncel performans önceliği: büyük pencere hareketi ve sabit görüntüden ani harekete geçiş için kod/log bulguları, uygulama sırası ve kabul testleri [120 Hz akıcılık yol haritasında](docs/PERFORMANCE_120HZ_ROADMAP.md) yer alıyor (27 Ekim 2026).

Hedef: iPad'i USB üzerinden ikinci ekran ve Apple Pencil ile yazılabilen bir çalışma alanı olarak kullanmayı kolaylaştırmak. Kullanıcı Windows tarafında tek bir setup EXE çalıştırabilmeli; uygulama, sürücü ve gerekli bağımlılıklar birlikte kurulmalı ve aynı kolaylıkla kaldırılabilmeli.

Öncelik sırası: **arayüz → tek setup EXE → otomatik kaldırma → Apple Pencil desteği**. Tamamlanan uygulama işleri işaretlenmiştir; kalan işler ve cihaz testleri aşağıda takip edilir. Sürücü imzalama araştırması, setup aşamasını bekletmemek için arayüz çalışmasıyla paralel başlayabilir. Henüz teslim tarihi belirlenmedi.

## Mevcut durum

- Windows uygulaması sanal ekran oluşturuyor, görüntüyü H.264 ile USB üzerinden iPad'e gönderiyor.
- Windows arayüzü ve Swift iPad görüntüleyicisi mevcut.
- Tek setup EXE için Inno Setup kaynağı ve paketleme scripti eklendi; uygulama, sürücü, Visual C++ runtime ve kayıtlı kaldırıcı birlikte paketleniyor.
- Yeni setup sürücü/sertifika sahipliğini kaydediyor; kurulum ve kaldırma kendi cihaz/paket kimliklerini kullanıyor. Temiz bilgisayarda kurulum, yükseltme ve tam kaldırma testleri bekliyor.
- Önceki ZIP/CMD/PowerShell geliştirici önizlemesi ayrı bir eski kurulum akışı olarak duruyor; kaldırma scriptinin kurulu dizine kopyalanması düzeltildi, eski kurulumun gerçek kaldırma testi bekliyor.
- Apple Mobile Device Service ön koşulu algılanıyor; eksikse resmi Apple kurulum yönlendirmesi gösteriliyor. Apple yazılımını otomatik kurma ve yeniden dağıtım yolu henüz tamamlanmadı.
- Varsayılan Signed setup, değiştirilmeyen hazır imzalı Virtual Display Driver x64 paketini kullanıyor. iPad istemcisi bağlanana kadar sanal cihaz kapalı tutuluyor; bağlantı bitince arka plan hizmeti kapatıyor. Kendi geliştirme sürücümüzün test imzalı akışı ayrıca duruyor.
- Apple Pencil olaylarını yakalayan ve Windows'a ileten bir giriş sistemi henüz yok.

## 1. Daha güzel ve kullanışlı arayüz

- [x] Windows uygulaması için tutarlı renk, tipografi, ikon, boşluk ve buton tasarımı hazırlamak.
- [x] Yüksek DPI, farklı Windows ölçekleri ve pencere boyutlarında düzgün yerleşim sağlamak.
- [x] Bağlı iPad'i, çözünürlük/Hz seçimini ve Başlat/Durdur kontrolünü anlaşılır bir ana ekranda toplamak.
- [x] Bağlantı bekleme, görüntü hazırlama, yayın, durdurma ve yeniden bağlanma durumlarını anlaşılır yönlendirmelerle göstermek.
- [x] FPS ve kodlayıcı bilgisini okunabilir göstermek; Windows'ta log klasörüne, iPad'de açılır tanılama alanına erişim eklemek.
- [x] iPad arayüzünü düzenlemek; yayın sırasında kontrolleri gizleyebilmek ve gerektiğinde tekrar açabilmek.
- [x] Windows'ta klavye ile kullanım, görünür odak ve okunabilir kontrast sağlamak; iPad'de erişilebilirlik ayarlarını gözetmek.
- [ ] iPad istemcisini gerçek cihazda derlemek; açık/koyu tema, ekran yönü, büyük yazı boyutu ve yayın geçişlerini doğrulamak.
- [ ] Fiziksel iPad ile Windows arayüzünden başlatma/durdurma, USB kopması ve yeniden bağlanma akışını doğrulamak; sürücü hatalarını daha ayrıntılı sınıflandırmak.

**Tamamlanma ölçütü:** Kullanıcı iPad'i bağlayıp modu seçerek yayını tek ekrandan başlatıp durdurabiliyor. Bağlantı ve sürücü hatalarında ne yapacağı belli; yüksek DPI'da yazılar veya kontroller kesilmiyor.

## 2. Tek setup EXE ile otomatik kurulum

- [x] Uygulama, IDD sürücü paketi, uygulamaya gömülü USB yardımcı araçları, Visual C++ runtime ve mevcut lisans belgelerini tek setup EXE içinde paketleyecek Inno Setup/`Build-Setup.ps1` akışını hazırlamak.
- [x] Son kullanıcı kurulumunu Visual Studio, WDK, SDK veya elle PowerShell komutu gerektirmeden setup üzerinden yürütmek.
- [x] Windows 11 x64, Media Foundation/Windows N, USB servis ön koşulu, sürücü imzası ve mevcut kurulum için ön kontroller eklemek.
- [x] Yönetici iznini setup üzerinden istemek; dosya kopyalama, sanal cihaz oluşturma, sürücü kurulumu ve kısayolları otomatik yürütmek.
- [x] Visual C++ x64 runtime kurulumunu pakete eklemek; uygulama kaldırılırken ortak runtime'ı korumak.
- [x] Apple Mobile Device Service'i algılamak; eksikse resmi Apple Devices/iTunes kurulum yönlendirmesi göstermek ve eksik ön koşulu başarılı kurulum gibi sunmamak.
- [ ] Apple USB yazılımını otomatik kurma yolunu, lisans ve dağıtım koşullarıyla birlikte doğrulamak.
- [ ] Gömülü üçüncü taraf dosyaların sürüm/kaynak envanterini ve tüm dağıtım lisansı/bildirimlerini yayın öncesi tamamlamak.
- [x] Development ve Release setup paketlerini ayırmak; Release yolunda uygulama/DLL/CAT güvenilen imzalarını ve setup/kaldırıcı imzalamasını zorunlu tutmak. Development pakette test-signing/Secure Boot ayarlarını değiştirmeden mevcut koşulları denetlemek.
- [ ] x64 UMDF/IDD sürücü paketi için güvenilen ticari release imzası yolunu doğrulamak; Microsoft WHQL imzalama seçeneğini hedef platformlara göre değerlendirmek. Uygulama ve setup EXE için kod imzalamayı hazırlamak.
- [ ] Normal sürümün Secure Boot açıkken, test-signing açmadan kurulmasını doğrulamak. Test imzalı geliştirme paketini ayrı tutmak.
- [x] Hazır imzalı MIT lisanslı sanal ekran paketini değiştirmeden doğrulayıp Signed setup'a entegre etmek; kendi imza sertifikamızı zorunlu tutmamak.
- [x] İkinci ekranı yalnız USB iPad istemcisi bağlantısı sırasında açmak; durdurma, bağlantı kopması, uygulama kapanması ve hizmet oturum kaybında kapatan akış eklemek.
- [x] Mevcut iPad piksel/Hz listesini korumak, tam modu doğrulamak ve sanal ekranı tüm GPU'larda cihaz kimliğiyle bulmak.
- [ ] Hazır sürücüyle gerçek cihazda tüm çözünürlük/Hz seçeneklerini, boşta USB çıkarma, tekrar bağlanma ve hizmet kurtarmasını doğrulamak.
- [x] Sürücü kurulum sonucu ve cihaz durumunu denetleyen; hata/yeniden başlatma durumlarını ayrı bildiren kurulum akışı eklemek.
- [x] Başarısız sürücü kurulumunda o işlemde eklenen cihaz/paket için geri alma ve kurulum sahipliği kaydı eklemek.
- [x] Kurulu dosya, sürücü paketi, cihaz ve sertifika sahipliğini kaldırma/yükseltme için kaydetmek.
- [ ] Temiz Windows 11 x64 bilgisayarda kurulum, yükseltme, onarım, yeniden başlatma ve hata sonrası geri alma senaryolarını doğrulamak.

**Tamamlanma ölçütü:** Desteklenen temiz Windows 11 x64 sisteminde tek EXE ile uygulama, sürücü ve gerekli Windows bağımlılıkları kuruluyor. Kullanıcı yönetici izni ve gerekiyorsa yeniden başlatma dışında elle sürücü kurmuyor. Apple USB yazılımının eksik olduğu sistemler için de doğrulanmış bir edinme/kurulum yolu var. Üretim sürümü Secure Boot açıkken çalışıyor.

**Uygulanan paketleme akışı:** `scripts/Build-Setup.ps1` ve `installer/WinSideUSB.iss`. Varsayılan Signed çıktı `WinSideUSB-{sürüm}-Setup.exe`, hazır imzalı sürücü ve ekran hizmetini içeriyor. Development/Release akışları ayrı duruyor. Kurulum/kaldırma rehberi: [docs/SETUP.md](docs/SETUP.md), ekran ömrü ve sınırları: [docs/SIGNED_DISPLAY.md](docs/SIGNED_DISPLAY.md). İşaretler uygulanan kod akışını gösteriyor; temiz bilgisayar ve gerçek iPad testleri bekliyor.

**Bağımlılık:** Varsayılan paket için hazır imzalı sürücü seçildi ve dosya/imza kontrolleri tamamlandı. Bu aşamanın kalan koşulu, Secure Boot açık ve test modu kapalı temiz bir bilgisayarda gerçek kurulum, iPad bağlantısı ve kaldırmayı doğrulamak.

**İmza ayrımı:** Sürücümüz kullanıcı modunda çalışan UMDF/IDD'dir. Microsoft'un PnP kuralları, normal x64 Windows için WHQL yanında güvenilen üçüncü taraf release sertifikasıyla imzalanmış paketleri de kabul ediyor. Bu nedenle tüm hedefler için baştan Microsoft imzasını zorunlu saymıyoruz. Seçilen imzalama yolu, kendi DLL/CAT paketimizle Secure Boot açık ve test-signing kapalı temiz sistemlerde doğrulanacak. S mode ve ARM64 gibi hedeflerin ek koşulları ayrıca değerlendirilecek. Kaynaklar: [Microsoft PnP imza koşulları](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/pnp-device-installation-signing-requirements--windows-vista-and-later-), [IDD modeli](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/indirect-display-driver-model-overview).

**iPad tarafı:** Windows setup EXE, iPad uygulamasının dağıtımının yerine geçmiyor. Setup/ilk kullanım ekranında iPad istemcisini edinme ve açma adımı gösterilecek; istemci için uygun iPadOS dağıtım yolu ayrıca belirlenecek.

## 3. Aynı kolaylıkta otomatik kaldırma

- [x] Eski geliştirici kurulumunda kaldırma scriptini kurulu dizine kopyalama eksikliğini düzeltmek.
- [ ] Eski ZIP önizlemesini gerçekten kurup belgelerdeki kurulu dizinden kaldırma yolunu doğrulamak.
- [x] Yeni EXE setup'ta Windows Yüklü Uygulamalar kaydı ve setup ile birlikte kaldırıcı üretmek.
- [x] Yeni kurulumda yayını durdurup uygulamaya ait süreçleri ve sanal cihazı temizleyecek kaldırma akışını eklemek.
- [x] Kurulumda kaydedilen kimliklerle uygulamaya ait sanal cihazı ve sahip olunan sürücü paketini kaldırma akışını eklemek; ortak bağımlılıkları korumak.
- [x] Yeni setup'ın kurduğu uygulama dosyaları, kısayollar ve kurulum kayıtları için otomatik temizleme eklemek.
- [ ] Ayarları ve logları saklama veya silme seçeneği sunmak.
- [x] Development setup'ta test sertifikası sahipliğini kaydetmek; kaldırmada yalnızca bu kurulumun eklediği sertifikaları hedeflemek.
- [x] Sürücü kaldırma hatasında veya yeniden başlatma gereksiniminde uygulama/yardımcı scriptleri koruyup tekrar kaldırma adımını bildiren akış eklemek.
- [ ] Kilitli dosya, ortak sürücü paketi ve sertifika paylaşımı durumlarını gerçek kurulumlarda doğrulamak.
- [ ] Tekrarlanan kaldırma, kurulum → kaldırma → yeniden kurulum ve sürüm yükseltme senaryolarını doğrulamak.

**Tamamlanma ölçütü:** Kullanıcı Windows Yüklü Uygulamalar üzerinden kaldırınca uygulama ve ona ait sanal ekran/sürücü paketi temizleniyor. Yeniden kurulum düzgün çalışıyor; diğer ekran sürücüleri ve ortak bağımlılıklar etkilenmiyor. Kaldırma sonucu eksik kalan bir işlem varsa bunu gösteriyor.

## 4. iPad'de Apple Pencil ile Windows'a yazma

Hedef, iPad'de gösterilen Windows uygulamasına doğrudan kalemle yazmak ve çizmek; örneğin OneNote üzerinde el yazısı kullanmak.

### 4.1. Temel kalem girişi

- [ ] Swift istemcide Apple Pencil'ın temas başlangıcı, hareketi, kaldırılması ve iptal olaylarını yakalamak.
- [ ] iPad → Windows yönünde USB üzerinden giriş iletimi eklemek; paket formatını, protokol sürümünü ve özellik anlaşmasını tanımlamak.
- [ ] Video yükü altında kalem olaylarının beklememesi için giriş iletimini ölçmek; gerekirse ayrı bir giriş kanalı kullanmak.
- [x] Signed akışında hedef sanal monitörü cihaz kimliğiyle seçmek; çoklu ekran sistemlerinde çıkış sırasına bağlı seçimi kaldırmak.
- [ ] iPad'deki görüntü koordinatlarını doğru Windows sanal ekranına eşlemek; DPI, ölçekleme, döndürme, görüntü kırpılması ve birden fazla monitörü hesaba katmak.
- [ ] Windows'ta kalem girişi oluşturma yöntemini bir prototiple doğrulamak; destek sınırlarını belirleyip temel yazma akışını uygulamak.
- [ ] Kalem ve parmak girişini ayırmak; avuç içi temaslarının yanlış çizgi üretmesini önlemek.
- [ ] USB kopması, uygulamanın arka plana geçmesi veya yayının durması halinde aktif kalem temasını sonlandırmak.
- [ ] Windows ve iPad arayüzüne kalem desteğini açma/kapatma kontrolü eklemek.

**Tamamlanma ölçütü:** Fiziksel iPad ve Apple Pencil ile Windows'ta OneNote üzerinde kesintisiz yazı/çizgi oluşuyor. Kalem kaldırılınca çizgi bitiyor, avuç içi yanlış giriş üretmiyor ve bağlantı kopunca kalem basılı kalmıyor. Farklı ekran ölçeklerinde kalem ucu ile çizgi hizalı kalıyor.

### 4.2. Basınç ve gelişmiş kalem özellikleri

- [ ] Donanımın sağladığı basınç ve eğim bilgilerini giriş protokolüne eklemek ve Windows tarafında desteklenen özelliklere eşlemek.
- [ ] Basınç destekleyen bir Windows uygulamasında çizgi kalınlığının kalem basıncına tepki verdiğini doğrulamak.
- [ ] Destekleyen Pencil modellerinde hover ve ek kalem hareketlerini değerlendirmek; modelin desteklemediği özellikleri arayüzde etkin göstermemek.
- [ ] Kalem örneklerini ve olay sırasını koruyarak gecikmeyi ölçmek; gerekirse hareket örneklerini toplu iletmek.
- [ ] Test edilen iPad/Pencil modellerini, Windows uygulamalarını ve basınç desteği sınırlarını belgelemek.

**Tamamlanma ölçütü:** Destekleyen donanım ve Windows uygulamasında basınç/eğim verileri korunuyor. Yalnızca konum/tıklama sağlayan bir yöntem, tam basınç destekli kalem girişi olarak sunulmuyor.

## Sürüm öncesi doğrulama

- [ ] Arayüz ve kalem değişikliklerinden sonra yayın başlatma/durdurma ve USB yeniden bağlanma testlerini yapmak.
- [ ] Temiz kurulum, yükseltme, onarım, hata sonrası geri alma ve tam kaldırmayı test makinelerinde doğrulamak.
- [ ] Kalem kullanırken görüntü akıcılığı ile giriş gecikmesini ölçmek; NVIDIA ve Media Foundation yollarını ayrı kaydetmek.
- [ ] README, kurulum/kaldırma rehberi ve iPad istemci rehberini tamamlanan özelliklere göre güncellemek.
