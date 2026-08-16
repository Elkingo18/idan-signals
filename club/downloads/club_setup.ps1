# Idans Money Club - Gold Bot installer (runs on a member's own PC)
# Installs the gold bot into the member's MetaTrader 5 DEMO account and sets
# up the feed publisher so the member sees their own stack in the app.
# Demo money only. No passwords are ever asked or stored.
$ErrorActionPreference = 'Continue'
$root = Join-Path $env:USERPROFILE 'IdanClub'
if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root | Out-Null }
$log = Join-Path $root 'setup.log'
function Say($m){ Write-Host $m; Add-Content -Path $log -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 }
$BASEURL = 'https://elkingo18.github.io/idan-signals/club/downloads/'

Say ''
Say '=========================================='
Say '   Idans Money Club - Gold Bot setup'
Say '=========================================='
Say ''

# --- 1. the feed key -------------------------------------------------------
$keyFile = Join-Path $root 'feed.txt'
$KEY = ''
if (Test-Path -LiteralPath $keyFile) { $KEY = (Get-Content -LiteralPath $keyFile -Raw).Trim() }
if ($KEY.Length -lt 24) {
    Say 'Paste the connection key from the app (Connections screen) and press Enter:'
    $KEY = (Read-Host '  key').Trim()
    if ($KEY.Length -lt 24) { Say 'That key looks too short. Open the app, create a key, and run this again.'; return }
    Set-Content -LiteralPath $keyFile -Value $KEY -Encoding ASCII
}
Say ('Connection key saved.')

# --- 2. find the MetaTrader 5 demo terminal -------------------------------
$tbase = Join-Path $env:APPDATA 'MetaQuotes\Terminal'
if (-not (Test-Path -LiteralPath $tbase)) {
    Say 'MetaTrader 5 is not installed yet.'
    Say 'Install it from https://www.metatrader5.com/en/download, open a DEMO account, then run this again.'
    return
}
$terminals = Get-ChildItem -LiteralPath $tbase -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'MQL5\Experts') } |
    Sort-Object LastWriteTime -Descending
if (-not $terminals) {
    Say 'Found MetaTrader but no data folder with MQL5\Experts yet.'
    Say 'Open MetaTrader once, log into a DEMO account, then run this again.'
    return
}
$T = $terminals[0]
Say ('Using MetaTrader data folder: ' + $T.Name)

# --- 3. drop the bot + starting params ------------------------------------
$exp = Join-Path $T.FullName 'MQL5\Experts'
$mq  = Join-Path $exp 'IdanGold.mq5'
try {
    Invoke-WebRequest -Uri ($BASEURL + 'IdanGold.mq5') -OutFile $mq -UseBasicParsing
    Say 'Downloaded the bot source.'
} catch { Say ('Could not download the bot: ' + $_.Exception.Message); return }

$filesDir = Join-Path $T.FullName 'MQL5\Files\IdanGold'
if (-not (Test-Path -LiteralPath $filesDir)) { New-Item -ItemType Directory -Path $filesDir -Force | Out-Null }
# exact params Idan runs (v36). The bot also self-heals this if missing.
$params = @'
{ "version":36,"enabled":true,"risk_pct":5.0,"h1_fast":34,"h1_slow":89,
"ema_fast":20,"ema_slow":600,"atr_period":14,"sl_atr":1.0,"tp1_r":1.5,"tp2_r":5.0,
"tp1_close_frac":0.0,"be_at_r":0.5,"trail_atr":2.0,"max_spread_frac":0.1,
"atr_min_points":60.0,"atr_max_points":1600,"max_trades_day":999,
"daily_loss_stop_pct":6.0,"max_consec_losses":3,"cooldown_bars":8,"tf_minutes":15,
"lock_at_r":0.3,"lock_give_r":0.15,"fixed_lots":0.0,"max_stake_pct":9.0,
"entry_mode":1,"burst_bars":4,"burst_atr":2.0,"risk_mode":1,
"rp_peak":5.0,"rp_norm":4.0,"rp_dd1":2.5,"rp_dd2":1.5,"dd1_pct":15.0,"dd2_pct":30.0 }
'@
Set-Content -LiteralPath (Join-Path $filesDir 'params.json') -Value $params -Encoding ASCII
Say 'Wrote the starting settings (same as Idans, risk ladder 3-9%).'

# --- 4. compile it with MetaEditor ----------------------------------------
$me = $null
foreach ($g in @('C:\Program Files\MetaTrader 5\metaeditor64.exe',
                 'C:\Program Files\MetaTrader 5 - v7.2\metaeditor64.exe')) {
    if (Test-Path -LiteralPath $g) { $me = $g; break }
}
if (-not $me) {
    $found = Get-ChildItem 'C:\Program Files' -Recurse -Filter 'metaeditor64.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $me = $found.FullName }
}
if ($me) {
    try {
        $c = Start-Process -FilePath $me -ArgumentList @("/compile:`"$mq`"") -PassThru -Wait -WindowStyle Hidden
        Say ('Compiled the bot (MetaEditor exit ' + $c.ExitCode + ').')
    } catch { Say ('Compile step could not run automatically: ' + $_.Exception.Message) }
} else {
    Say 'Note: could not find MetaEditor to compile automatically. Open MetaEditor, press F7 on IdanGold, once.'
}

# --- 5. install the feed publisher (every 2 minutes) ----------------------
$feed = Join-Path $root 'feed_publish.ps1'
try {
    Invoke-WebRequest -Uri ($BASEURL + 'feed_publish.ps1') -OutFile $feed -UseBasicParsing
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $feed + '"')
    $tr1 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
    $tr2 = New-ScheduledTaskTrigger -AtLogOn
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'IdanClubFeed' -Action $action -Trigger @($tr1,$tr2) -Settings $set -Force | Out-Null
    Say 'Feed publisher installed (updates the app every 2 minutes).'
} catch { Say ('Could not install the feed task: ' + $_.Exception.Message) }

Say ''
Say '=========================================='
Say ' Almost done. Last step you do by hand:'
Say '  1. Open MetaTrader 5'
Say '  2. Open a GOLD chart (XAUUSD)'
Say '  3. Drag "IdanGold" from Navigator onto the chart, click OK'
Say '  4. Make sure the "Algo Trading" button at the top is GREEN'
Say ' Then your stack shows up in the app within ~2 minutes.'
Say '=========================================='
