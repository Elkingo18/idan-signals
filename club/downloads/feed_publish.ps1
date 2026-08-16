# Idans Money Club - feed publisher (Windows)
# Reads the member's own MetaTrader status.json (written by the gold bot)
# and posts a small snapshot so their own stack shows in the app.
# Demo data only. Read-only: it never places or changes an order.
# Runs safely under Smart App Control's Constrained Language Mode.
# Pass -loop to keep publishing every 2 minutes (used by the Startup launcher).
param([switch]$Loop)

$ROOT = Join-Path $env:USERPROFILE 'IdanClub'
$LOG  = Join-Path $ROOT 'feed.log'
function Say($m){ try { Add-Content -Path $LOG -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 } catch {} }

$PROJECT = 'idan-money-club'
$APIKEY  = 'AIzaSyA0n2xr_xomM8L_Usqrq_qFHb-ZliDAN5M'

function Publish-Feed {
    $keyFile = Join-Path $ROOT 'feed.txt'
    if (-not (Test-Path -LiteralPath $keyFile)) { Say 'no feed.txt - run the setup first'; return }
    $KEY = (Get-Content -LiteralPath $keyFile -Raw).Trim()
    if ($KEY.Length -lt 24) { Say 'feed key too short'; return }

    # newest status.json the gold bot has written, across all terminals
    $base = Join-Path $env:APPDATA 'MetaQuotes\Terminal'
    $status = $null
    if (Test-Path -LiteralPath $base) {
        $status = Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Join-Path $_.FullName 'MQL5\Files\IdanGold\status.json'
            if (Test-Path -LiteralPath $p) { Get-Item -LiteralPath $p }
        } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if (-not $status) { Say 'no status.json yet - is the bot on a chart with algo-trading on?'; return }

    try {
        $raw = Get-Content -LiteralPath $status.FullName -Raw -Encoding UTF8
        $j = $raw | ConvertFrom-Json
    } catch { Say ('could not read status.json: ' + $_.Exception.Message); return }

    # compact payload - only what the app seat needs
    $compact = ('{"account":' + [string]$j.account +
                ',"balance":' + [string]$j.balance +
                ',"equity":' + [string]$j.equity +
                ',"day_pnl":' + [string]$j.day_pnl +
                ',"trades_today":' + [string]$j.trades_today +
                ',"enabled":' + ($(if ($j.enabled -eq $false) {'false'} else {'true'})) +
                ',"params_version":' + [string]$j.params_version + '}')
    $acct = [string]$j.account
    $nowIso = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    $esc = $compact.Replace('"','\"')
    $body = '{"fields":{"j":{"stringValue":"' + $esc + '"},"t":{"stringValue":"' + $nowIso +
            '"},"acct":{"stringValue":"' + $acct + '"},"v":{"integerValue":"1"}}}'
    $url = 'https://firestore.googleapis.com/v1/projects/' + $PROJECT +
           '/databases/(default)/documents/feeds/' + $KEY + '?key=' + $APIKEY

    try {
        Invoke-RestMethod -Method Patch -Uri $url -ContentType 'application/json' -Body $body | Out-Null
        Say ('posted equity=' + [string]$j.equity + ' day=' + [string]$j.day_pnl)
    } catch {
        Say ('post failed: ' + $_.Exception.Message)
    }
}

if ($Loop) {
    Say 'feed loop started'
    while ($true) {
        Publish-Feed
        Start-Sleep -Seconds 120
    }
} else {
    Publish-Feed
}
