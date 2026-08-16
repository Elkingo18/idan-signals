# Idans Money Club - feed publisher
# Reads the member's own MetaTrader demo status.json (written by the gold bot)
# and posts a compact snapshot to the club so the member sees their own stack
# in the app. Demo data only. No passwords, no orders, read-only.
$ErrorActionPreference = 'Continue'
$root = Join-Path $env:USERPROFILE 'IdanClub'
$log  = Join-Path $root 'feed.log'
function Say($m){ Add-Content -Path $log -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 }

$PROJECT = 'idan-money-club'
$APIKEY  = 'AIzaSyA0n2xr_xomM8L_Usqrq_qFHb-ZliDAN5M'

$keyFile = Join-Path $root 'feed.txt'
if (-not (Test-Path -LiteralPath $keyFile)) { Say 'no feed.txt - run the setup first'; exit 1 }
$KEY = (Get-Content -LiteralPath $keyFile -Raw).Trim()
if ($KEY.Length -lt 24) { Say 'feed key too short'; exit 1 }

# find the member's MT5 status.json (the bot writes MQL5\Files\IdanGold\status.json)
$base = Join-Path $env:APPDATA 'MetaQuotes\Terminal'
$status = $null
if (Test-Path -LiteralPath $base) {
    $status = Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Join-Path $_.FullName 'MQL5\Files\IdanGold\status.json'
        if (Test-Path -LiteralPath $p) { Get-Item -LiteralPath $p }
    } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (-not $status) { Say 'no status.json yet - is the bot on a chart with algo-trading on?'; exit 0 }

try {
    $raw = Get-Content -LiteralPath $status.FullName -Raw -Encoding UTF8
    $j = $raw | ConvertFrom-Json
} catch { Say ('could not read status.json: ' + $_.Exception.Message); exit 0 }

# compact payload - only what the app seat needs
$compact = @{
    account       = $j.account
    balance       = $j.balance
    equity        = $j.equity
    day_pnl       = $j.day_pnl
    trades_today  = $j.trades_today
    enabled       = $j.enabled
    params_version= $j.params_version
} | ConvertTo-Json -Compress

$acct = [string]$j.account
$nowIso = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

# Firestore REST - PATCH feeds/{KEY}. Rule allows the fixed 4-field shape.
$url = "https://firestore.googleapis.com/v1/projects/$PROJECT/databases/(default)/documents/feeds/$KEY`?key=$APIKEY"
$body = @{ fields = @{
    j    = @{ stringValue = $compact }
    t    = @{ stringValue = $nowIso }
    acct = @{ stringValue = $acct }
    v    = @{ integerValue = '1' }
} } | ConvertTo-Json -Depth 6

try {
    Invoke-RestMethod -Method Patch -Uri $url -ContentType 'application/json' -Body $body | Out-Null
    Say ('posted equity=' + $j.equity + ' day=' + $j.day_pnl)
} catch {
    Say ('post failed: ' + $_.Exception.Message)
}
