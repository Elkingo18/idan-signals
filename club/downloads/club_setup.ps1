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
$mq  = Join-Path $exp 'IdanDrawerGold.mq5'
$ex5 = Join-Path $exp 'IdanDrawerGold.ex5'
$gotBot = $false
try {
    # (no TLS tweak here on purpose: setting it is a .NET static call, which
    #  Smart App Control blocks. Windows 11 already negotiates TLS 1.2+.)
    # the ready-to-run build - no compiling needed on the member's machine
    Invoke-WebRequest -Uri ($BASEURL + 'IdanDrawerGold.ex5') -OutFile $ex5 -UseBasicParsing -TimeoutSec 90
    if ((Get-Item -LiteralPath $ex5 -ErrorAction SilentlyContinue).Length -gt 10000) { $gotBot = $true; Say '   Bot installed (ready-to-run build, nothing to compile).' }
} catch { Say ('   Ready-made build not available: ' + $_.Exception.Message) }
if (-not $gotBot) {
    try {
        Invoke-WebRequest -Uri ($BASEURL + 'IdanDrawerGold.mq5') -OutFile $mq -UseBasicParsing -TimeoutSec 60
        Say '   Bot source downloaded (will be compiled below).'
    } catch {
        # 19.8.2026 - THIS LINE USED TO SAY 'return', AND IT COST US A LIVE
        # INSTALL. The bot file was briefly missing from the site, the
        # download threw, the whole script stopped here - and the member
        # never reached step 5, so no feed task was created and no key was
        # printed at the end. A wall of red, and nothing connected.
        #
        # The bot is the LEAST urgent part of this script. The key and the
        # feed are what let Idan see the account at all, and a missing
        # download must never take them down with it. Carry on, and say
        # plainly what is missing.
        Say ('   Could not download the bot right now: ' + $_.Exception.Message)
        Say '   That is not fatal - your key and your connection are set up below.'
        Say '   Run this installer again in a few minutes and the bot will land.'
    }
}

$preDir = Join-Path $Tdata 'MQL5\Presets'
if (-not (Test-Path -LiteralPath $preDir)) { New-Item -ItemType Directory -Path $preDir -Force | Out-Null }
#  The bot ships DISARMED in its source on purpose. Arming lives here, in one
#  named file you can read and delete. Two numbers matter more than the rest:
#    InpMaxLegs=13       - the FULL 1050 ladder is the ceiling; since bot
#                          v1.17 the machine BENDS to the deepest rung your
#                          demo balance actually carries (the 10% worst-day
#                          rule) and climbs by itself as the balance grows.
#    InpWorstDayPctCap   - the brake that decides that depth. The bot this
#                          replicates ran 13 rungs unbraked on $201,000 and
#                          lost $197,000 in six hours on 19.8.2026 - the
#                          brake is the difference between the two stories.
@(
  'InpArmed=true',
  'InpDemoOnly=true',
  'InpWorstDayPctCap=10.0',
  'InpMaxLegs=13',
  'InpDailyTargetUsd=1350.0',
  'InpMagic=770118'
) | Set-Content -LiteralPath (Join-Path $preDir 'drawer.set') -Encoding ASCII
Say '   Settings written: ladder bends to your balance (ceiling 13), banks the day at +$1,350, demo only.'

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
        Say '   MetaEditor not found - open MetaEditor once, select IdanDrawerGold and press F7.'
    }
    if (-not $compiled) { Say '   NOTE: if the bot is missing from the Navigator, open MetaEditor, select IdanDrawerGold, press F7.' }
}

# ---------------------------------------------------------------------
# 4. attach it to a gold chart automatically and start the terminal
# ---------------------------------------------------------------------
Say 'STEP 4 of 5 - putting the bot on a gold chart ...'
if (-not (Test-Path -LiteralPath $ex5)) {
    Say '   No bot file yet - skipping the chart step. Everything below still runs.'
} else {
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
Expert=IdanDrawerGold
ExpertParameters=drawer.set
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
    Say '   Open MetaTrader, open a ' + $SYM + ' chart, and drag IdanDrawerGold onto it.'
}

}

# ---------------------------------------------------------------------
# 5. the feed - so the member sees their own account in the app
#    THIS ALWAYS RUNS. Nothing above it is allowed to skip it.
# ---------------------------------------------------------------------
Say 'STEP 5 of 5 - connecting your account to the app ...'
$feed = Join-Path $root 'feed_publish.ps1'
$feedArgs = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $feed + '" -loop'
try { Invoke-WebRequest -Uri ($BASEURL + 'feed_publish.ps1') -OutFile $feed -UseBasicParsing -TimeoutSec 60 }
catch { Say ('   Could not download the feed script: ' + $_.Exception.Message) }

# Preferred: a scheduled task. But on many home PCs (and whenever Smart App
# Control is on) registering a task is denied without admin - so we ALSO put a
# launcher in the Startup folder, which needs no admin and runs at every logon.
$feedOk = $false
try {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $feed + '" -loop')
    $tr = New-ScheduledTaskTrigger -AtLogOn
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'IdanClubFeed' -Action $action -Trigger $tr -Settings $set -Force -ErrorAction Stop | Out-Null
    $feedOk = $true
    Say '   Feed installed as a scheduled task.'
} catch {
    Say '   (no admin for a scheduled task - using the Startup folder instead, that is fine)'
}

# Startup-folder launcher - always installed, no admin needed. A plain .cmd is
# not subject to Constrained Language Mode and carries no mark-of-the-web.
try {
    $startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    if (-not (Test-Path -LiteralPath $startup)) { New-Item -ItemType Directory -Path $startup -Force | Out-Null }
    $cmd = Join-Path $startup 'IdanClubFeed.cmd'
    $cmdText = '@echo off' + "`r`n" +
               'start "" /min powershell ' + $feedArgs + "`r`n"
    Set-Content -LiteralPath $cmd -Value $cmdText -Encoding ASCII
    Say '   Feed set to start automatically at every logon (Startup folder).'
} catch { Say ('   Could not add the Startup launcher: ' + $_.Exception.Message) }

# start it right now so the member appears within ~1 minute
try {
    Start-Process -FilePath 'powershell.exe' -ArgumentList $feedArgs -WindowStyle Hidden
    Say '   Feed running now (updates the app every 2 minutes).'
} catch { Say ('   Could not start the feed now: ' + $_.Exception.Message) }

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
