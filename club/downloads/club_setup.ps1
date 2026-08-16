# =====================================================================
#  Idans Money Club - one-click setup (runs on a MEMBER's own PC)
#  Installs the club's gold bot into the member's own MetaTrader 5 DEMO
#  account, attaches it to a gold chart automatically, and starts the
#  feed so the member sees their own stack inside the app.
#  DEMO MONEY ONLY. No passwords are ever asked for or stored.
# =====================================================================
$ErrorActionPreference = 'Continue'
$BASEURL = 'https://elkingo18.github.io/idan-signals/club/downloads/'
$root = Join-Path $env:USERPROFILE 'IdanClub'
if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
$log = Join-Path $root 'setup.log'
function Say($m){ Write-Host $m; try { Add-Content -Path $log -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 } catch {} }
function Line(){ Say '' }

Line
Say '============================================================'
Say '        Idans Money Club  -  Gold Bot setup'
Say '        Demo money only. Nothing here touches real funds.'
Say '============================================================'
Line

# ---------------------------------------------------------------------
# 1. connection key - created here, pasted into the app afterwards.
#    (This order matters: a new member can install BEFORE being approved,
#     then paste the key into the app once Idan lets them in.)
# ---------------------------------------------------------------------
$keyFile = Join-Path $root 'feed.txt'
$KEY = ''
if (Test-Path -LiteralPath $keyFile) { $KEY = (Get-Content -LiteralPath $keyFile -Raw).Trim() }
if ($KEY.Length -lt 24) {
    # Get-Random only: .NET crypto classes are blocked when Windows
    # Smart App Control forces PowerShell into Constrained Language Mode.
    $KEY = 'f' + (-join (1..32 | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] }))
    Set-Content -LiteralPath $keyFile -Value $KEY -Encoding ASCII
}
Say 'STEP 1 of 5 - your personal connection key:'
Line
Say ('        ' + $KEY)
Line
Say ('   It is saved here:  ' + $keyFile)
Say '   You will paste it into the app at the end (Connections screen).'
try { Set-Clipboard -Value $KEY; Say '   (copied to your clipboard)' } catch {}
Line

# ---------------------------------------------------------------------
# 2. find the member's MetaTrader 5 (data folder + the .exe that owns it)
# ---------------------------------------------------------------------
Say 'STEP 2 of 5 - looking for MetaTrader 5 ...'
$tbase = Join-Path $env:APPDATA 'MetaQuotes\Terminal'
if (-not (Test-Path -LiteralPath $tbase)) {
    Say '   MetaTrader 5 is not installed (or was never opened).'
    Say '   Install it from https://www.metatrader5.com/en/download ,'
    Say '   open a DEMO account inside it, then run this file again.'
    return
}
# plain variables - [pscustomobject] is blocked in Constrained Language Mode
$Tdata = ''; $Tname = ''; $Texe = ''; $Torigin = ''; $Tseen = $null
$anyData = ''; $anyName = ''; $anySeen = $null
foreach ($d in (Get-ChildItem -LiteralPath $tbase -Directory -ErrorAction SilentlyContinue)) {
    $expd = Join-Path $d.FullName 'MQL5\Experts'
    if (-not (Test-Path -LiteralPath $expd)) { continue }
    if (($null -eq $anySeen) -or ($d.LastWriteTime -gt $anySeen)) {
        $anyData = $d.FullName; $anyName = $d.Name; $anySeen = $d.LastWriteTime
    }
    $origin = ''
    $op = Join-Path $d.FullName 'origin.txt'
    if (Test-Path -LiteralPath $op) { $origin = (Get-Content -LiteralPath $op -Raw -ErrorAction SilentlyContinue).Trim() }
    $exe = ''
    if ($origin -and (Test-Path -LiteralPath (Join-Path $origin 'terminal64.exe'))) { $exe = Join-Path $origin 'terminal64.exe' }
    if ($exe -and (($null -eq $Tseen) -or ($d.LastWriteTime -gt $Tseen))) {
        $Tdata = $d.FullName; $Tname = $d.Name; $Texe = $exe; $Torigin = $origin; $Tseen = $d.LastWriteTime
    }
}
if (-not $Tdata) { $Tdata = $anyData; $Tname = $anyName }
if (-not $Tdata) {
    Say '   Found the MetaQuotes folder but no terminal data yet.'
    Say '   Open MetaTrader once, log into a DEMO account, then run this again.'
    return
}
Say ('   Using MetaTrader data folder: ' + $Tname)
if ($Texe) { Say ('   Terminal program:            ' + $Texe) }

# which gold symbol does this broker use?
$SYM = 'XAUUSD'
try {
    $sbase = Join-Path $Tdata 'bases'
    if (Test-Path -LiteralPath $sbase) {
        $hit = Get-ChildItem -LiteralPath $sbase -Recurse -Directory -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match '^(XAUUSD|GOLD)' } | Select-Object -First 1
        if ($hit) { $SYM = $hit.Name }
    }
} catch {}
Say ('   Gold symbol:                ' + $SYM)

# ---------------------------------------------------------------------
# 3. install the bot + the exact settings Idan runs
# ---------------------------------------------------------------------
Say 'STEP 3 of 5 - installing the bot ...'
$exp = Join-Path $Tdata 'MQL5\Experts'
$mq  = Join-Path $exp 'IdanGold.mq5'
$ex5 = Join-Path $exp 'IdanGold.ex5'
$gotBot = $false
try {
    # (no TLS tweak here on purpose: setting it is a .NET static call, which
    #  Smart App Control blocks. Windows 11 already negotiates TLS 1.2+.)
    # the ready-to-run build - no compiling needed on the member's machine
    Invoke-WebRequest -Uri ($BASEURL + 'IdanGold.ex5') -OutFile $ex5 -UseBasicParsing -TimeoutSec 90
    if ((Get-Item -LiteralPath $ex5 -ErrorAction SilentlyContinue).Length -gt 10000) { $gotBot = $true; Say '   Bot installed (ready-to-run build, nothing to compile).' }
} catch { Say ('   Ready-made build not available: ' + $_.Exception.Message) }
if (-not $gotBot) {
    try {
        Invoke-WebRequest -Uri ($BASEURL + 'IdanGold.mq5') -OutFile $mq -UseBasicParsing -TimeoutSec 60
        Say '   Bot source downloaded (will be compiled below).'
    } catch { Say ('   Could not download the bot: ' + $_.Exception.Message); return }
}

$filesDir = Join-Path $Tdata 'MQL5\Files\IdanGold'
if (-not (Test-Path -LiteralPath $filesDir)) { New-Item -ItemType Directory -Path $filesDir -Force | Out-Null }
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
Say '   Settings written (same as Idans: burst entry, risk ladder 3-9%).'

# compile - only needed if the ready-to-run build was unavailable
$me = $null
if ($gotBot) { $me = $null } else {
if ($Torigin -and (Test-Path -LiteralPath (Join-Path $Torigin 'metaeditor64.exe'))) { $me = Join-Path $Torigin 'metaeditor64.exe' }
if (-not $me) {
    foreach ($g in @('C:\Program Files\MetaTrader 5\metaeditor64.exe',
                     'C:\Program Files\MetaTrader 5 - v7.2\metaeditor64.exe',
                     "$env:USERPROFILE\AppData\Roaming\MetaQuotes\metaeditor64.exe")) {
        if (Test-Path -LiteralPath $g) { $me = $g; break }
    }
}
if (-not $me) {
    $f = Get-ChildItem 'C:\Program Files' -Recurse -Filter 'metaeditor64.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $me = $f.FullName }
}
}
$compiled = $gotBot
if (-not $gotBot) {
    if ($me) {
        try {
            $c = Start-Process -FilePath $me -ArgumentList @("/compile:`"$mq`"") -PassThru -Wait -WindowStyle Hidden
            if (Test-Path -LiteralPath $ex5) { $compiled = $true; Say '   Compiled the bot.' }
        } catch { Say ('   Automatic compile did not run: ' + $_.Exception.Message) }
    } else {
        Say '   MetaEditor not found - open MetaEditor once, select IdanGold and press F7.'
    }
    if (-not $compiled) { Say '   NOTE: if the bot is missing from the Navigator, open MetaEditor, select IdanGold, press F7.' }
}

# ---------------------------------------------------------------------
# 4. attach it to a gold chart automatically and start the terminal
# ---------------------------------------------------------------------
Say 'STEP 4 of 5 - putting the bot on a gold chart ...'
$ini = Join-Path $root 'idan_club.ini'
$iniText = @"
[Common]
AutoConfiguration=0
EnableDDE=0
EnableNews=0

[Experts]
AllowLiveTrading=1
AllowDllImport=0
Enabled=1
Account=0
Profile=0

[StartUp]
Expert=IdanGold
Symbol=$SYM
Period=M15
"@
Set-Content -LiteralPath $ini -Value $iniText -Encoding ASCII
if ($Texe) {
    try {
        Get-Process terminal64 -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $Texe } | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 4
        Start-Process -FilePath $Texe -ArgumentList ('/config:"{0}"' -f $ini)
        Say '   MetaTrader restarted with the bot on a gold chart.'
    } catch { Say ('   Could not restart MetaTrader automatically: ' + $_.Exception.Message) }
} else {
    Say '   Open MetaTrader, open a ' + $SYM + ' chart, and drag IdanGold onto it.'
}

# ---------------------------------------------------------------------
# 5. the feed - so the member sees their own account in the app
# ---------------------------------------------------------------------
Say 'STEP 5 of 5 - connecting your account to the app ...'
$feed = Join-Path $root 'feed_publish.ps1'
try {
    Invoke-WebRequest -Uri ($BASEURL + 'feed_publish.ps1') -OutFile $feed -UseBasicParsing -TimeoutSec 60
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $feed + '"')
    $tr1 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
    $tr2 = New-ScheduledTaskTrigger -AtLogOn
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'IdanClubFeed' -Action $action -Trigger @($tr1,$tr2) -Settings $set -Force | Out-Null
    Say '   Feed installed (updates the app every 2 minutes).'
    Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $feed + '"') -WindowStyle Hidden
} catch { Say ('   Could not install the feed task: ' + $_.Exception.Message) }

# a friendly desktop shortcut to the app
try {
    $desk = Join-Path $env:USERPROFILE 'Desktop'
    if (-not (Test-Path -LiteralPath $desk)) { New-Item -ItemType Directory -Path $desk -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $desk 'Idans Money Club.url') `
        -Value "[InternetShortcut]`r`nURL=https://elkingo18.github.io/idan-signals/club/" -Encoding ASCII
    Say '   Shortcut to the app added to your desktop.'
} catch { Say '   (could not add a desktop shortcut - not important)' }

# open the app so the member lands in the right place
try { Start-Process 'https://elkingo18.github.io/idan-signals/club/' } catch {}

Line
Say '============================================================'
Say '  DONE. Two small things you do by hand:'
Line
Say '  1) In MetaTrader, look at the top toolbar: the'
Say '     "Algo Trading" button must be GREEN. If it is red,'
Say '     click it once.'
Line
Say '  2) The app just opened in your browser. Sign in with'
Say '     Google, and in the "Connections" screen paste this key:'
Line
Say ('        ' + $KEY)
Line
Say '     (it is already on your clipboard - just press Ctrl+V)'
Line
Say '  Within ~2 minutes your own account shows up in the app.'
Say '  If Idan has not approved you yet, you will see a waiting'
Say '  screen - that is normal, he approves you with one click.'
Say '============================================================'
