# Idans Money Club - Stocks (paper) feed setup
# Sets up the same connection key for the stocks side. In this version it
# registers the key and prepares the folder; the full paper-trading engine
# for a member's own IBKR paper account is delivered in the next update.
$ErrorActionPreference = 'Continue'
$root = Join-Path $env:USERPROFILE 'IdanClub'
if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root | Out-Null }
$log = Join-Path $root 'stocks_setup.log'
function Say($m){ Write-Host $m; Add-Content -Path $log -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 }

Say ''
Say '   Idans Money Club - Stocks (paper) setup'
Say ''

$keyFile = Join-Path $root 'feed.txt'
$KEY = ''
if (Test-Path -LiteralPath $keyFile) { $KEY = (Get-Content -LiteralPath $keyFile -Raw).Trim() }
if ($KEY.Length -lt 24) {
    Say 'Paste the same connection key from the app and press Enter:'
    $KEY = (Read-Host '  key').Trim()
    if ($KEY.Length -lt 24) { Say 'That key looks too short. Create one in the app and run this again.'; return }
    Set-Content -LiteralPath $keyFile -Value $KEY -Encoding ASCII
}
Say 'Connection key saved for the stocks side.'
Say ''
Say 'Make sure Interactive Brokers TWS is running with the paper account,'
Say 'and API is enabled: File > Global Configuration > API > Settings >'
Say 'Enable ActiveX and Socket Clients, socket port 7497.'
Say ''
Say 'You are set up. The automatic paper-trading engine for your own IBKR'
Say 'account arrives in the next app update - you will get a notice in the app.'
