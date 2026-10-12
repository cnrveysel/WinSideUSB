# Run with Windows PowerShell 5.1: Invoke-Pester .\tests\Setup-Driver.Tests.ps1
# All device, Driver Store, elevation, and certificate operations are mocked.
Import-Module (Join-Path $PSScriptRoot '..\scripts\Setup-DriverSupport.psm1') -Force

InModuleScope Setup-DriverSupport {
    Describe 'WinSideUSB installer driver ownership and failures' {
        BeforeEach {
            $script:statePath = Join-Path $TestDrive 'setup-state.json'
            if (Test-Path -LiteralPath $script:statePath) { Remove-Item -LiteralPath $script:statePath -Force }
            $script:infHash = 'A' * 64
            $script:thumbprint = 'B' * 40
            $script:deviceId = 'ROOT\WINSIDEUSBVIRTUALDISPLAY\0000'
            $script:published = ''
            $script:devices = @()
            $script:bound = $false
            $script:bindingFails = $false
            $script:deleteFails = $false
            $script:bindReboot = $false
            $script:removeReboot = $false
            $script:bootId = 'BOOT-1'
            $script:trusted = @{}
            $script:removedIds = @()
            $script:deletedPackages = @()
            $script:removedCertificates = @()
            $script:LogPath = ''
            Mock Assert-SetupAdministrator {}
            Mock Protect-SetupStateFolder {}
            Mock Get-SetupBootId { return $script:bootId }
            Mock Test-SetupCertificateInUse { return $false }
            Mock Test-SetupPackage {
                [pscustomobject]@{ InfPath = 'X:\payload\IddSampleDriver.inf'; Certificate = [pscustomobject]@{ Thumbprint = $script:thumbprint } }
            }
            Mock Get-SetupPublishedInf { return $script:published }
            Mock Get-SetupInfHash { return $script:infHash }
            Mock Test-SetupInfExists { return $true }
            Mock Invoke-SetupPnpUtil {
                if ($Arguments[0] -eq '/add-driver') { $script:published = 'oem72.inf' }
                else {
                    if ($script:deleteFails) { throw 'Driver is in use by another device.' }
                    $script:deletedPackages += $Arguments[1]
                }
                return $false
            }
            Mock Get-SetupDevices {
                if ($script:bound) {
                    return @([pscustomobject]@{ InstanceId = $script:deviceId; PublishedInf = 'oem72.inf'; ProblemCode = 0; Status = 8 })
                }
                return $script:devices
            }
            Mock New-SetupDevice { $script:devices = @([pscustomobject]@{ InstanceId = $script:deviceId }); return $script:deviceId }
            Mock Connect-SetupDriver {
                if ($script:bindingFails) { throw 'Windows refused the driver binding.' }
                $script:bound = $true; return $script:bindReboot
            }
            Mock Remove-SetupDevice { $script:removedIds += $InstanceId; return $script:removeReboot }
            Mock Test-SetupCertificatePresent { return $script:trusted.ContainsKey($Store) }
            Mock Add-SetupCertificate { $script:trusted[$Store] = $Certificate.Thumbprint }
            Mock Remove-SetupCertificate { $script:removedCertificates += "${Store}:$Thumbprint" }
        }

        It 'Check only validates and never changes certificates, devices, or Driver Store' {
            $result = Invoke-SetupDriverAction Check 'X:\payload' $script:statePath Development 'X:\cert.cer'
            $result.ExitCode | Should Be 0
            Assert-MockCalled Invoke-SetupPnpUtil -Times 0 -Exactly -Scope It
            Assert-MockCalled New-SetupDevice -Times 0 -Exactly -Scope It
            Assert-MockCalled Add-SetupCertificate -Times 0 -Exactly -Scope It
            Test-Path $script:statePath | Should Be $false
        }

        It 'records exact newly created device, published INF, and newly imported certificate stores' {
            $result = Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Development 'X:\cert.cer'
            $result.ExitCode | Should Be 0
            $state = Read-SetupState $script:statePath
            $state.DeviceIds.Count | Should Be 1
            $state.DeviceIds[0] | Should Be $script:deviceId
            $state.Packages[0].PublishedInf | Should Be 'oem72.inf'
            $state.Certificates.Count | Should Be 2
            $state.Installed | Should Be $true
        }

        It 'repeated installation reuses devices and does not duplicate ownership or certificate imports' {
            $null = Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Development 'X:\cert.cer'
            $null = Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Development 'X:\cert.cer'
            $state = Read-SetupState $script:statePath
            $state.DeviceIds.Count | Should Be 1
            $state.Packages.Count | Should Be 1
            $state.Certificates.Count | Should Be 2
            Assert-MockCalled New-SetupDevice -Times 1 -Exactly -Scope It
            Assert-MockCalled Add-SetupCertificate -Times 2 -Exactly -Scope It
        }

        It 'preserves an existing matching device, existing driver package, and pre-existing trust on uninstall' {
            $script:published = 'oem72.inf'
            $script:devices = @([pscustomobject]@{ InstanceId = $script:deviceId })
            $script:trusted['Root'] = $script:thumbprint
            $script:trusted['TrustedPublisher'] = $script:thumbprint
            $null = Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Development 'X:\cert.cer'
            $null = Invoke-SetupDriverAction Uninstall '' $script:statePath
            $script:removedIds.Count | Should Be 0
            $script:deletedPackages.Count | Should Be 0
            $script:removedCertificates.Count | Should Be 0
            Assert-MockCalled New-SetupDevice -Times 0 -Exactly -Scope It
        }

        It 'rolls back only resources created during a failed first install' {
            $script:trusted['Root'] = $script:thumbprint
            $script:bindingFails = $true
            { Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Development 'X:\cert.cer' } | Should Throw 'Windows refused'
            $script:removedIds[0] | Should Be $script:deviceId
            $script:deletedPackages[0] | Should Be 'oem72.inf'
            $script:removedCertificates.Count | Should Be 1
            $script:removedCertificates[0] | Should Be "TrustedPublisher:$($script:thumbprint)"
            $state = Read-SetupState $script:statePath
            $state.DeviceIds.Count | Should Be 0
            $state.Packages.Count | Should Be 0
            $state.Certificates.Count | Should Be 0
            $state.Installed | Should Be $false
        }

        It 'keeps the ownership record and certificate trust when package deletion fails' {
            $null = Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Development 'X:\cert.cer'
            $script:deleteFails = $true
            { Invoke-SetupDriverAction Uninstall '' $script:statePath } | Should Throw 'ownership record was kept'
            $state = Read-SetupState $script:statePath
            $state.DeviceIds.Count | Should Be 0
            $state.Packages.Count | Should Be 1
            $state.Certificates.Count | Should Be 2
            Assert-MockCalled Remove-SetupCertificate -Times 0 -Exactly -Scope It
        }

        It 'preserves an OEM name whose INF hash changed rather than deleting an unrelated package' {
            $null = Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Release
            $script:infHash = 'C' * 64
            { Invoke-SetupDriverAction Uninstall '' $script:statePath } | Should Throw 'contents have changed'
            $script:deletedPackages.Count | Should Be 0
            (Read-SetupState $script:statePath).Packages.Count | Should Be 1
        }

        It 'returns 3010 only when Windows reports a genuine restart requirement' {
            $script:bindReboot = $true
            $result = Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Release
            $result.ExitCode | Should Be 3010
            (Read-SetupState $script:statePath).PendingRestart | Should Be $true
        }

        It 'preserves imported trust during pending reboot removal and cleans it on the next uninstall' {
            $null = Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Development 'X:\cert.cer'
            $script:removeReboot = $true
            $result = Invoke-SetupDriverAction Uninstall '' $script:statePath
            $result.ExitCode | Should Be 3010
            (Read-SetupState $script:statePath).Certificates.Count | Should Be 2
            (Read-SetupState $script:statePath).DeviceIds.Count | Should Be 1
            $script:removeReboot = $false
            $result = Invoke-SetupDriverAction Uninstall '' $script:statePath
            $result.ExitCode | Should Be 3010
            (Read-SetupState $script:statePath).Certificates.Count | Should Be 2
            $script:bootId = 'BOOT-2'
            $result = Invoke-SetupDriverAction Uninstall '' $script:statePath
            $result.ExitCode | Should Be 0
            (Read-SetupState $script:statePath).Certificates.Count | Should Be 0
        }

        It 'does not report a stopped device with problem code zero as a working driver' {
            Mock Get-SetupDevices { return @([pscustomobject]@{ InstanceId = $script:deviceId; PublishedInf = 'oem72.inf'; ProblemCode = 0; Status = 0 }) }
            Mock Start-Sleep {}
            { Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Release } | Should Throw 'working WinSideUSB driver'
            (Read-SetupState $script:statePath).Installed | Should Be $false
        }

        It 'preserves certificate trust adopted by another driver and records why it was retained' {
            $null = Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Development 'X:\cert.cer'
            Mock Test-SetupCertificateInUse { return $true }
            $result = Invoke-SetupDriverAction Uninstall '' $script:statePath
            $result.ExitCode | Should Be 0
            $result.Message | Should Match 'other driver packages'
            $state = Read-SetupState $script:statePath
            $state.SharedCertificates.Count | Should Be 2
            $state.Certificates.Count | Should Be 0
            Assert-MockCalled Remove-SetupCertificate -Times 0 -Exactly -Scope It
        }

        It 'blocks install while an earlier device removal is pending instead of falsely reporting an installed driver' {
            $null = Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Release
            $script:removeReboot = $true
            $null = Invoke-SetupDriverAction Uninstall '' $script:statePath
            { Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Release } | Should Throw 'Restart Windows'
            $script:bootId = 'BOOT-2'
            { Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Release } | Should Throw 'Finish the previous uninstall'
        }

        It 'rejects an unsafe state path before opening an elevated log file' {
            Mock Protect-SetupStateFolder { throw 'Unsafe state owner.' }
            { Initialize-SetupLog $script:statePath Install } | Should Throw 'Unsafe state owner'
            $script:LogPath | Should Be ''
            Test-Path -LiteralPath $script:statePath | Should Be $false
        }

        It 'rejects malformed ownership data before issuing removals' {
            $state = New-SetupState
            $state.DeviceIds = @('ROOT\IDDSAMPLEDRIVER\0000')
            Save-SetupState $state $script:statePath
            { Invoke-SetupDriverAction Uninstall '' $script:statePath } | Should Throw 'invalid device'
            Assert-MockCalled Remove-SetupDevice -Times 0 -Exactly -Scope It
        }

        It 'does not destroy prior installation resources when an upgrade fails' {
            $null = Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Release
            $script:bindingFails = $true
            { Invoke-SetupDriverAction Install 'X:\payload' $script:statePath Release } | Should Throw 'Windows refused'
            (Read-SetupState $script:statePath).Installed | Should Be $true
            $script:removedIds.Count | Should Be 0
            $script:deletedPackages.Count | Should Be 0
        }
    }
}

InModuleScope Setup-DriverSupport {
    Describe 'pnputil native process exit status' {
        It 'never treats nonzero native driver failure as success' {
            # The actual command adapter is tested using a safe local executable
            # which only exits. No Windows driver operation is run.
            $script:LogPath = ''
            Mock Join-Path { return (Join-Path $PSHOME 'powershell.exe') } -ParameterFilter { $ChildPath -eq 'System32\pnputil.exe' }
            { Invoke-SetupPnpUtil @('-NoProfile', '-Command', 'exit 5') } | Should Throw 'exit code 5'
        }
    }
}

