# Windows PowerShell 5.1. Native provider tests touch only disposable HKCU keys.
Import-Module (Join-Path $PSScriptRoot '..\scripts\Setup-DriverSupport.psm1') -Force

InModuleScope Setup-DriverSupport {
    Describe 'Windows registry setup with real provider operations' {
        BeforeEach {
            $script:LogPath = ''
            $script:probeBase = 'HKCU:\Software\WinSideUSBSetupProbe-' + [guid]::NewGuid().ToString('N')
            $null = New-Item -Path $script:probeBase -Force
            $script:probeAcl = Get-SetupRegistryAcl $script:probeBase
            $script:probeKey = $script:probeBase + '\Vendor\VirtualDisplayDriver'
            $script:probeStatePath = Join-Path $TestDrive 'registry-state.json'
            $script:probeState = New-SetupState
            $script:probeState.SignedConfig = [pscustomobject]@{
                Registry = @(); RegistryKeys = @()
                XmlPath = (Join-Path $TestDrive 'absent.xml')
                Directory = (Join-Path $TestDrive 'absent-directory')
            }
            # User-owned test keys cannot have the production HKLM/admin owner.
            # Keep actual key creation, value I/O, ACL I/O and restoration real.
            Mock Assert-SetupTrustedRegistryAcl {}
            Mock New-SetupRegistryAcl { $script:probeAcl }
        }
        AfterEach {
            if ($script:probeBase -notmatch '^HKCU:\\Software\\WinSideUSBSetupProbe-[a-f0-9]{32}$') { throw 'Unexpected test cleanup target.' }
            if (Test-Path -LiteralPath $script:probeBase) { Remove-Item -LiteralPath $script:probeBase -Recurse -Force }
        }
        It 'reads an existing nested key through the literal registry handle' {
            $null = New-Item -Path $script:probeKey -Force
            $acl = Get-SetupRegistryAcl $script:probeKey
            $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should Not BeNullOrEmpty
            $value = Get-SetupRegistryValue $script:probeKey 'VDDPATH'
            $value.KeyExisted | Should Be $true
            $value.Existed | Should Be $false
            $value.KeySddl | Should Not BeNullOrEmpty
        }
        It 'creates a missing nested key and records the actual installed ACL and value' {
            Set-SetupOwnedRegistryValue $script:probeState $script:probeStatePath $script:probeKey 'VDDPATH' 'C:\Example\Config'
            $value = Get-SetupRegistryValue $script:probeKey 'VDDPATH'
            $value.Value | Should Be 'C:\Example\Config'
            $script:probeState.SignedConfig.RegistryKeys.Count | Should Be 1
            $script:probeState.SignedConfig.RegistryKeys[0].Existed | Should Be $false
            $script:probeState.SignedConfig.RegistryKeys[0].InstalledSddl | Should Be $value.KeySddl
            Remove-SetupSignedConfiguration $script:probeState $script:probeStatePath
            (Test-Path -LiteralPath $script:probeKey) | Should Be $false
        }
        It 'applies a newly constructed descriptor without trying to reassign its owner or group' {
            $script:freshAcl = New-Object Security.AccessControl.RegistrySecurity
            $script:freshAcl.SetSecurityDescriptorSddlForm($script:probeAcl.GetSecurityDescriptorSddlForm('All'))
            Mock New-SetupRegistryAcl { $script:freshAcl }
            Set-SetupOwnedRegistryValue $script:probeState $script:probeStatePath $script:probeKey 'VDDPATH' 'C:\Example\Config'
            (Get-SetupRegistryValue $script:probeKey 'VDDPATH').Value | Should Be 'C:\Example\Config'
            (Get-SetupRegistryAcl $script:probeKey).GetOwner([Security.Principal.SecurityIdentifier]).Value | Should Be $script:probeAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        }
        It 'restores previous values, value types and permissions on an existing key' {
            $null = New-Item -Path $script:probeKey -Force
            $null = New-ItemProperty -LiteralPath $script:probeKey -Name 'VDDPATH' -Value 'C:\Previous' -PropertyType String
            $null = New-ItemProperty -LiteralPath $script:probeKey -Name 'LOGS' -Value 1 -PropertyType DWord
            $before = Get-SetupRegistryAcl $script:probeKey
            Set-SetupOwnedRegistryValue $script:probeState $script:probeStatePath $script:probeKey 'VDDPATH' 'C:\Example\Config'
            Set-SetupOwnedRegistryValue $script:probeState $script:probeStatePath $script:probeKey 'LOGS' 0 DWord
            (Get-SetupRegistryValue $script:probeKey 'LOGS').Value | Should Be 0
            Remove-SetupSignedConfiguration $script:probeState $script:probeStatePath
            (Get-SetupRegistryValue $script:probeKey 'VDDPATH').Value | Should Be 'C:\Previous'
            $flag = Get-SetupRegistryValue $script:probeKey 'LOGS'
            $flag.Kind | Should Be DWord
            $flag.Value | Should Be 1
            $after = Get-SetupRegistryAcl $script:probeKey
            $after.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should Be $before.GetOwner([Security.Principal.SecurityIdentifier]).Value
            $after.GetGroup([Security.Principal.SecurityIdentifier]).Value | Should Be $before.GetGroup([Security.Principal.SecurityIdentifier]).Value
            $after.AreAccessRulesProtected | Should Be $before.AreAccessRulesProtected
            # Windows may normalize the auto-inherited descriptor flag on a
            # write. Compare the actual permissions and inheritance instead.
            $beforeRules = @($before.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Select-Object IdentityReference,RegistryRights,AccessControlType,InheritanceFlags,PropagationFlags,IsInherited) | ConvertTo-Json -Compress
            $afterRules = @($after.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Select-Object IdentityReference,RegistryRights,AccessControlType,InheritanceFlags,PropagationFlags,IsInherited) | ConvertTo-Json -Compress
            $afterRules | Should Be $beforeRules
        }
        It 'preserves a value changed after setup instead of removing a foreign change' {
            Set-SetupOwnedRegistryValue $script:probeState $script:probeStatePath $script:probeKey 'VDDPATH' 'C:\Example\Config'
            Set-ItemProperty -LiteralPath $script:probeKey -Name 'VDDPATH' -Value 'C:\Changed'
            Remove-SetupSignedConfiguration $script:probeState $script:probeStatePath
            (Get-SetupRegistryValue $script:probeKey 'VDDPATH').Value | Should Be 'C:\Changed'
        }
    }

    Describe 'Registry trust validation on real and representative descriptors' {
        It 'accepts the normal SOFTWARE parent permissions without changing them' {
            Assert-SetupTrustedRegistryAcl (Get-SetupRegistryAcl 'HKLM:\SOFTWARE')
        }
        It 'accepts the creator-owner inheritance placeholder with an administrator owner' {
            $acl = New-Object Security.AccessControl.RegistrySecurity
            $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;CI;KA;;;CO)(A;CI;KA;;;SY)(A;CI;KA;;;BA)(A;CI;KR;;;BU)')
            Assert-SetupTrustedRegistryAcl $acl
        }
        It 'rejects an effective non-administrator writer even with creator-owner inheritance' {
            $acl = New-Object Security.AccessControl.RegistrySecurity
            $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;CI;KA;;;CO)(A;CI;KA;;;SY)(A;CI;KA;;;BA)(A;CI;KA;;;BU)')
            { Assert-SetupTrustedRegistryAcl $acl } | Should Throw 'non-administrator changes'
        }
        It 'still rejects an untrusted owner' {
            $acl = New-Object Security.AccessControl.RegistrySecurity
            $acl.SetSecurityDescriptorSddlForm('O:BUG:BAD:P(A;CI;KA;;;CO)(A;CI;KA;;;SY)(A;CI;KA;;;BA)')
            { Assert-SetupTrustedRegistryAcl $acl } | Should Throw 'untrusted owner'
        }
    }
}
