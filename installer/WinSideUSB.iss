; Built by scripts/Build-Setup.ps1. All payloads are local at compile time.
#ifndef PayloadDir
  #error PayloadDir must be supplied by Build-Setup.ps1
#endif
#ifndef AppVersion
  #define AppVersion "0.3.7"
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
turkish.WelcomeLabel2=iPad'inizi Windows'un ikinci ekranına dönüştürün.%n%nKurulum uygulamayı, sanal ekran sürücüsünü ve gerekli Windows bileşenlerini hazırlar.%n%nApple Devices veya iTunes bilgisayarınızda kurulu olmalıdır. iPad uygulamasını ayrıca açmanız gerekir.
english.WelcomeLabel1=Welcome to WinSideUSB
english.WelcomeLabel2=Turn your iPad into a second Windows display.%n%nSetup installs the app, virtual display driver, and Windows runtime.%n%nApple Devices or iTunes must already be installed. Open the iPad app separately.
turkish.DevelopmentNotice=Bu bir geliştirme sürümüdür. Test imzalı sürücü için Windows test-signing açık ve Secure Boot kapalı olmalıdır. Kurulum bu ayarları değiştirmez.
english.DevelopmentNotice=This is a development preview. Its test-signed driver requires Windows test-signing on and Secure Boot off. Setup does not change these settings.
turkish.AppleButton=Apple USB desteğini edin
english.AppleButton=Get Apple USB support
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
Name: desktopicon; Description: "{cm:DesktopShortcut}"; Flags: unchecked

[Files]
; Put prerequisites first so early extraction remains quick with solid compression.
Source: "{#PayloadDir}\scripts\Setup-Driver.ps1"; DestDir: "{tmp}\driver-tools"; Flags: dontcopy
Source: "{#PayloadDir}\scripts\Setup-DriverSupport.psm1"; DestDir: "{tmp}\driver-tools"; Flags: dontcopy
Source: "{#PayloadDir}\scripts\Setup-Prerequisites.ps1"; DestDir: "{tmp}\driver-tools"; Flags: dontcopy
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
begin
  if not Exec(ExpandConstant('{sysnative}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{tmp}\driver-tools\Setup-Prerequisites.ps1') +
    '" -Action ' + Action + ' -AppPath "' + ExpandConstant('{app}\WinSideUSB.exe') +
    '" -ResultPath "' + ResultPath + '"', ExpandConstant('{tmp}\driver-tools'), SW_HIDE, ewWaitUntilTerminated, Result) then Result := -1;
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
  ShellExecAsOriginalUser('open', 'https://support.apple.com/118290', '', '', SW_SHOWNORMAL, ewNoWait, ErrorCode);
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
  Code := RunPrerequisites('Prepare', MessageFile);
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
