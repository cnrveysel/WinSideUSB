# Read-only native Driver Store integration. Requires the pinned package to
# have been staged by the install under test; no staging/removal is performed.
Import-Module (Join-Path $PSScriptRoot '..\scripts\Setup-DriverSupport.psm1') -Force

InModuleScope Setup-DriverSupport {
    Describe 'Published package lookup using actual Windows Driver Store' {
        BeforeEach {
            $script:sourcePackage = Join-Path (Split-Path (Get-Module Setup-DriverSupport).Path -Parent) '..\.codex\vendor\VirtualDisplayDriver'
            $script:copyPackage = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $script:copyPackage
            foreach ($name in @('MttVDD.inf','MttVDD.dll','mttvdd.cat')) {
                Copy-Item -LiteralPath (Join-Path $script:sourcePackage $name) -Destination $script:copyPackage
            }
            $script:sourceInf = Join-Path $script:copyPackage 'MttVDD.inf'
        }
        It 'finds a staged full package from an arbitrary extracted source path' {
            $published = Get-SetupPublishedInf $script:sourceInf
            $published | Should Match '^oem[0-9]+\.inf$'
            (Get-SetupInfHash $published) | Should Be (Get-FileHash -LiteralPath $script:sourceInf).Hash
        }
        It 'does not match a different INF' {
            Add-Content -LiteralPath $script:sourceInf -Value '; changed'
            Get-SetupPublishedInf $script:sourceInf | Should BeNullOrEmpty
        }
        It 'does not assume ownership from identical INF bytes with a different DLL' {
            Add-Content -LiteralPath (Join-Path $script:copyPackage 'MttVDD.dll') -Value 'changed'
            Get-SetupPublishedInf $script:sourceInf | Should BeNullOrEmpty
        }
        It 'does not assume ownership from identical INF and DLL bytes with a different catalog' {
            Add-Content -LiteralPath (Join-Path $script:copyPackage 'mttvdd.cat') -Value 'changed'
            Get-SetupPublishedInf $script:sourceInf | Should BeNullOrEmpty
        }
    }
}
