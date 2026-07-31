#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Builds the four TradingView watchlist import files from the live engine data.
Run:  python tools/build_watchlists.py
Reads:  engine/universe.json , data/state.json
Writes: watchlists/1-engine.txt .. 4-premium.txt , watchlists/manifest.json
Pure stdlib. Safe to run on GitHub Actions.
"""
import json, os, datetime

NL = chr(10)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT  = os.path.join(ROOT, "watchlists")

GOLD_TV = "OANDA:XAUUSD"

# Exchange map — keeps TradingView from resolving a ticker to the wrong listing.
EXCH = {
 "SNAP":"NYSE","NOK":"NYSE","BB":"NYSE","ERIC":"NASDAQ","GRAB":"NASDAQ","LUMN":"NYSE",
 "INFY":"NYSE","PATH":"NYSE","VTRS":"NASDAQ","OGN":"NYSE","NTLA":"NASDAQ","SRPT":"NASDAQ",
 "TDOC":"NYSE","TNDM":"NASDAQ","NVAX":"NASDAQ","NEO":"NASDAQ","CLOV":"NASDAQ","AMRX":"NASDAQ",
 "SOFI":"NASDAQ","NU":"NYSE","SAN":"NYSE","ITUB":"NYSE","BBD":"NYSE","HBAN":"NASDAQ",
 "FLG":"NYSE","RIG":"NYSE","PTEN":"NASDAQ","KOS":"NYSE","TALO":"NYSE","RUN":"NASDAQ",
 "FLNC":"NASDAQ","NXE":"NYSE","PLUG":"NASDAQ","AAL":"NASDAQ","LYFT":"NASDAQ","JBLU":"NASDAQ",
 "SHLS":"NASDAQ","ARRY":"NASDAQ","ULCC":"NASDAQ","F":"NYSE","KVUE":"NYSE","KSS":"NYSE",
 "AEO":"NYSE","CAG":"NYSE","WEN":"NASDAQ","GT":"NASDAQ","UAA":"NYSE","STLA":"NYSE",
 "RDW":"NYSE","LUNR":"NASDAQ","YSS":"NYSE","SPCE":"NYSE","SATL":"NASDAQ","AUR":"NASDAQ",
 "SOUN":"NASDAQ","BBAI":"NYSE","RXRX":"NASDAQ","AI":"NYSE","PONY":"NASDAQ","NVTS":"NASDAQ",
 "HIMX":"NASDAQ","INDI":"NASDAQ","RIVN":"NASDAQ","LCID":"NASDAQ","NIO":"NYSE","XPEV":"NYSE",
 "QS":"NASDAQ","LI":"NASDAQ","ENVX":"NASDAQ","SBS":"NYSE",
 "NVDA":"NASDAQ","MSFT":"NASDAQ","ORCL":"NYSE","PLTR":"NASDAQ","CRWD":"NASDAQ","LLY":"NYSE",
 "JNJ":"NYSE","UNH":"NYSE","MRK":"NYSE","ABBV":"NYSE","V":"NYSE","MA":"NYSE","JPM":"NYSE",
 "BAC":"NYSE","GS":"NYSE","XOM":"NYSE","CVX":"NYSE","COP":"NYSE","SLB":"NYSE","CCJ":"NYSE",
 "CAT":"NYSE","DE":"NYSE","LMT":"NYSE","BA":"NYSE","RTX":"NYSE","MCD":"NYSE","TGT":"NYSE",
 "SBUX":"NASDAQ","KO":"NYSE","NKE":"NYSE","RKLB":"NASDAQ","ASTS":"NASDAQ","PL":"NYSE",
 "IRDM":"NASDAQ","KTOS":"NASDAQ","CRWV":"NASDAQ","NBIS":"NASDAQ","SNOW":"NYSE","TSM":"NYSE",
 "AVGO":"NASDAQ","AMD":"NASDAQ","MU":"NASDAQ","TSLA":"NASDAQ","ALB":"NYSE","SQM":"NYSE",
 "IIPR":"NYSE","SMG":"NYSE","JAZZ":"NASDAQ","AWK":"NYSE","XYL":"NYSE","VLTO":"NYSE",
 "ECL":"NYSE","WTRG":"NYSE",
}

SEC_HE = {
 "tech":"💻 טכנולוגיה",
 "health":"🧬 בריאות",
 "fintech":"🏦 פינטק",
 "energy":"🛢 אנרגיה",
 "cleanenergy":"☀ אנרגיה נקייה",
 "travel":"✈ תעופה ונסיעות",
 "consumer":"🛒 צריכה",
 "space":"🚀 חלל",
 "ai":"🤖 בינה מלאכותית",
 "semis":"🔌 שבבים",
 "ev":"🔋 רכב חשמלי",
 "utilities":"💧 תשתיות",
}

PREMIUM_GROUPS = [
 ("💻 מגה-טכ וענן", ["NVDA","MSFT","ORCL","PLTR","CRWD","CRWV","NBIS","SNOW"]),
 ("🔌 שבבים", ["TSM","AVGO","AMD","MU"]),
 ("🧬 בריאות", ["LLY","JNJ","UNH","MRK","ABBV","JAZZ"]),
 ("🏦 פיננסים", ["V","MA","JPM","BAC","GS"]),
 ("🛢 אנרגיה ומשאבים", ["XOM","CVX","COP","SLB","CCJ"]),
 ("🏭 תעשייה וביטחון", ["CAT","DE","LMT","BA","RTX","KTOS"]),
 ("🛒 צריכה", ["MCD","TGT","SBUX","KO","NKE"]),
 ("🚀 חלל ולוויינים", ["RKLB","ASTS","PL","IRDM"]),
 ("🔋 ליתיום ורכב", ["TSLA","ALB","SQM"]),
 ("🌱 קנביס נדלן", ["IIPR","SMG"]),
 ("💧 מים וסביבה", ["AWK","XYL","VLTO","ECL","WTRG"]),
]


def sym(t):
    e = EXCH.get(t)
    return "{}:{}".format(e, t) if e else t


def block(title, tickers):
    tickers = [t for t in tickers if t]
    if not tickers:
        return ""
    lines = ["###" + title]
    lines += [sym(t) for t in tickers]
    return NL.join(lines) + NL


def dedupe(body):
    """TradingView rejects a list containing the same symbol twice (422 duplicated_symbols)."""
    seen, out, dropped = set(), [], []
    for line in body.splitlines():
        if line.startswith("###") or not line:
            out.append(line)
            continue
        if line in seen:
            dropped.append(line)
            continue
        seen.add(line)
        out.append(line)
    if dropped:
        print("   dropped duplicates: " + ", ".join(dropped))
    return NL.join(out) + NL


def write(name, body, manifest):
    body = dedupe(body)
    path = os.path.join(OUT, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(body)
    n = len([l for l in body.splitlines() if l and not l.startswith("###")])
    manifest[name] = {"symbols": n,
                      "sections": len([l for l in body.splitlines() if l.startswith("###")])}
    print("{:16s} {:3d} symbols".format(name, n))


def main():
    os.makedirs(OUT, exist_ok=True)
    uni = json.load(open(os.path.join(ROOT, "engine", "universe.json"), encoding="utf-8"))
    try:
        st = json.load(open(os.path.join(ROOT, "data", "state.json"), encoding="utf-8"))
    except Exception:
        st = {}

    sectors = uni["sectors"]
    day     = uni["day_focus"]
    swing   = [t for arr in sectors.values() for t in arr]
    premium = uni["premium_watch_only"]
    manifest = {}

    # ---- 1. by engine ----
    b  = block("🥇 זהב — מטה-טריידר", [GOLD_TV])
    b += block("⚡ דיי-טרייד (נייר בלבד)", day)
    b += block("📅 סווינג", [t for t in swing if t not in day])
    write("1-engine.txt", b, manifest)

    # ---- 2. by sector ----
    b = block("🥇 זהב", [GOLD_TV])
    for k, arr in sectors.items():
        b += block(SEC_HE.get(k, k) + " · " + str(len(arr)), arr)
    write("2-sector.txt", b, manifest)

    # ---- 3. by live status ----
    uv   = {x["t"]: x for x in st.get("universe_view", [])}
    pos  = [p["ticker"] for p in st.get("positions", []) if p.get("kind") != "gold"]
    goldpos = [p for p in st.get("positions", []) if p.get("kind") == "gold"]
    sig  = st.get("signals", {}) or {}
    live = []
    for key in ("swing", "day"):
        for s in (sig.get(key) or []):
            t = s.get("ticker")
            if t and str(s.get("state", "")).endswith("_NOW") and t not in live:
                live.append(t)
    watch = []
    for key in ("swing", "day"):
        for s in (sig.get(key) or []):
            t = s.get("ticker")
            if t and t not in live and t not in watch:
                watch.append(t)
    for t, x in uv.items():
        if x.get("state") == "watch" and t not in watch and t not in live:
            watch.append(t)
    rest = [t for t in swing if t not in pos + live + watch]

    gold_title = "🥇 זהב"
    if goldpos:
        gold_title += " · פוזיציה פתוחה"
    b  = block(gold_title, [GOLD_TV])
    b += block("💼 בפוזיציה · " + str(len(pos)), pos)
    b += block("🎯 איתות חי · " + str(len(live)), live)
    b += block("👁 לקראת פריצה · " + str(len(watch)), watch)
    b += block("⚪ שקט · " + str(len(rest)), rest)
    write("3-status.txt", b, manifest)

    # ---- 4. premium + Ido, watch only ----
    b = ""
    grouped = set()
    for title, arr in PREMIUM_GROUPS:
        arr = [t for t in arr if t in premium]
        grouped |= set(arr)
        b += block(title, arr)
    leftover = [t for t in premium if t not in grouped]
    b += block("📦 נוספים", leftover)
    for lst in uni.get("ido_lists", []):
        for grp, arr in lst.get("groups", {}).items():
            b += block("{} {} · {}".format(lst.get("icon", ""), lst.get("name", ""), grp), arr)
    write("4-premium.txt", b, manifest)

    manifest["_built_utc"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    manifest["_gold_symbol"] = GOLD_TV
    with open(os.path.join(OUT, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    print("manifest written")


if __name__ == "__main__":
    main()
