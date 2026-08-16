#!/bin/bash
# =====================================================================
#  Idans Money Club - setup for macOS
#  Installs the club's gold bot into the member's own MetaTrader 5 DEMO
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
say "        Idans Money Club  -  Gold Bot setup (macOS)"
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
if curl -fsSL "$BASEURL/IdanGold.ex5" -o "$EXPERTS/IdanGold.ex5"; then
  say "   Bot installed (ready-to-run build, nothing to compile)."
else
  say "   Could not download the bot. Check your internet and run this again."
  exit 1
fi

FILESDIR="$MQL5/Files/IdanGold"
mkdir -p "$FILESDIR"
cat > "$FILESDIR/params.json" <<'PARAMS'
{ "version":36,"enabled":true,"risk_pct":5.0,"h1_fast":34,"h1_slow":89,
"ema_fast":20,"ema_slow":600,"atr_period":14,"sl_atr":1.0,"tp1_r":1.5,"tp2_r":5.0,
"tp1_close_frac":0.0,"be_at_r":0.5,"trail_atr":2.0,"max_spread_frac":0.1,
"atr_min_points":60.0,"atr_max_points":1600,"max_trades_day":999,
"daily_loss_stop_pct":6.0,"max_consec_losses":3,"cooldown_bars":8,"tf_minutes":15,
"lock_at_r":0.3,"lock_give_r":0.15,"fixed_lots":0.0,"max_stake_pct":9.0,
"entry_mode":1,"burst_bars":4,"burst_atr":2.0,"risk_mode":1,
"rp_peak":5.0,"rp_norm":4.0,"rp_dd1":2.5,"rp_dd2":1.5,"dd1_pct":15.0,"dd2_pct":30.0 }
PARAMS
say "   Settings written (same as Idans: burst entry, risk ladder 3-9%)."

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
say "  2) From the Navigator on the left, drag 'IdanGold' onto"
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
