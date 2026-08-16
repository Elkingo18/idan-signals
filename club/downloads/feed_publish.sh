#!/bin/bash
# Idans Money Club - feed publisher for macOS.
# Reads the member's own MetaTrader status.json (written by the gold bot)
# and posts a small snapshot so their own stack shows in the app.
# Demo data only. Read-only: it never places or changes an order.
ROOT="$HOME/IdanClub"
LOG="$ROOT/feed.log"
say(){ printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG" 2>/dev/null; }

PROJECT="idan-money-club"
APIKEY="AIzaSyA0n2xr_xomM8L_Usqrq_qFHb-ZliDAN5M"

KEYFILE="$ROOT/feed.txt"
[ -f "$KEYFILE" ] || { say "no feed.txt - run the setup first"; exit 1; }
KEY=$(tr -d '[:space:]' < "$KEYFILE")
[ ${#KEY} -ge 24 ] || { say "feed key too short"; exit 1; }

# newest status.json the gold bot has written
STATUS=""
while IFS= read -r f; do STATUS="$f"; break; done < <(
  find "$HOME/Library/Application Support" -maxdepth 14 -type f -path "*/MQL5/Files/IdanGold/status.json" 2>/dev/null |
  while IFS= read -r p; do printf '%s %s\n' "$(stat -f '%m' "$p" 2>/dev/null || echo 0)" "$p"; done |
  sort -rn | head -1 | cut -d' ' -f2-)

[ -n "$STATUS" ] || { say "no status.json yet - is the bot on a chart with algo trading on?"; exit 0; }

num(){ grep -o "\"$1\"[[:space:]]*:[[:space:]]*-\{0,1\}[0-9.]*" "$STATUS" | head -1 | sed 's/.*: *//'; }
bool(){ grep -o "\"$1\"[[:space:]]*:[[:space:]]*[a-z]*" "$STATUS" | head -1 | sed 's/.*: *//'; }

ACCOUNT=$(num account); BALANCE=$(num balance); EQUITY=$(num equity)
DAYPNL=$(num day_pnl); TRADES=$(num trades_today); PV=$(num params_version)
ENABLED=$(bool enabled)
[ -n "$BALANCE" ] || { say "could not read balance from status.json"; exit 0; }
[ -n "$EQUITY" ] || EQUITY="$BALANCE"
[ -n "$DAYPNL" ] || DAYPNL=0
[ -n "$TRADES" ] || TRADES=0
[ "$ENABLED" = "false" ] && ENABLED=false || ENABLED=true

COMPACT="{\"account\":${ACCOUNT:-0},\"balance\":$BALANCE,\"equity\":$EQUITY,\"day_pnl\":$DAYPNL,\"trades_today\":$TRADES,\"enabled\":$ENABLED,\"params_version\":${PV:-0}}"
ESCAPED=$(printf '%s' "$COMPACT" | sed 's/"/\\"/g')
NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

BODY="{\"fields\":{\"j\":{\"stringValue\":\"$ESCAPED\"},\"t\":{\"stringValue\":\"$NOW\"},\"acct\":{\"stringValue\":\"${ACCOUNT:-0}\"},\"v\":{\"integerValue\":\"1\"}}}"
URL="https://firestore.googleapis.com/v1/projects/$PROJECT/databases/(default)/documents/feeds/$KEY?key=$APIKEY"

CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "$URL" -H 'Content-Type: application/json' -d "$BODY")
if [ "$CODE" = "200" ]; then say "posted equity=$EQUITY day=$DAYPNL"; else say "post failed http=$CODE"; fi
