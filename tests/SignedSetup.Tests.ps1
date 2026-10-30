# Windows PowerShell 5.1 / Pester. All machine mutations are mocked.
Import-Module (Join-Path $PSScriptRoot '..\scripts\Setup-DriverSupport.psm1') -Force

InModuleScope Setup-DriverSupport {
    Describe 'Signed display setup transaction' {
        BeforeEach {
            $script:statePath = Join-Path $TestDrive 'signed-state.json'
            if (Test-Path $script:statePath) { Remove-Item -LiteralPath $script:statePath }
            $script:servicePayload = Join-Path $TestDrive 'service.exe'
            Set-Content -LiteralPath $script:servicePayload -Value 'fake service'
            $script:deviceId = 'ROOT\MTTVDD\0000'
            $script:devices = @(); $script:enabled = $false; $script:published = ''
            $script:bindFails = $false; $script:disableFails = $false; $script:bindReboot = $false
            $script:removeReboot = $false; $script:bootId = 'BOOT-1'; $script:LogPath = ''
            $script:publisherTrusted = $false
            Mock Assert-SetupAdministrator {}
            Mock Protect-SetupStateFolder {}
            Mock Assert-SetupInstallLocation {}
            Mock Get-SetupBootId { $script:bootId }
            Mock Get-SetupInstalledStatePath { Join-Path $TestDrive 'absent-state.json' }
            Mock Get-SetupService { $null }
            Mock Get-SetupMttDevices { $script:devices }
            Mock Test-SetupPackage { [pscustomobject]@{ InfPath = 'X:\payload\MttVDD.inf'; Certificate = $null } }
            Mock Install-SetupSignedConfiguration {
                $State.SignedConfig = [pscustomobject]@{ Registry = @(); RegistryKeys = @() }
                $State.Service = [pscustomobject]@{ Name = 'WinSideUSBDisplayService'; BinaryPath = 'C:\Program Files\WinSideUSB\WinSideUSBDisplayService.exe'; ExpectedHash = ('C' * 64); Owned = $false; Registered = $false }
            }
            Mock Set-SetupOwnedRegistryValue {}
            Mock Stop-SetupOwnedService {}
            Mock Remove-SetupSignedService { $State.Service = $null; $false }
            Mock Remove-SetupSignedConfiguration { $State.SignedConfig = $null }
            Mock Get-SetupPublishedInf { $script:published }
            Mock Get-SetupInfHash { 'A' * 64 }
            Mock Test-SetupInfExists { $true }
            Mock Invoke-SetupPnpUtil {
                if ($Arguments[0] -eq '/add-driver') { $script:published = 'oem72.inf' }
                $false
            }
            Mock New-SetupDevice { $script:devices = @([pscustomobject]@{ InstanceId = $script:deviceId }); $script:deviceId }
            Mock Get-SetupDevices {
                if ($script:devices.Count) {
                    [pscustomobject]@{ InstanceId = $script:deviceId; PublishedInf = $script:published; ProblemCode = $(if ($script:enabled) { 0 } else { 22 }); Status = $(if ($script:enabled) { 8 } else { 0 }) }
                }
            }
            Mock Connect-SetupDriver {
                if ($script:bindFails) { throw 'Binding failed.' }
                $script:enabled = $true; $script:bindReboot
            }
            Mock Disable-SetupDevice {
                if ($script:disableFails) { throw 'Disabling failed.' }
                $script:enabled = $false; $false
            }
            Mock Remove-SetupDevice { $script:devices = @(); $script:removeReboot }
            Mock Add-SetupCertificate { throw 'Signed setup must never import a certificate.' }
            Mock Remove-SetupCertificate { throw 'Signed setup has no imported certificate.' }
            Mock Test-SetupCertificatePresent { $Store -eq 'TrustedPublisher' -and $script:publisherTrusted }
            Mock Test-SetupCertificateInUse { $false }
            Mock Start-Sleep {}
        }
        It 'checks the signed package without creating a device or changing trust' {
            $result = Invoke-SetupDriverAction Check 'X:\payload' $script:statePath Signed '' 'C:\Program Files\WinSideUSB' $script:servicePayload
            $result.ExitCode | Should Be 0
            Assert-MockCalled New-SetupDevice -Times 0 -Exactly -Scope It
            Assert-MockCalled Invoke-SetupPnpUtil -Times 0 -Exactly -Scope It
            Assert-MockCalled Add-SetupCertificate -Times 0 -Exactly -Scope It
            (Test-Path $script:statePath) | Should Be $false
        }
        It 'rejects another vendor installation before staging anything' {
            $script:devices = @([pscustomobject]@{ InstanceId = 'ROOT\MTTVDD\OTHER' })
            { Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Signed '' 'C:\Program Files\WinSideUSB' $script:servicePayload } | Should Throw 'Another Virtual Display Driver'
            Assert-MockCalled Invoke-SetupPnpUtil -Times 0 -Exactly -Scope It
            Assert-MockCalled Install-SetupSignedConfiguration -Times 0 -Exactly -Scope It
        }
        It 'leaves exactly one owned node disabled after binding and imports no certificate' {
            $result = Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Signed '' 'C:\Program Files\WinSideUSB' $script:servicePayload
            $result.ExitCode | Should Be 0
            $state = Read-SetupState $script:statePath
            $state.DriverMode | Should Be Signed
            $state.DeviceIds.Count | Should Be 1
            $state.DeviceIds[0] | Should Be $script:deviceId
            $state.Certificates.Count | Should Be 0
            $script:enabled | Should Be $false
            Assert-MockCalled Disable-SetupDevice -Times 1 -Exactly -Scope It
            Assert-MockCalled Set-SetupOwnedRegistryValue -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'ManagedDeviceInstanceId' -and $Value -eq $script:deviceId }
        }
        It 'reuses only its recorded node during an upgrade' {
            $null = Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Signed
            $null = Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Signed
            (Read-SetupState $script:statePath).DeviceIds.Count | Should Be 1
            Assert-MockCalled New-SetupDevice -Times 1 -Exactly -Scope It
            Assert-MockCalled Disable-SetupDevice -Times 2 -Exactly -Scope It
        }
        It 'adds only the reviewed publisher leaf after explicit selection and records ownership' {
            Mock Test-SetupPackage { [pscustomobject]@{ InfPath='X:\payload\MttVDD.inf'; Certificate=[pscustomobject]@{Thumbprint='3CF8CF26D8BA266C3A483AB7D26D4A818E317D76'} } }
            Mock Add-SetupCertificate { $script:publisherTrusted=$true }
            $null=Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Signed -TrustDriverPublisher -NonInteractive
            $state=Read-SetupState $script:statePath
            $state.Certificates.Count | Should Be 1
            $state.Certificates[0].Store | Should Be 'TrustedPublisher'
            Assert-MockCalled Add-SetupCertificate -Scope It -Times 1 -Exactly -ParameterFilter {$Store -eq 'TrustedPublisher'}
            Assert-MockCalled Add-SetupCertificate -Scope It -Times 0 -Exactly -ParameterFilter {$Store -eq 'Root'}
            $null=Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Signed -TrustDriverPublisher -NonInteractive
            (Read-SetupState $script:statePath).Certificates.Count | Should Be 1
            Assert-MockCalled Add-SetupCertificate -Scope It -Times 1 -Exactly
        }
        It 'preserves pre-existing publisher trust rather than claiming ownership' {
            Mock Test-SetupPackage { [pscustomobject]@{ InfPath='X:\payload\MttVDD.inf'; Certificate=[pscustomobject]@{Thumbprint='3CF8CF26D8BA266C3A483AB7D26D4A818E317D76'} } }
            $script:publisherTrusted=$true
            $null=Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Signed -TrustDriverPublisher -NonInteractive
            (Read-SetupState $script:statePath).Certificates.Count | Should Be 0
            $null=Invoke-SetupDriverAction Uninstall '' $script:statePath
            Assert-MockCalled Add-SetupCertificate -Scope It -Times 0 -Exactly
            Assert-MockCalled Remove-SetupCertificate -Scope It -Times 0 -Exactly
        }
        It 'rejects a different signing certificate before adding trust or creating devices' {
            Mock Test-SetupPackage { [pscustomobject]@{ InfPath='X:\payload\MttVDD.inf'; Certificate=[pscustomobject]@{Thumbprint=('A'*40)} } }
            {Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Signed -TrustDriverPublisher} | Should Throw 'exact reviewed'
            Assert-MockCalled Add-SetupCertificate -Scope It -Times 0 -Exactly
            Assert-MockCalled New-SetupDevice -Scope It -Times 0 -Exactly
        }
        It 'fails a silent unapproved publisher at the read-only check instead of waiting for Windows UI' {
            Mock Test-SetupPackage { [pscustomobject]@{ InfPath='X:\payload\MttVDD.inf'; Certificate=[pscustomobject]@{Thumbprint='3CF8CF26D8BA266C3A483AB7D26D4A818E317D76'} } }
            {Invoke-SetupDriverAction Check 'X:\payload' $script:statePath Signed '' 'C:\Program Files\WinSideUSB' $script:servicePayload -NonInteractive} | Should Throw 'publisher has not been approved'
            Assert-MockCalled Add-SetupCertificate -Scope It -Times 0 -Exactly
            Assert-MockCalled Invoke-SetupPnpUtil -Scope It -Times 0 -Exactly
            (Test-Path $script:statePath) | Should Be $false
        }
        It 'removes only publisher trust introduced by this setup after its driver is removed' {
            Mock Test-SetupPackage { [pscustomobject]@{ InfPath='X:\payload\MttVDD.inf'; Certificate=[pscustomobject]@{Thumbprint='3CF8CF26D8BA266C3A483AB7D26D4A818E317D76'} } }
            Mock Add-SetupCertificate { $script:publisherTrusted=$true }
            Mock Remove-SetupCertificate { $script:publisherTrusted=$false }
            $null=Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Signed -TrustDriverPublisher
            $null=Invoke-SetupDriverAction Uninstall '' $script:statePath
            (Read-SetupState $script:statePath).Certificates.Count | Should Be 0
            $script:publisherTrusted | Should Be $false
            Assert-MockCalled Remove-SetupCertificate -Scope It -Times 1 -Exactly -ParameterFilter {$Store -eq 'TrustedPublisher'}
        }
        It 'rolls back its newly selected publisher trust when first installation fails' {
            Mock Test-SetupPackage { [pscustomobject]@{ InfPath='X:\payload\MttVDD.inf'; Certificate=[pscustomobject]@{Thumbprint='3CF8CF26D8BA266C3A483AB7D26D4A818E317D76'} } }
            Mock Add-SetupCertificate { $script:publisherTrusted=$true }
            Mock Remove-SetupCertificate { $script:publisherTrusted=$false }
            $script:bindFails=$true
            {Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Signed -TrustDriverPublisher} | Should Throw 'Binding failed'
            $script:publisherTrusted | Should Be $false
            Assert-MockCalled Remove-SetupCertificate -Scope It -Times 1 -Exactly
        }
        It 'rolls back the new node and configuration if binding fails' {
            $script:bindFails = $true
            { Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Signed } | Should Throw 'Binding failed'
            (Read-SetupState $script:statePath).DeviceIds.Count | Should Be 0
            Assert-MockCalled Remove-SetupSignedConfiguration -Times 1 -Exactly -Scope It
            Assert-MockCalled Remove-SetupDevice -Times 1 -Exactly -Scope It
        }
        It 'does not report success if the node cannot be disabled' {
            $script:disableFails = $true
            { Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Signed } | Should Throw 'Disabling failed'
            (Read-SetupState $script:statePath).Installed | Should Be $false
        }
        It 'reports a real pending restart and retains ownership' {
            $script:bindReboot = $true
            (Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Signed).ExitCode | Should Be 3010
            (Read-SetupState $script:statePath).PendingRestart | Should Be $true
        }
        It 'removes the service before its device and restores owned configuration' {
            $null = Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Signed
            (Invoke-SetupDriverAction Uninstall '' $script:statePath).ExitCode | Should Be 0
            $state = Read-SetupState $script:statePath
            $state.Service | Should BeNullOrEmpty
            $state.SignedConfig | Should BeNullOrEmpty
            $state.Installed | Should Be $false
            Assert-MockCalled Remove-SetupSignedService -Times 1 -Exactly -Scope It
            Assert-MockCalled Remove-SetupSignedConfiguration -Times 1 -Exactly -Scope It
        }
        It 'keeps configuration and helpers when removal needs a restart' {
            $null = Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Signed
            $script:removeReboot = $true
            (Invoke-SetupDriverAction Uninstall '' $script:statePath).ExitCode | Should Be 3010
            (Read-SetupState $script:statePath).SignedConfig | Should Not BeNullOrEmpty
            Assert-MockCalled Remove-SetupSignedConfiguration -Times 0 -Exactly -Scope It
        }
        It 'refuses a foreign service without stopping it' {
            Mock Get-SetupService { [pscustomobject]@{ PathName = '"C:\Other\service.exe"' } }
            { Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Signed } | Should Throw 'same name belongs to another'
            Assert-MockCalled Stop-SetupOwnedService -Times 0 -Exactly -Scope It
        }
        It 'cleans only recorded development resources before switching to signed' {
            $state = New-SetupState
            $state.DriverMode = 'Development'; $state.Installed = $true
            $state.DeviceIds = @('ROOT\WINSIDEUSBVIRTUALDISPLAY\0000')
            Save-SetupState $state $script:statePath
            $null = Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Signed
            (Read-SetupState $script:statePath).DeviceIds[0] | Should Be $script:deviceId
            Assert-MockCalled Remove-SetupDevice -Times 1 -Exactly -Scope It -ParameterFilter { $InstanceId -eq 'ROOT\WINSIDEUSBVIRTUALDISPLAY\0000' }
        }
    }

    Describe 'Display configuration and restricted UMDF read access' {
        It 'includes all native iPad resolutions and both existing refresh choices' {
            $source = Join-Path (Split-Path (Get-Module Setup-DriverSupport).Path -Parent) '..\WinSideUSB\WinSideUSB.cpp'
            $xmlPath = Join-Path $TestDrive 'vdd_settings.xml'
            $count = New-SetupDisplayConfiguration $source $xmlPath
            $xml = New-Object Xml.XmlDocument; $xml.Load($xmlPath)
            $xml.vdd_settings.monitors.count | Should Be '1'
            $count | Should BeGreaterThan 10
            $modes = @($xml.vdd_settings.resolutions.resolution | ForEach-Object { "$($_.width),$($_.height)" })
            $table = [regex]::Match((Get-Content $source -Raw), '(?s)static const iPadDef g_ipadDefs\[\] = \{(.*?)\r?\n\};')
            foreach ($row in [regex]::Matches($table.Groups[1].Value, '(?m)^\s*\{\s*"iPad[^"]+",.*?,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}')) {
                ($modes -contains "$($row.Groups[1].Value),$($row.Groups[2].Value)") | Should Be $true
            }
            @($xml.vdd_settings.global.g_refresh_rate) -join ',' | Should Be '60,120'
        }
        It 'grants LocalService and its restricted driver SID read access and only admins write access' {
            foreach ($acl in @((New-SetupDirectoryAcl), (New-SetupRegistryAcl))) {
                $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
                foreach ($sid in @('S-1-5-19', 'S-1-5-84-0-0-0-0-0')) {
                    @($rules | Where-Object { $_.IdentityReference.Value -eq $sid }).Count | Should Be 1
                }
                foreach ($rule in $rules | Where-Object { $_.IdentityReference.Value -notin @('S-1-5-18', 'S-1-5-32-544') }) {
                    if ($rule -is [Security.AccessControl.FileSystemAccessRule]) {
                        ([int]$rule.FileSystemRights -band [int][Security.AccessControl.FileSystemRights]'WriteData,AppendData,Delete,ChangePermissions,TakeOwnership') | Should Be 0
                    } else {
                        ([int]$rule.RegistryRights -band [int][Security.AccessControl.RegistryRights]'SetValue,CreateSubKey,Delete,ChangePermissions,TakeOwnership') | Should Be 0
                    }
                }
            }
        }
    }

    Describe 'Owned registry permission restoration' {
        BeforeEach {
            $script:LogPath = ''
            $script:originalAcl = New-Object Security.AccessControl.RegistrySecurity
            $script:originalAcl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;KA;;;SY)(A;;KA;;;BA)(A;;KR;;;BU)')
            $script:currentAcl = New-SetupRegistryAcl
            $script:currentAcl.SetGroup($script:originalAcl.GetGroup([Security.Principal.SecurityIdentifier]))
            $script:configState = New-SetupState
            $script:keyPath = 'HKLM:\SOFTWARE\WinSideUSB'
            $script:configState.SignedConfig = [pscustomobject]@{
                Registry = @(); XmlPath = 'X:\absent.xml'; Directory = 'X:\absent'
                RegistryKeys = @([pscustomobject]@{ KeyPath = $script:keyPath; Existed = $true; PreviousSddl = $script:originalAcl.GetSecurityDescriptorSddlForm('All'); InstalledSddl = $script:currentAcl.GetSecurityDescriptorSddlForm('All') })
            }
            Mock Test-Path { $LiteralPath -eq $script:keyPath }
            Mock Get-SetupRegistryAcl { $script:currentAcl }
            Mock Set-Acl {}
            Mock Save-SetupState {}
        }
        It 'restores the exact former permissions when its installed ACL is unchanged' {
            Remove-SetupSignedConfiguration $script:configState 'X:\state.json'
            Assert-MockCalled Set-Acl -Times 1 -Exactly -Scope It -ParameterFilter { $AclObject.GetSecurityDescriptorSddlForm('All') -eq $script:originalAcl.GetSecurityDescriptorSddlForm('All') }
            $script:configState.SignedConfig | Should BeNullOrEmpty
        }
        It 'preserves permissions changed by another administrator after setup' {
            $script:currentAcl = $script:originalAcl
            Remove-SetupSignedConfiguration $script:configState 'X:\state.json'
            Assert-MockCalled Set-Acl -Times 0 -Exactly -Scope It
        }
    }

    Describe 'Owned display service completion' {
        BeforeEach {
            $script:LogPath = ''; $script:serviceCommands = @(); $script:serviceExists = $false
            $script:finalState = New-SetupState
            $script:finalState.Installed = $true; $script:finalState.DeviceIds = @('ROOT\MTTVDD\0000')
            $script:finalState.Service = [pscustomobject]@{ BinaryPath = 'C:\Program Files\WinSideUSB\WinSideUSBDisplayService.exe'; ExpectedHash = 'C' * 64; Owned = $false; Registered = $false }
            Mock Assert-SetupExclusiveMttState {}
            Mock Assert-SetupInstallLocation {}
            Mock Assert-SetupTrustedStateItem {}
            Mock Save-SetupState {}
            Mock Get-FileHash { [pscustomobject]@{ Hash = 'C' * 64 } }
            Mock Get-SetupService { if ($script:serviceExists) { [pscustomobject]@{ PathName = '"' + $script:finalState.Service.BinaryPath + '"' } } }
            Mock New-Service { $script:serviceExists = $true }
            Mock Set-Service {}
            Mock Start-Service {}
            Mock Get-Service {
                $controller = [pscustomobject]@{ Status = 'Running' }
                $controller | Add-Member ScriptMethod WaitForStatus {}
                $controller
            }
            Mock Invoke-SetupServiceCommand { $script:serviceCommands += ($Arguments -join ' '); $false }
            Mock Get-SetupDevices { [pscustomobject]@{ InstanceId = 'ROOT\MTTVDD\0000'; ProblemCode = 22; Status = 0 } }
        }
        It 'registers automatic service and crash recovery, then verifies the display is disabled' {
            (Complete-SetupSignedService $script:finalState 'X:\state.json').ExitCode | Should Be 0
            $script:finalState.Service.Owned | Should Be $true
            $script:serviceCommands.Count | Should Be 2
            $script:serviceCommands[0] | Should Match 'restart/1000'
            $script:serviceCommands[1] | Should Match 'failureflag.*1'
            Assert-MockCalled Assert-SetupTrustedStateItem -Times 3 -Exactly -Scope It -ParameterFilter { $AllowTrustedInstaller }
            Assert-MockCalled Start-Service -Times 1 -Exactly -Scope It
        }
        It 'defers service startup until a requested restart' {
            $script:finalState.PendingRestart = $true
            (Complete-SetupSignedService $script:finalState 'X:\state.json').ExitCode | Should Be 3010
            Assert-MockCalled Start-Service -Times 0 -Exactly -Scope It
        }
        It 'rejects a replaced service binary before registration' {
            Mock Get-FileHash { [pscustomobject]@{ Hash = 'D' * 64 } }
            { Complete-SetupSignedService $script:finalState 'X:\state.json' } | Should Throw 'does not match'
            Assert-MockCalled New-Service -Times 0 -Exactly -Scope It
        }
        It 'rejects a service that leaves an active desktop while idle' {
            Mock Get-SetupDevices { [pscustomobject]@{ InstanceId = 'ROOT\MTTVDD\0000'; ProblemCode = 0; Status = 8 } }
            { Complete-SetupSignedService $script:finalState 'X:\state.json' } | Should Throw 'disabled'
        }
    }
}
