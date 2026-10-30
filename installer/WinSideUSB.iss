; Built by scripts/Build-Setup.ps1. All payloads are local at compile time.
#ifndef PayloadDir
  #error PayloadDir must be supplied by Build-Setup.ps1
#endif
#ifndef AppleInstallerUrl
  #error AppleInstallerUrl must be supplied by Build-Setup.ps1
#endif
#ifndef AppleInstallerSHA256
  #error AppleInstallerSHA256 must be supplied by Build-Setup.ps1
#endif
#ifndef AppVersion
  #define AppVersion "0.3.12"
#endif
#ifndef DriverMode
  #define DriverMode "Signed"
#endif
#if DriverMode == "Development"
  #define ProductName "WinSideUSB Development Preview"
  #define OutputName "WinSideUSB-" + AppVersion + "-Development-Setup"
#else
  #define ProductName "WinSideUSB"
  #define OutputName "WinSideUSB-" + AppVersion + "-Setup"
#endif

[Setup]
AppId={{B1638B2B-88F8-40A2-B7C0-B75F2EE9BA5F}
AppName={#ProductName}
AppVersion={#AppVersion}
AppPublisher=WinSideUSB
DefaultDirName={autopf}\WinSideUSB
DefaultGroupName=WinSideUSB
DisableWelcomePage=no
DisableDirPage=no
DisableReadyPage=no
DisableFinishedPage=no
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.22000
WizardStyle=modern light
WizardSizePercent=110
SetupLogging=yes
CloseApplications=yes
CloseApplicationsFilter=WinSideUSB.exe
RestartApplications=no
SetupMutex=Global\WinSideUSBSetup
OutputBaseFilename={#OutputName}
OutputDir={#OutputDir}
Compression=lzma2
SolidCompression=yes
UninstallDisplayIcon={app}\WinSideUSB.exe
UninstallDisplayName={#ProductName}
VersionInfoVersion={#AppVersion}
LicenseFile={#PayloadDir}\LICENSE
#ifdef SignCommand
SignTool=WinSideUSB {#SignCommand}
SignedUninstaller=yes
#endif

[Languages]
Name: turkish; MessagesFile: compiler:Languages\Turkish.isl
Name: english; MessagesFile: compiler:Default.isl

[CustomMessages]
turkish.WelcomeLabel1=WinSideUSB'ye hoş geldiniz
turkish.WelcomeLabel2=iPad'inizi Windows'un ikinci ekranına dönüştürün.%n%nKurulum uygulamayı, sanal ekran sürücüsünü ve gerekli Windows bileşenlerini hazırlar.%n%nApple USB desteği eksikse Apple'ın resmi paketi indirilip yalnız USB bileşeni kurulur (yaklaşık 200 MB). Windows N'de eksik medya bileşenleri de indirilir. Gerekli indirmeler için internet bağlantısı gerekir. iPad uygulamasını ayrıca açın.
english.WelcomeLabel1=Welcome to WinSideUSB
english.WelcomeLabel2=Turn your iPad into a second Windows display.%n%nSetup installs the app, virtual display driver, and Windows components.%n%nIf Apple USB support is missing, setup downloads Apple's official package (about 200 MB) and installs its USB component. Missing Windows N media components are also downloaded. These downloads require internet access. Open the iPad app separately.
turkish.DevelopmentNotice=Bu bir geliştirme sürümüdür. Test imzalı sürücü için Windows test-signing açık ve Secure Boot kapalı olmalıdır. Kurulum bu ayarları değiştirmez.
english.DevelopmentNotice=This is a development preview. Its test-signed driver requires Windows test-signing on and Secure Boot off. Setup does not change these settings.
turkish.AppleButton=Apple lisans koşulları
english.AppleButton=Apple license terms
turkish.AppleUsbTask=Apple USB desteğini otomatik hazırla (Apple koşullarını kabul ediyorum)
english.AppleUsbTask=Prepare missing Apple USB support (I accept Apple's terms)
turkish.MediaTask=Windows N'de eksik medya bileşenlerini hazırla
english.MediaTask=Prepare missing media components on Windows N
turkish.AppleDownloadTitle=Apple USB desteği indiriliyor
english.AppleDownloadTitle=Downloading Apple USB support
turkish.AppleDownloadDescription=Apple'ın resmi iTunes paketi indiriliyor. USB desteği zaten kuruluysa bu indirme yapılmaz.
english.AppleDownloadDescription=Downloading Apple's official iTunes package. This download is skipped when USB support is already installed.
turkish.AppleRequired=Apple USB desteği eksik. Geri dönüp Apple USB desteği seçeneğini etkinleştirin; kurulum bunu sizin için hazırlasın.
english.AppleRequired=Apple USB support is missing. Go back and enable the Apple USB support option so setup can prepare it for you.
turkish.PrerequisiteProgress=Gerekli Windows ve Apple USB bileşenleri hazırlanıyor. Bu işlem birkaç dakika sürebilir...
english.PrerequisiteProgress=Preparing Windows and Apple USB components. This can take several minutes...
turkish.PublisherTitle=Ekran sürücüsü yayıncısı
english.PublisherTitle=Display driver publisher
turkish.PublisherDescription=Windows ilk kurulumda SignPath Foundation yayıncısı için onay isteyebilir.
english.PublisherDescription=Windows can request approval for SignPath Foundation on the first installation.
turkish.PublisherNotice=İsterseniz aşağıdaki seçeneği işaretleyerek sürücüyü otomatik kurabilirsiniz.%n%nBu seçim, doğrulanan yayıncı sertifikasını bu bilgisayardaki güvenilen yayıncılara ekler; aynı sertifikayla imzalanmış diğer sürücülerin onayını da etkiler. Önceden var olan kayıtlar korunur. WinSideUSB'nin eklediği kayıt, kaldırma sırasında başka bir sürücü kullanmıyorsa temizlenir.%n%nSeçmezseniz Windows'un yayıncı onayını kendiniz verirsiniz.
english.PublisherNotice=You can select the option below to install the driver automatically.%n%nThis adds the verified signing certificate to trusted publishers on this PC; it also affects approval for other drivers signed with the same certificate. Existing trust is preserved. Trust added by WinSideUSB is removed on uninstall when no other driver uses it.%n%nLeave it unchecked to approve the publisher in Windows yourself.
turkish.PublisherOption=SignPath Foundation yayıncısına bu bilgisayarda güven
english.PublisherOption=Trust SignPath Foundation on this PC
turkish.DesktopShortcut=Masaüstü kısayolu oluştur
english.DesktopShortcut=Create a desktop shortcut
turkish.LaunchApp=WinSideUSB'yi aç
english.LaunchApp=Open WinSideUSB
turkish.OpenIPadGuide=iPad kurulum rehberini aç
english.OpenIPadGuide=Open the iPad setup guide
turkish.DriverProgress=Sanal ekran sürücüsü kuruluyor...
english.DriverProgress=Installing the virtual display driver...
turkish.RuntimeProgress=Windows çalışma bileşenleri hazırlanıyor...
english.RuntimeProgress=Preparing the Windows runtime...
turkish.SetupFailed=Kurulum tamamlanamadı. Ayrıntılar:
english.SetupFailed=Setup could not finish. Details:
turkish.DriverCleanupFailed=Sürücü kaldırılamadı. Uygulama korunuyor; tekrar kaldırmayı deneyin. Ayrıntılar:
english.DriverCleanupFailed=The driver could not be removed. The app is preserved; retry uninstall. Details:
turkish.FinishedLabel=Hazır. WinSideUSB'yi ve iPad uygulamasını açıp USB kablosunu bağlayın. İkinci ekran bağlantı kurulunca otomatik açılır, bağlantı kesilince kapanır.
english.FinishedLabel=Ready. Open WinSideUSB and the iPad app, then connect USB. The second display opens when the client connects and closes when it disconnects.

[Tasks]
Name: desktopicon; Description: "{cm:DesktopShortcut}"
Name: appleusb; Description: "{cm:AppleUsbTask}"
Name: media; Description: "{cm:MediaTask}"

[Files]
; Put prerequisites first so early extraction remains quick with solid compression.
Source: "{#PayloadDir}\scripts\Setup-Driver.ps1"; DestDir: "{tmp}\driver-tools"; Flags: dontcopy
Source: "{#PayloadDir}\scripts\Setup-DriverSupport.psm1"; DestDir: "{tmp}\driver-tools"; Flags: dontcopy
Source: "{#PayloadDir}\scripts\Setup-Prerequisites.ps1"; DestDir: "{tmp}\driver-tools"; Flags: dontcopy
Source: "{#PayloadDir}\scripts\Setup-PrerequisitesSupport.psm1"; DestDir: "{tmp}\driver-tools"; Flags: dontcopy
Source: "{#PayloadDir}\scripts\AppleUsbPrerequisite.json"; DestDir: "{tmp}\driver-tools"; Flags: dontcopy
#if DriverMode == "Signed"
Source: "{#PayloadDir}\WinSideUSBDisplayService.exe"; DestDir: "{tmp}\driver-tools"; Flags: dontcopy
#endif
Source: "{#PayloadDir}\driver\*"; DestDir: "{tmp}\driver"; Flags: dontcopy
Source: "{#PayloadDir}\vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: dontcopy
Source: "{#PayloadDir}\WinSideUSB.exe"; DestDir: "{app}"; Flags: ignoreversion
#if DriverMode == "Signed"
Source: "{#PayloadDir}\WinSideUSBDisplayService.exe"; DestDir: "{app}"; Flags: ignoreversion
#endif
Source: "{#PayloadDir}\driver\*"; DestDir: "{app}\driver"; Flags: ignoreversion
Source: "{#PayloadDir}\scripts\*"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#PayloadDir}\docs\*"; DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PayloadDir}\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PayloadDir}\iPad\*"; DestDir: "{app}\iPad"; Flags: ignoreversion
Source: "{#PayloadDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\NOTICE.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\payload-manifest.json"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\WinSideUSB"; Filename: "{app}\WinSideUSB.exe"
Name: "{autodesktop}\WinSideUSB"; Filename: "{app}\WinSideUSB.exe"; Tasks: desktopicon
Name: "{group}\iPad setup guide"; Filename: "{app}\docs\iPad-Guide.html"

[Run]
Filename: "{app}\WinSideUSB.exe"; Description: "{cm:LaunchApp}"; Flags: nowait postinstall skipifsilent runasoriginaluser; Check: CanLaunch
Filename: "{app}\docs\iPad-Guide.html"; Description: "{cm:OpenIPadGuide}"; Flags: shellexec postinstall skipifsilent unchecked runasoriginaluser

[Code]
var
  DriverInstalled, Finalized, Finished, HadState, RestartRequired: Boolean;
  AppleButton: TNewButton;
  AppleDownloadPage: TDownloadWizardPage;
  PublisherPage: TInputOptionWizardPage;

function StatePath: String;
begin
  Result := ExpandConstant('{commonappdata}\WinSideUSB\setup-state.json');
end;

function ReadMessage(const Path, Fallback: String): String;
var
  Data: AnsiString;
begin
  Result := Fallback;
  if LoadStringFromFile(Path, Data) then Result := UTF8Decode(Data);
  if (Length(Result) > 0) and (Ord(Result[1]) = 65279) then Delete(Result, 1, 1);
end;

function RunDriver(const ScriptDir, PackageDir, Action, State: String): Integer;
var
  Params: String;
begin
  Params := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    ScriptDir + '\Setup-Driver.ps1" -Action ' + Action + ' -PackageDir "' +
    PackageDir + '" -StatePath "' + State + '" -DriverMode {#DriverMode}';
#if DriverMode == "Signed"
  Params := Params + ' -InstallDir "' + ExpandConstant('{app}') + '"';
  if (Action = 'Check') or (Action = 'Install') then begin
    if PublisherPage.Values[0] then Params := Params + ' -TrustDriverPublisher';
    if WizardSilent then Params := Params + ' -NonInteractive';
  end;
  if (Action = 'Check') or (Action = 'Install') then
    Params := Params + ' -ServicePath "' + ExpandConstant('{tmp}\driver-tools\WinSideUSBDisplayService.exe') + '"'
  else
    Params := Params + ' -ServicePath "' + ExpandConstant('{app}\WinSideUSBDisplayService.exe') + '"';
#endif
#if DriverMode == "Development"
  Params := Params + ' -CertificatePath "' + PackageDir + '\IddSampleDriver.cer"';
#endif
  if not Exec(ExpandConstant('{sysnative}\WindowsPowerShell\v1.0\powershell.exe'),
    Params, ScriptDir, SW_HIDE, ewWaitUntilTerminated, Result) then Result := -1;
end;

function RunPrerequisites(const Action, ResultPath: String): Integer;
var
  Params: String;
begin
  Params := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{tmp}\driver-tools\Setup-Prerequisites.ps1') +
    '" -Action ' + Action + ' -AppPath "' + ExpandConstant('{app}\WinSideUSB.exe') +
    '" -ResultPath "' + ResultPath + '"';
  if Action = 'Prepare' then begin
    if FileExists(ExpandConstant('{tmp}\AppleUSBSetup.exe')) then
      Params := Params + ' -AppleInstallerPath "' + ExpandConstant('{tmp}\AppleUSBSetup.exe') + '"';
    if WizardIsTaskSelected('media') then Params := Params + ' -InstallMissingMedia';
  end;
  if not Exec(ExpandConstant('{sysnative}\WindowsPowerShell\v1.0\powershell.exe'),
    Params, ExpandConstant('{tmp}\driver-tools'), SW_HIDE, ewWaitUntilTerminated, Result) then Result := -1;
end;

function RuntimeNeeded: Boolean;
var
  Installed: Cardinal;
  Version: String;
  InstalledVersion, RequiredVersion: Int64;
begin
  Result := True;
  if RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Installed', Installed) and
    (Installed = 1) and RegQueryStringValue(HKLM64,
    'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Version', Version) then begin
    if (Length(Version) > 0) and (Version[1] = 'v') then Delete(Version, 1, 1);
    if StrToVersion(Version, InstalledVersion) and StrToVersion('{#RuntimeVersion}', RequiredVersion) then
      Result := ComparePackedVersion(InstalledVersion, RequiredVersion) < 0;
  end;
end;

procedure OpenAppleSupport(Sender: TObject);
var
  ErrorCode: Integer;
begin
  ShellExecAsOriginalUser('open', 'https://www.apple.com/legal/sla/', '', '', SW_SHOWNORMAL, ewNoWait, ErrorCode);
end;

procedure InitializeWizard;
begin
  WizardForm.WelcomeLabel1.Caption := CustomMessage('WelcomeLabel1');
  WizardForm.WelcomeLabel2.Caption := CustomMessage('WelcomeLabel2');
#if DriverMode == "Development"
  WizardForm.WelcomeLabel2.Caption := WizardForm.WelcomeLabel2.Caption + #13#10#13#10 + CustomMessage('DevelopmentNotice');
#endif
  AppleButton := TNewButton.Create(WizardForm);
  AppleButton.Parent := WizardForm;
  AppleButton.SetBounds(ScaleX(16), WizardForm.CancelButton.Top, ScaleX(190), WizardForm.CancelButton.Height);
  AppleButton.Caption := CustomMessage('AppleButton');
  AppleButton.OnClick := @OpenAppleSupport;
  AppleDownloadPage := CreateDownloadPage(CustomMessage('AppleDownloadTitle'), CustomMessage('AppleDownloadDescription'), nil);
  AppleDownloadPage.ShowBaseNameInsteadOfUrl := True;
#if DriverMode == "Signed"
  PublisherPage := CreateInputOptionPage(wpSelectTasks, CustomMessage('PublisherTitle'), CustomMessage('PublisherDescription'), CustomMessage('PublisherNotice'), False, False);
  PublisherPage.Add(CustomMessage('PublisherOption'));
  PublisherPage.Values[0] := ExpandConstant('{param:TRUSTDISPLAYPUBLISHER|0}') = '1';
#endif
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
  CheckState, MessageFile: String;
begin
  Result := '';
  if DriverInstalled then exit;
  ExtractTemporaryFiles('{tmp}\driver-tools\*');
  ExtractTemporaryFiles('{tmp}\driver\*');
  CheckState := ExpandConstant('{tmp}\check\setup-state.json');
  Code := RunDriver(ExpandConstant('{tmp}\driver-tools'), ExpandConstant('{tmp}\driver'), 'Check', CheckState);
  if Code <> 0 then begin
    Result := ReadMessage(ExpandConstant('{tmp}\check\setup-result.txt'), CustomMessage('SetupFailed'));
    exit;
  end;
  MessageFile := ExpandConstant('{tmp}\prerequisites.txt');
  Code := RunPrerequisites('CheckApple', MessageFile);
  if Code = 1 then begin
    if not WizardIsTaskSelected('appleusb') then begin
      Result := CustomMessage('AppleRequired');
      exit;
    end;
    AppleDownloadPage.Clear;
    AppleDownloadPage.Add('{#AppleInstallerUrl}', 'AppleUSBSetup.exe', '{#AppleInstallerSHA256}');
    AppleDownloadPage.Show;
    try
      try
        AppleDownloadPage.Download;
      except
        Result := GetExceptionMessage;
      end;
    finally
      AppleDownloadPage.Hide;
    end;
    if Result <> '' then exit;
  end else if Code <> 0 then begin
    Result := ReadMessage(MessageFile, CustomMessage('SetupFailed'));
    exit;
  end;
  Code := RunPrerequisites('CloseApp', MessageFile);
  if Code <> 0 then begin
    Result := ReadMessage(MessageFile, CustomMessage('SetupFailed'));
    exit;
  end;
  if RuntimeNeeded then begin
    WizardForm.StatusLabel.Caption := CustomMessage('RuntimeProgress');
    ExtractTemporaryFile('vc_redist.x64.exe');
    if not Exec(ExpandConstant('{tmp}\vc_redist.x64.exe'), '/install /quiet /norestart', '',
      SW_HIDE, ewWaitUntilTerminated, Code) then begin
      Result := 'Could not start the Microsoft Visual C++ installer.';
      exit;
    end;
    if Code = 3010 then RestartRequired := True
    else if (Code <> 0) and (Code <> 1638) then begin
      Result := 'Microsoft Visual C++ installation failed. Exit code: ' + IntToStr(Code);
      exit;
    end;
    if RuntimeNeeded then begin
      Result := 'The required Microsoft Visual C++ runtime is not ready. Restart Windows and retry setup.';
      NeedsRestart := RestartRequired;
      exit;
    end;
  end;
  WizardForm.StatusLabel.Caption := CustomMessage('PrerequisiteProgress');
  Code := RunPrerequisites('Prepare', MessageFile);
  if (Code <> 0) and (Code <> 3010) then begin
    Result := ReadMessage(MessageFile, CustomMessage('SetupFailed'));
    exit;
  end;
  RestartRequired := RestartRequired or (Code = 3010);
  { An empty state left by a failed attempt is not an existing installed app. }
  HadState := RegKeyExists(HKLM64,
    'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{B1638B2B-88F8-40A2-B7C0-B75F2EE9BA5F}_is1');
  WizardForm.StatusLabel.Caption := CustomMessage('DriverProgress');
  Code := RunDriver(ExpandConstant('{tmp}\driver-tools'), ExpandConstant('{tmp}\driver'), 'Install', StatePath);
  if (Code <> 0) and (Code <> 3010) then begin
    Result := ReadMessage(ExpandConstant('{commonappdata}\WinSideUSB\setup-result.txt'), CustomMessage('SetupFailed'));
    exit;
  end;
  RestartRequired := RestartRequired or (Code = 3010);
  DriverInstalled := True;
  WizardForm.CancelButton.Enabled := False;
end;

procedure CancelButtonClick(CurPageID: Integer; var Cancel, Confirm: Boolean);
begin
  if DriverInstalled and not Finished then Cancel := False;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Code: Integer;
begin
  if CurStep = ssPostInstall then begin
    Code := RunDriver(ExpandConstant('{app}\scripts'), ExpandConstant('{app}\driver'), 'Finalize', StatePath);
    if (Code <> 0) and (Code <> 3010) then
      RaiseException(CustomMessage('SetupFailed') + #13#10 +
        ReadMessage(ExpandConstant('{commonappdata}\WinSideUSB\setup-result.txt'), 'Display service setup failed.'));
    RestartRequired := RestartRequired or (Code = 3010);
    Finalized := True;
    WizardForm.FinishedLabel.Caption := CustomMessage('FinishedLabel');
  end;
  if CurStep = ssDone then begin
    Finished := True;
  end;
end;

function NeedRestart: Boolean;
begin
  Result := RestartRequired;
end;

function CanLaunch: Boolean;
begin
  Result := DriverInstalled and Finalized and not RestartRequired;
end;

procedure DeinitializeSetup;
var
  Code: Integer;
begin
  if DriverInstalled and not Finished and not HadState then begin
    Code := RunDriver(ExpandConstant('{tmp}\driver-tools'), ExpandConstant('{tmp}\driver'), 'Uninstall', StatePath);
    Log('Fresh-install driver rollback exit code: ' + IntToStr(Code));
    if (Code <> 0) and (Code <> 3010) then
      SuppressibleMsgBox(ReadMessage(ExpandConstant('{commonappdata}\WinSideUSB\setup-result.txt'),
        CustomMessage('SetupFailed')), mbError, MB_OK, IDOK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Code: Integer;
  MessageFile: String;
begin
  if CurUninstallStep <> usUninstall then exit;
  { This event occurs after the user confirms uninstall. }
  MessageFile := ExpandConstant('{tmp}\close-app-result.txt');
  if not Exec(ExpandConstant('{sysnative}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{app}\scripts\Setup-Prerequisites.ps1') +
    '" -Action CloseApp -AppPath "' + ExpandConstant('{app}\WinSideUSB.exe') +
    '" -ResultPath "' + MessageFile + '"', ExpandConstant('{app}\scripts'), SW_HIDE, ewWaitUntilTerminated, Code) then Code := -1;
  if Code <> 0 then begin
    SuppressibleMsgBox(ReadMessage(MessageFile, CustomMessage('DriverCleanupFailed')), mbError, MB_OK, IDOK);
    Abort;
  end;
  Code := RunDriver(ExpandConstant('{app}\scripts'), ExpandConstant('{app}\driver'), 'Uninstall', StatePath);
  { Keep the helper/ownership record available when removal needs a reboot/retry. }
  RestartRequired := Code = 3010;
  if Code <> 0 then begin
    SuppressibleMsgBox(CustomMessage('DriverCleanupFailed') + #13#10#13#10 +
      ReadMessage(ExpandConstant('{commonappdata}\WinSideUSB\setup-result.txt'), 'See %ProgramData%\WinSideUSB logs.'),
      mbError, MB_OK, IDOK);
    Abort;
  end;
end;

function UninstallNeedRestart: Boolean;
begin
  Result := RestartRequired;
end;
