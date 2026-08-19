#!/bin/bash
# =====================================================================
#  Idans Money Club - setup for macOS
#  Installs the club's black-day bot into the member's own MetaTrader 5 DEMO
#  account (the Mac build of MT5 runs inside a wine bottle) and starts
#  the feed so the member sees their own stack in the app.
#  DEMO MONEY ONLY. No passwords are asked for or stored.
# =====================================================================
BASEURL="https://elkingo18.github.io/idan-signals/club/downloads"
ROOT="$HOME/IdanClub"
mkdir -p "$ROOT"
LOG="$ROOT/setup.log"
say(){ printf '%s\n' "$1"; printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG" 2>/dev/null; }

say ""
say "============================================================"
say "        Idans Money Club  -  Black-Day Bot setup (macOS)"
say "        Demo money only. Nothing here touches real funds."
say "============================================================"
say ""

# ---------------------------------------------------------------------
# 1. connection key
# ---------------------------------------------------------------------
KEYFILE="$ROOT/feed.txt"
if [ -f "$KEYFILE" ]; then KEY=$(tr -d '[:space:]' < "$KEYFILE"); else KEY=""; fi
if [ ${#KEY} -lt 24 ]; then
  KEY="f$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 32)"
  printf '%s' "$KEY" > "$KEYFILE"
fi
say "STEP 1 of 4 - your personal connection key:"
say ""
say "        $KEY"
say ""
printf '%s' "$KEY" | pbcopy 2>/dev/null && say "   (copied to your clipboard)"
say ""

# ---------------------------------------------------------------------
# 2. find MetaTrader 5 (Mac build keeps MQL5 inside its wine bottle)
# ---------------------------------------------------------------------
say "STEP 2 of 4 - looking for MetaTrader 5 ..."
EXPERTS=""
while IFS= read -r d; do
  [ -n "$d" ] || continue
  EXPERTS="$d"
  break
done < <(find "$HOME/Library/Application Support" -maxdepth 12 -type d -path "*/MetaQuotes/Terminal/*/MQL5/Experts" 2>/dev/null | sort)

if [ -z "$EXPERTS" ]; then
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    EXPERTS="$d"; break
  done < <(find "$HOME" -maxdepth 14 -type d -path "*/MetaQuotes/Terminal/*/MQL5/Experts" 2>/dev/null | sort)
fi

if [ -z "$EXPERTS" ]; then
  say "   MetaTrader 5 was not found on this Mac."
  say "   Install the Mac version from https://www.metatrader5.com/en/download ,"
  say "   open it once and log into a DEMO account, then run this again."
  exit 0
fi
MQL5=$(dirname "$EXPERTS")
say "   Found MetaTrader here:"
say "   $MQL5"

# ---------------------------------------------------------------------
# 3. install the bot + the exact settings Idan runs
# ---------------------------------------------------------------------
say "STEP 3 of 4 - installing the bot ..."
if curl -fsSL "$BASEURL/IdanDrawerGold.ex5" -o "$EXPERTS/IdanDrawerGold.ex5"; then
  say "   Bot installed (ready-to-run build, nothing to compile)."
else
  # 19.8.2026 - this used to "exit 1" and it cost us a live install on the
  # Windows twin: the bot file was briefly missing, the script stopped, and
  # the member never reached the step that creates the feed. The bot is the
  # least urgent part of this script; the key and the feed are what connect
  # the account at all. Carry on.
  say "   Could not download the bot right now. That is NOT fatal -"
  say "   your key and your connection are set up below."
  say "   Run this installer again in a few minutes and the bot will land."
fi

# The bot ships DISARMED in its source on purpose. Arming lives in this one
# named file, which you can read and delete. Two numbers matter most:
#   InpMaxLegs=8       the deepest ladder a ~$10,000 demo can carry. The bot
#                      this one replicates ran 13 rungs on $201,000 and lost
#                      $197,000 of it in six hours on 19.8.2026.
#   InpDailyTargetUsd  the day closes itself at +$1,200 and opens nothing new.
# If your balance cannot carry 8 rungs the bot REFUSES TO START and prints
# the numbers. That refusal is the whole point of this build.
PRESETS="$MQL5/Presets"
mkdir -p "$PRESETS"
cat > "$PRESETS/drawer.set" <<'SETEOF'
InpArmed=true
InpDemoOnly=true
InpWorstDayPctCap=10.0
InpMaxLegs=8
InpDailyTargetUsd=1200.0
InpMagic=770118
SETEOF
say "   Settings written: 8 rungs max, stops the day at +\$1,200, demo only."

# ---------------------------------------------------------------------
# 4. the feed - so the member sees their own account in the app
# ---------------------------------------------------------------------
say "STEP 4 of 4 - connecting your account to the app ..."
FEED="$ROOT/feed_publish.sh"
if curl -fsSL "$BASEURL/feed_publish.sh" -o "$FEED"; then
  chmod +x "$FEED"
  PLIST="$HOME/Library/LaunchAgents/com.idanclub.feed.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.idanclub.feed</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$FEED</string></array>
  <key>StartInterval</key><integer>120</integer>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLISTEOF
  launchctl unload "$PLIST" 2>/dev/null
  launchctl load "$PLIST" 2>/dev/null && say "   Feed installed (updates the app every 2 minutes)."
  /bin/bash "$FEED" >/dev/null 2>&1 &
else
  say "   Could not install the feed - you can still use the app, ask Idan."
fi

# open the app
open "https://elkingo18.github.io/idan-signals/club/" 2>/dev/null

say ""
say "============================================================"
say "  DONE. Three small things you do by hand in MetaTrader:"
say ""
say "  1) Open a GOLD chart (XAUUSD)."
say "  2) From the Navigator on the left, drag 'IdanDrawerGold' onto"
say "     that chart and click OK."
say "  3) The 'Algo Trading' button at the top must be GREEN."
say ""
say "  Then open the app (it just opened in your browser),"
say "  sign in with Google, and in 'Connections' paste this key:"
say ""
say "        $KEY"
say ""
say "  Within ~2 minutes your own account shows up in the app."
say "============================================================"
