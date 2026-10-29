$ErrorActionPreference = 'Stop'

# Keep the distributable single-file client and the installed app identical.
$repo = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo 'WinSideUSB\swiftclientcode.swift'
$destination = Join-Path $repo 'iPadClient\Sources\WinSideUSBClient\App.swift'
Copy-Item -LiteralPath $source -Destination $destination -Force
Write-Host 'iPad app source synchronized with swiftclientcode.swift.'
