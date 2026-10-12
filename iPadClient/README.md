# WinSideUSB iPad uygulaması

Gönderilen Swift kodu `Sources/WinSideUSBClient/App.swift` dosyasına değiştirilmeden kopyalandı. Proje iPad için, iPadOS 17 ve sonrası hedeflenerek hazırlanmıştır. Orijinal kodun Swift dil modu korunmak için Swift 5 kullanılır.

10 Ekim 2026 tarihinde release derlemesi tamamlandı; bağlı iPad'e USB üzerinden imzalanarak yüklendi ve kurulum doğrulandı. Uygulamanın çalışması ve bilgisayardan video alması henüz doğrulanmadı. xtool ile uzaktan açma denemesi `DebugserverClient.Error.unknown` hatası verdi.

## iPad'de açma

Ana ekrandan **WinSideUSB** uygulamasını aç. Güvenilmeyen geliştirici uyarısı çıkarsa **Ayarlar → Genel → VPN ve Aygıt Yönetimi** bölümünde Apple hesabına ait geliştirici profiline güven. Geliştirici Modu cihazda açık olarak doğrulandı.

Başlangıçta `PC bekleniyor` mesajı beklenir. Kodun durum paneli üç saniye sonra gizlenir; ekrana dokunarak tekrar gösterilebilir. Bilgisayardaki WinSideUSB uygulaması yayın başlatınca video alınır.

## Dosyalar

- `artifacts/WinSideUSBClient.ipa`: mevcut Apple hesabıyla imzalanmış iPad uygulaması.
- `artifacts/build.log`, `artifacts/package.log`, `artifacts/install.log`: derleme, imzalama ve kurulum kayıtları.
- Linux derleme klasörü: `/home/veysel/projects/WinSideUSBClient`.

## Yeniden derleme

PowerShell'de, bu bilgisayarda kurulu Ubuntu ve xtool kullanılarak:

```powershell
wsl.exe -d Ubuntu-24.04 --user veysel -- bash -lc 'cp /mnt/c/Users/Veysel/Desktop/WinSideUSB/iPadClient/Package.swift /mnt/c/Users/Veysel/Desktop/WinSideUSB/iPadClient/xtool.yml /mnt/c/Users/Veysel/Desktop/WinSideUSB/iPadClient/Info.plist /home/veysel/projects/WinSideUSBClient/; cp -r /mnt/c/Users/Veysel/Desktop/WinSideUSB/iPadClient/Sources/. /home/veysel/projects/WinSideUSBClient/Sources/; cd /home/veysel/projects/WinSideUSBClient && xtool dev build --configuration release --sign --ipa'
```

USB kablosu bağlı ve ekran kilidi açıkken aynı iPad'e tekrar yüklemek için:

```powershell
wsl.exe -d Ubuntu-24.04 --user veysel -- bash -lc 'xtool install --usb --udid 00008112-001505042608C01E /home/veysel/projects/WinSideUSBClient/xtool/WinSideUSBClient.ipa'
```

Apple'ın kişisel geliştirme profili kalıcı dağıtım için değildir. İmza süresi bittiğinde yeniden imzalamak ve yüklemek gerekir; mevcut paketin son geçerlilik tarihi `artifacts/provisioning.txt` dosyasındadır.
