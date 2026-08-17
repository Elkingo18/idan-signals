# Idans Money Club - feed publisher (Windows)
# Reads the member's own MetaTrader status.json (written by the gold bot)
# and posts a snapshot of THEIR OWN account so the app shows their numbers.
# Demo data only. Read-only: it never places or changes an order.
# Runs safely under Smart App Control's Constrained Language Mode.
# Pass -loop to keep publishing every 2 minutes (used by the Startup launcher).
param([switch]$Loop)

$ROOT = Join-Path $env:USERPROFILE 'IdanClub'
$LOG  = Join-Path $ROOT 'feed.log'
$HISTFILE = Join-Path $ROOT 'hist.json'
function Say($m){ try { Add-Content -Path $LOG -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 } catch {} }

$PROJECT = 'idan-money-club'
$APIKEY  = 'AIzaSyA0n2xr_xomM8L_Usqrq_qFHb-ZliDAN5M'
$START_BALANCE = 10000.0

function Find-ParamsFile {
    # the gold bot reads MQL5\Files\IdanGold\params.json in its terminal
    $base = Join-Path $env:APPDATA 'MetaQuotes\Terminal'
    if (-not (Test-Path -LiteralPath $base)) { return $null }
    $hit = Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Join-Path $_.FullName 'MQL5\Files\IdanGold\params.json'
        if (Test-Path -LiteralPath $p) { Get-Item -LiteralPath $p }
    } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hit) { return $hit.FullName } else { return $null }
}
function Apply-Commands($KEY) {
    # Owner (Idan) can control this bot from the app. We READ commands/{KEY}
    # from Firestore (public read, owner-only write) and apply them locally
    # by editing the bot's params.json. The bot re-reads params.json live.
    $cmdFile = Join-Path $ROOT 'cmd_applied.txt'
    $lastTs = ''
    if (Test-Path -LiteralPath $cmdFile) { $lastTs = (Get-Content -LiteralPath $cmdFile -Raw).Trim() }
    $url = 'https://firestore.googleapis.com/v1/projects/' + $PROJECT +
           '/databases/(default)/documents/commands/' + $KEY + '?key=' + $APIKEY
    try {
        $doc = Invoke-RestMethod -Method Get -Uri $url -ErrorAction Stop
    } catch { return }   # no command doc yet -> nothing to do
    if (-not $doc.fields) { return }
    $f = $doc.fields
    $ts = ''
    if ($f.ts -and $f.ts.stringValue) { $ts = $f.ts.stringValue }
    if (-not $ts -or $ts -eq $lastTs) { return }   # already applied

    $pf = Find-ParamsFile
    if (-not $pf) { return }
    try {
        $p = Get-Content -LiteralPath $pf -Raw | ConvertFrom-Json
    } catch { return }

    $changed = $false
    if ($null -ne $f.enabled -and $null -ne $f.enabled.booleanValue) {
        $p.enabled = [bool]$f.enabled.booleanValue; $changed = $true
    }
    if ($f.params -and $f.params.mapValue -and $f.params.mapValue.fields) {
        $pp = $f.params.mapValue.fields
        if ($null -ne $pp.risk_mode -and $null -ne $pp.risk_mode.integerValue) {
            $p.risk_mode = [int]$pp.risk_mode.integerValue; $changed = $true
        }
        if ($pp.fixed_risk_pct -and ($pp.fixed_risk_pct.doubleValue -or $pp.fixed_risk_pct.integerValue)) {
            # a fixed risk: pin the whole ladder to that value.
            # whole numbers (1.0) arrive from the web SDK as integerValue!
            $rv = 0.0
            if ($pp.fixed_risk_pct.doubleValue) { $rv = [double]$pp.fixed_risk_pct.doubleValue }
            else { $rv = [double]$pp.fixed_risk_pct.integerValue }
            $p.rp_peak = $rv; $p.rp_norm = $rv; $p.rp_dd1 = $rv; $p.rp_dd2 = $rv
            $p.risk_pct = $rv; $changed = $true
        }
    }
    if ($changed) {
        try {
            $json = $p | ConvertTo-Json -Compress -Depth 6
            Set-Content -LiteralPath $pf -Value $json -Encoding ASCII
            Say ('applied owner command ts=' + $ts)
        } catch { Say ('apply failed: ' + $_.Exception.Message) }
    }
    # record we've applied this command (even restart-only, which the app shows)
    Set-Content -LiteralPath $cmdFile -Value $ts -Encoding ASCII
}

function Publish-Feed {
    $keyFile = Join-Path $ROOT 'feed.txt'
    if (-not (Test-Path -LiteralPath $keyFile)) { Say 'no feed.txt - run the setup first'; return }
    $KEY = (Get-Content -LiteralPath $keyFile -Raw).Trim()
    if ($KEY.Length -lt 24) { Say 'feed key too short'; return }

    # apply any pending owner command before reading status
    try { Apply-Commands $KEY } catch { Say ('command check failed: ' + $_.Exception.Message) }

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

    # --- keep a tiny local day-by-day history of THIS member's P&L ---------
    $hist = @{}
    if (Test-Path -LiteralPath $HISTFILE) {
        try { $h = Get-Content -LiteralPath $HISTFILE -Raw | ConvertFrom-Json
              foreach ($p in $h.PSObject.Properties) { $hist[$p.Name] = $p.Value } } catch {}
    }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $dp = 0.0; if ($null -ne $j.day_pnl) { $dp = [double]$j.day_pnl }
    # status.json already carries 2-decimal values; no [math]::Round (blocked in CLM)
    $hist[$today] = $dp
    try {
        $histJson = $hist | ConvertTo-Json -Compress
        Set-Content -LiteralPath $HISTFILE -Value $histJson -Encoding ASCII
    } catch { Say ('history save failed: ' + $_.Exception.Message) }

    # last 30 days as an ordered array
    $histArr = @()
    foreach ($k in ($hist.Keys | Sort-Object | Select-Object -Last 30)) {
        $histArr += @{ d = $k; pnl = $hist[$k] }
    }

    # --- the member's own open position, if any ----------------------------
    $pos = $null
    if ($null -ne $j.position -and $j.position -ne 'None' -and $j.position -ne '') {
        try {
            $pp = $j.position
            $pos = @{ side = [string]$pp.side; volume = $pp.volume; entry = $pp.entry;
                      last = $pp.last; profit = $pp.profit }
        } catch { $pos = $null }
    }

    # --- the payload: their account only -----------------------------------
    $obj = @{
        account        = $j.account
        balance        = $j.balance
        equity         = $j.equity
        day_pnl        = $dp
        trades_today   = $j.trades_today
        enabled        = [bool]$j.enabled
        params_version = $j.params_version
        start          = $START_BALANCE
        position       = $pos
        hist           = $histArr
    }
    $compact = $obj | ConvertTo-Json -Compress -Depth 6
    if ($compact.Length -gt 5800) {   # stay under the security-rule cap
        $obj.hist = ($histArr | Select-Object -Last 14)
        $compact = $obj | ConvertTo-Json -Compress -Depth 6
    }

    $acct = [string]$j.account
    $nowIso = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $body = @{ fields = @{
        j    = @{ stringValue = $compact }
        t    = @{ stringValue = $nowIso }
        acct = @{ stringValue = $acct }
        v    = @{ integerValue = '1' }
    } } | ConvertTo-Json -Compress -Depth 6

    $url = 'https://firestore.googleapis.com/v1/projects/' + $PROJECT +
           '/databases/(default)/documents/feeds/' + $KEY + '?key=' + $APIKEY
    try {
        Invoke-RestMethod -Method Patch -Uri $url -ContentType 'application/json' -Body $body | Out-Null
        Say ('posted equity=' + [string]$j.equity + ' day=' + [string]$dp)
    } catch {
        Say ('post failed: ' + $_.Exception.Message)
    }
}

if ($Loop) {
    Say 'feed loop started'
    while ($true) { Publish-Feed; Start-Sleep -Seconds 120 }
} else {
    Publish-Feed
}
