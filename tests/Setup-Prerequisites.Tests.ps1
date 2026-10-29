# Windows PowerShell 5.1 / Pester 3.4+. No real installers or services are changed.
Import-Module (Join-Path $PSScriptRoot '..\scripts\Setup-PrerequisitesSupport.psm1') -Force

InModuleScope Setup-PrerequisitesSupport {
    Describe 'Automatic Windows setup prerequisites' {
        BeforeEach {
            Mock Test-SetupMediaFoundation { $true }
            Mock Get-SetupAppleUsbState { [pscustomobject]@{ Ready = $true } }
            Mock Test-SetupAppleUsbInstaller {}
            Mock Invoke-SetupAppleUsbInstaller { 0 }
            Mock Start-SetupAppleUsbService {}
            Mock Get-SetupMediaCapability { [pscustomobject]@{ Name = 'Media.MediaFeaturePack~~~~0.0.1.0'; State = 'NotPresent' } }
            Mock Add-SetupMediaCapability {}
            $script:appleChecks = 0
            $script:mediaChecks = 0
        }

        It 'uses already installed components without downloads, installers or capability changes' {
            $state = Initialize-SetupPrerequisites -InstallMissingMedia -LogDirectory $TestDrive
            $state.RestartRequired | Should Be $false
            Assert-MockCalled Test-SetupAppleUsbInstaller -Scope It -Times 0
            Assert-MockCalled Invoke-SetupAppleUsbInstaller -Scope It -Times 0
            Assert-MockCalled Add-SetupMediaCapability -Scope It -Times 0
            Assert-MockCalled Start-SetupAppleUsbService -Scope It -Times 1
        }

        It 'verifies and installs missing Apple support then checks the installed service' {
            Mock Get-SetupAppleUsbState {
                $script:appleChecks++
                [pscustomobject]@{ Ready = ($script:appleChecks -gt 1) }
            }
            $state = Initialize-SetupPrerequisites -AppleInstallerPath 'X:\AppleUSBSetup.exe' -LogDirectory $TestDrive
            $state.RestartRequired | Should Be $false
            Assert-MockCalled Test-SetupAppleUsbInstaller -Scope It -Times 1
            Assert-MockCalled Invoke-SetupAppleUsbInstaller -Scope It -Times 1
            Assert-MockCalled Get-SetupAppleUsbState -Scope It -Times 2
            Assert-MockCalled Start-SetupAppleUsbService -Scope It -Times 1
        }

        It 'blocks a missing Apple prerequisite if the download was not selected' {
            Mock Get-SetupAppleUsbState { [pscustomobject]@{ Ready = $false } }
            { Initialize-SetupPrerequisites -LogDirectory $TestDrive } | Should Throw
            Assert-MockCalled Invoke-SetupAppleUsbInstaller -Scope It -Times 0
        }

        It 'never starts an installer that fails verification' {
            Mock Get-SetupAppleUsbState { [pscustomobject]@{ Ready = $false } }
            Mock Test-SetupAppleUsbInstaller { throw 'Untrusted file' }
            { Initialize-SetupPrerequisites -AppleInstallerPath 'X:\bad.exe' -LogDirectory $TestDrive } | Should Throw
            Assert-MockCalled Invoke-SetupAppleUsbInstaller -Scope It -Times 0
        }

        It 'does not report a failed Apple installer as a successful setup' {
            Mock Get-SetupAppleUsbState { [pscustomobject]@{ Ready = $false } }
            Mock Invoke-SetupAppleUsbInstaller { 1603 }
            { Initialize-SetupPrerequisites -AppleInstallerPath 'X:\AppleUSBSetup.exe' -LogDirectory $TestDrive } | Should Throw
            Assert-MockCalled Start-SetupAppleUsbService -Scope It -Times 0
        }

        It 'does not trust a zero installer exit code without working installed files' {
            Mock Get-SetupAppleUsbState { [pscustomobject]@{ Ready = $false } }
            { Initialize-SetupPrerequisites -AppleInstallerPath 'X:\AppleUSBSetup.exe' -LogDirectory $TestDrive } | Should Throw
            Assert-MockCalled Start-SetupAppleUsbService -Scope It -Times 0
        }

        It 'does not trust already-installed exit code 1638 when USB support is still absent' {
            Mock Get-SetupAppleUsbState { [pscustomobject]@{ Ready = $false } }
            Mock Invoke-SetupAppleUsbInstaller { 1638 }
            { Initialize-SetupPrerequisites -AppleInstallerPath 'X:\AppleUSBSetup.exe' -LogDirectory $TestDrive } | Should Throw
        }

        It 'preserves an explicit Apple restart requirement without launching the service prematurely' {
            Mock Get-SetupAppleUsbState { [pscustomobject]@{ Ready = $false } }
            Mock Invoke-SetupAppleUsbInstaller { 3010 }
            $state = Initialize-SetupPrerequisites -AppleInstallerPath 'X:\AppleUSBSetup.exe' -LogDirectory $TestDrive
            $state.RestartRequired | Should Be $true
            Assert-MockCalled Start-SetupAppleUsbService -Scope It -Times 0
        }

        It 'fails when the installed Apple service cannot start without a pending restart' {
            Mock Start-SetupAppleUsbService { throw 'Service failed' }
            { Initialize-SetupPrerequisites -LogDirectory $TestDrive } | Should Throw
        }

        It 'installs Windows N media capability and requests a restart' {
            Mock Test-SetupMediaFoundation { $false }
            Mock Get-SetupMediaCapability {
                $script:mediaChecks++
                [pscustomobject]@{ Name = 'Media.MediaFeaturePack~~~~0.0.1.0'; State = $(if ($script:mediaChecks -eq 1) { 'NotPresent' } else { 'Installed' }) }
            }
            $state = Initialize-SetupPrerequisites -InstallMissingMedia -LogDirectory $TestDrive
            $state.RestartRequired | Should Be $true
            Assert-MockCalled Add-SetupMediaCapability -Scope It -Times 1
        }

        It 'requests a restart for already-staged media without reinstalling it' {
            Mock Test-SetupMediaFoundation { $false }
            Mock Get-SetupMediaCapability { [pscustomobject]@{ Name = 'Media.MediaFeaturePack~~~~0.0.1.0'; State = 'InstallPending' } }
            $state = Initialize-SetupPrerequisites -InstallMissingMedia -LogDirectory $TestDrive
            $state.RestartRequired | Should Be $true
            Assert-MockCalled Add-SetupMediaCapability -Scope It -Times 0
        }

        It 'does not change Windows capabilities when automatic media preparation is disabled' {
            Mock Test-SetupMediaFoundation { $false }
            { Initialize-SetupPrerequisites -LogDirectory $TestDrive } | Should Throw
            Assert-MockCalled Get-SetupMediaCapability -Scope It -Times 0
            Assert-MockCalled Add-SetupMediaCapability -Scope It -Times 0
        }

        It 'rejects missing media on an edition without the Media Feature Pack' {
            Mock Test-SetupMediaFoundation { $false }
            Mock Get-SetupMediaCapability { $null }
            { Initialize-SetupPrerequisites -InstallMissingMedia -LogDirectory $TestDrive } | Should Throw
            Assert-MockCalled Add-SetupMediaCapability -Scope It -Times 0
        }

        It 'rechecks the actual capability state after Windows Update returns' {
            Mock Test-SetupMediaFoundation { $false }
            { Initialize-SetupPrerequisites -InstallMissingMedia -LogDirectory $TestDrive } | Should Throw
            Assert-MockCalled Add-SetupMediaCapability -Scope It -Times 1
            Assert-MockCalled Invoke-SetupAppleUsbInstaller -Scope It -Times 0
        }
    }

    Describe 'Apple download verification' {
        BeforeEach {
            $script:downloadPath = Join-Path $TestDrive 'AppleUSBSetup.exe'
            Set-Content -LiteralPath $script:downloadPath -Value 'fixture, never executed'
            Mock Get-SetupAppleUsbDefinition { [pscustomobject]@{ SHA256 = ('A' * 64) } }
            Mock Get-FileHash { [pscustomobject]@{ Hash = ('A' * 64) } }
            Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Apple Inc., O=Apple Inc., C=US' } } }
        }

        It 'accepts only the pinned bytes with a trusted Apple publisher signature' {
            { Test-SetupAppleUsbInstaller -Path $script:downloadPath } | Should Not Throw
            Assert-MockCalled Get-AuthenticodeSignature -Scope It -Times 1
        }

        It 'rejects changed bytes before consulting the signature' {
            Mock Get-FileHash { [pscustomobject]@{ Hash = ('B' * 64) } }
            { Test-SetupAppleUsbInstaller -Path $script:downloadPath } | Should Throw
            Assert-MockCalled Get-AuthenticodeSignature -Scope It -Times 0
        }

        It 'rejects a signature that Windows does not trust' {
            Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'UnknownError'; SignerCertificate = [pscustomobject]@{ Subject = 'O=Apple Inc.' } } }
            { Test-SetupAppleUsbInstaller -Path $script:downloadPath } | Should Throw
        }

        It 'rejects a valid signature belonging to a different publisher' {
            Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Other, O=Other Publisher, C=US' } } }
            { Test-SetupAppleUsbInstaller -Path $script:downloadPath } | Should Throw
        }

        It 'rejects a missing download' {
            { Test-SetupAppleUsbInstaller -Path (Join-Path $TestDrive 'absent.exe') } | Should Throw
        }
    }

    Describe 'Apple installer invocation' {
        It 'runs hidden, waits and explicitly forbids an automatic reboot' {
            Mock Start-Process { [pscustomobject]@{ ExitCode = 3010 } }
            Invoke-SetupAppleUsbInstaller -Path 'X:\AppleUSBSetup.exe' -LogPath 'X:\logs with spaces\AppleUSB-install.log' | Should Be 3010
            Assert-MockCalled Start-Process -Scope It -Times 1 -ParameterFilter {
                $WindowStyle -eq 'Hidden' -and $Wait -and $PassThru -and
                ($ArgumentList -contains '/quiet') -and ($ArgumentList -contains '/norestart') -and
                ($ArgumentList -contains '"X:\logs with spaces\AppleUSB-install.log"')
            }
        }
    }
}
