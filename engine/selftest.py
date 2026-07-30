#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Offline self-test: synthetic bars, monkey-patched data layer, 12 simulated ticks.
Verifies indicators, signal logic, risk governor, ledger math, T1/BE/trail/stop,
calendar, XP/levels/badges and the period summary — with NO network."""
import json, math, os, random, sys
from datetime import datetime, timedelta
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import engine as E

random.seed(7)
FAIL = []
def ck(name, cond, extra=""):
    print(("  ✅ " if cond else "  ❌ ") + name + (f"  {extra}" if extra else ""))
    if not cond: FAIL.append(name)

# ---------------- indicator unit tests ----------------
print("\n== indicators ==")
ck("sma", abs(E.sma([1,2,3,4,5],5)-3.0) < 1e-9)
e = E.ema_series([10]*30, 9)
ck("ema flat -> flat", abs(e[-1]-10) < 1e-9)
ck("ema seeded at n-1", e[7] is None and e[8] is not None)
ck("rsi all-up = 100", E.wilder_rsi([i for i in range(1,40)],14) > 99)
ck("rsi all-down ~0", E.wilder_rsi([40-i for i in range(39)],14) < 1)
h=[10,10.5,11,11.5,12.5,11.5,11,10.5,10,9.5,10,10.5,11,11.5]
l=[ 9, 9.5,10,10.5,11.5,10.5,10, 9.5, 8.5, 9, 9.5,10,10.5,11]
ph,pl = E.confirmed_pivots(h,l,3,3)
ck("pivot high found (centered, right-confirmed)", ph == 12.5, f"ph={ph}")
ck("pivot low found",  pl == 8.5,  f"pl={pl}")
ck("pivot not visible until 'right' bars later",
   E.confirmed_pivots(h[:6],l[:6],3,3) == (None,None))
bars=[{"h":10,"l":9,"c":9.5,"v":100},{"h":11,"l":10,"c":10.5,"v":300}]
vw=E.session_vwap(bars)
ck("session vwap weighted", 10.2 < vw < 10.4, f"{vw:.3f}")
ck("vwap ignores other sessions (len-sensitive by design)", abs(E.session_vwap(bars[:1])-9.5) < 1e-9)

print("\n== sizing ==")
ck("size floors, respects risk", E.size_stock(10.0, 9.0, 1000, 40) == 40)
ck("size capped by cash", E.size_stock(10.0, 9.9, 1000, 40) == 95)
ck("size 0 on bad stop", E.size_stock(10, 10, 1000, 40) == 0)
gcfg={"leverage":20,"max_margin_frac_of_wallet":0.35,"tick":0.1}
oz=E.size_gold(4000, 3990, 1000, 1000, 40, gcfg)
ck("gold sized by margin cap not risk", abs(oz-1.75) < 0.02, f"{oz} oz  margin=${oz*4000/20:.0f}")
ck("gold risk<=cap", oz*10 <= 40+1e-6, f"risk=${oz*10:.2f}")

# ---------------- synthetic market ----------------
def mk_daily(n=200, start=8.0, drift=0.0016, vol=0.02, breakout_at=None):
    bars=[]; px=start; d=datetime(2026,1,2)
    for i in range(n):
        r = random.gauss(drift, vol)
        if breakout_at and i == breakout_at: r = 0.075
        o=px; px=max(0.6, px*(1+r))
        hi=max(o,px)*(1+abs(random.gauss(0,0.006))); lo=min(o,px)*(1-abs(random.gauss(0,0.006)))
        v=1_500_000*(3.2 if (breakout_at and i==breakout_at) else random.uniform(0.7,1.25))
        bars.append({"t":(d+timedelta(days=i)).strftime("%Y-%m-%d"),
                     "o":round(o,3),"h":round(hi,3),"l":round(lo,3),"c":round(px,3),"v":v})
    return bars

def mk_intra(day="2026-07-29", n=60, start=4000.0, up=True):
    bars=[]; px=start
    for i in range(n):
        r = random.gauss(0.0009 if up else -0.0009, 0.0016)
        o=px; px=px*(1+r)
        bars.append({"t":f"{day}T{9+i//12:02d}:{(i%12)*5:02d}:00","d":day,
                     "hm":f"{(570+i*5)//60:02d}:{(570+i*5)%60:02d}",
                     "o":o,"h":max(o,px)*1.0006,"l":min(o,px)*0.9994,"c":px,
                     "v":900*random.uniform(0.6,1.6)})
    return bars


def mk_breakout(start=6.0, res_px=10.0, sup_px=8.6):
    """Deterministic tape: uptrend -> pivot high at res_px -> consolidation ->
    fresh breakout on the LAST bar with 3x volume. Exactly what the rule wants."""
    bars=[]; d=datetime(2026,1,2); i=0
    def add(o,h,l,c,v):
        nonlocal i
        bars.append({"t":(d+timedelta(days=i)).strftime("%Y-%m-%d"),
                     "o":o,"h":h,"l":l,"c":c,"v":v}); i+=1
    px=start
    for _ in range(70):                       # base uptrend
        px*=1.006; add(px*0.997, px*1.012, px*0.988, px, 1_400_000)
    for _ in range(6):                        # push into the pivot high
        px*=1.012; add(px*0.997, px*1.010, px*0.990, px, 1_600_000)
    add(res_px*0.99, res_px, res_px*0.965, res_px*0.972, 2_100_000)   # THE pivot high
    px=res_px*0.972
    for _ in range(5):                        # pull back to the pivot low
        px*=0.985; add(px*1.004, px*1.008, px*0.992, px, 1_300_000)
    add(sup_px*1.01, sup_px*1.02, sup_px, sup_px*1.012, 1_500_000)    # THE pivot low
    px=sup_px*1.012
    for _ in range(14):                       # consolidate UNDER the pivot high
        px=min(res_px*0.985, px*1.006)
        add(px*0.998, px*1.006, px*0.993, px, 1_450_000)
    add(res_px*0.985, res_px*1.045, res_px*0.98, res_px*1.038, 4_600_000)  # breakout
    return bars

print("\n== strategy: swing ==")
scfg = E.CFG["swing"]
bars = mk_breakout()
sig = E.swing_signal("TEST", bars, scfg, 40, 1000, 1000, 0.35)
ck("swing produced a signal on engineered breakout", sig is not None)
if sig:
    ck("entry>stop", sig["entry"] > sig["stop"])
    ck("t1>entry and t2>entry", sig["t1"] > sig["entry"] and sig["t2"] > sig["entry"])
    ck("stop_pct within guardrails", 1.2 <= sig["stop_pct"] <= 12, f'{sig["stop_pct"]}%')
    ck("R:R at T1 >= 1.5 by construction", sig["rr1"] >= 1.5, sig["rr1"])
    ck("notional capped at 35% of equity", sig["notional"] <= 351, f'${sig["notional"]}')
    ck("actual risk reported and <= 4%", sig["risk_pct_actual"] <= 4.01, f'{sig["risk_pct_actual"]}%')
    ck("shares > 0", sig["shares"] > 0, f'{sig["shares"]} sh')
    ck("risk of the sized position <= 4% of wallet",
       abs(sig["entry"]-sig["stop"])*sig["shares"] <= 40.5,
       f'${abs(sig["entry"]-sig["stop"])*sig["shares"]:.2f}')
    sc = E.score(sig, True)
    ck("score is not pinned at 96+ (audit fix)", sc < 95, f"score={sc}")
flat = mk_daily(200, 8.0, 0.0, 0.004)
fs = E.swing_signal("FLAT", flat, scfg, 40, 1000, 1000, 0.35)
ck("no BUY_NOW on a flat tape (watch is fine)",
   fs is None or fs["state"] != "BUY_NOW", fs and fs["state"])
exp = mk_breakout(start=20.0, res_px=30.0, sup_px=26.0)
ck("price>$20 rejected by universe rule", E.swing_signal("EXP", exp, scfg, 40, 1000, 1000, 0.35) is None)

print("\n== strategy: gold (two-sided, multi-pattern) ==")
g = mk_intra(n=120, start=4000, up=True)
gl = E.gold_signals(g, E.CFG["gold"], 1000, 1000, 40)
ck("gold long candidate in an uptrend", any(x["side"]=="long" for x in gl), [x.get("pattern") for x in gl])
if gl:
    gs = [x for x in gl if x["side"]=="long"][0]
    ck("gold long stop below entry", gs["stop"] < gs["entry"])
    ck("gold margin <= 35% wallet", gs["margin"] <= 350.5, f'${gs["margin"]}')
    ck("gold oz floored to 0.01", abs(gs["ounces"]*100 - round(gs["ounces"]*100)) < 1e-6)
    ck("gold has a pattern name", bool(gs.get("pattern")))
gd = mk_intra(n=120, start=4000, up=False)
gsl = E.gold_signals(gd, E.CFG["gold"], 1000, 1000, 40)
ck("gold SHORT candidate in a downtrend", any(x["side"]=="short" for x in gsl),
   [x.get("pattern") for x in gsl])
if any(x["side"]=="short" for x in gsl):
    sh = [x for x in gsl if x["side"]=="short"][0]
    ck("short stop ABOVE entry", sh["stop"] > sh["entry"])
    ck("short targets BELOW entry", sh["t1"] < sh["entry"] and sh["t2"] < sh["t1"])

print("\n== risk governor ==")
st = E.fresh_state(); st["calendar"]={}; st["game"]={"xp":0,"level":1,"streak":0,"best_streak":0,"badges":[],"quests":[],"boss":{}}
gov = E.CFG["governor"]
base = {"kind":"swing","ticker":"SOFI","side":"long","state":"BUY_NOW","entry":10.0,
        "stop":9.0,"t1":13.0,"t2":14.0,"rr1":3.0,"shares":40,"score":80}
ok,why = E.governor_check(st, base, gov, 40)
ck("clean signal passes", ok, why)
ck("rr below 1.5 blocked", not E.governor_check(st, {**base,"rr1":1.0}, gov, 40)[0])
ck("WATCH blocked", not E.governor_check(st, {**base,"state":"WATCH_BUY"}, gov, 40)[0])
ck("short blocked (cash account)", not E.governor_check(st, {**base,"side":"short"}, gov, 40)[0])
ck("rejects list blocks", not E.governor_check(st, {**base,"rejects":["early_session"]}, gov, 40)[0])
st["halts"]["daily_stop_hit"]=True
ck("daily stop halts everything", not E.governor_check(st, base, gov, 40)[0])
st["halts"]["daily_stop_hit"]=False
st["control"]={"halt":True,"close_all":False}
ok,why = E.governor_check(st, base, gov, 40)
ck("🛑 emergency halt blocks new positions", not ok, why)
st["control"]={"halt":False,"close_all":False}
now = datetime.now(E.IL)
E.open_position(st, base, now, E.CFG["costs"], 40)
ck("position opened", len(st["positions"])==1)
ok,why = E.governor_check(st, {**base,"ticker":"NU"}, gov, 40)
ck("2nd trade in same sector ALLOWED (cap raised to 2)", ok, why)
ok,why = E.governor_check(st, {**base,"ticker":"SNAP"}, gov, 40)
ck("different sector allowed", ok, why)
# REALITY CHECK: at 4% risk with a 10% stop, one position is ~40% of a $1000
# wallet, so the CASH runs out before the position limit does. That is correct.
E.open_position(st, {**base,"ticker":"SNAP"}, now, E.CFG["costs"], 40)
ck("3rd full-size position refused for lack of cash (not a bug — a $1000 reality)",
   E.open_position(st, {**base,"ticker":"RIVN"}, now, E.CFG["costs"], 40) is None,
   f'cash ${st["wallet"]["cash"]:.2f}')
E.open_position(st, {**base,"ticker":"NU","shares":8}, now, E.CFG["costs"], 8)
ok,why = E.governor_check(st, {**base,"ticker":"ITUB","shares":5}, gov, 5)
ck("3rd fintech blocked (sector cap 2)", (not ok) and why.startswith("sector_cap"), why)
E.open_position(st, {**base,"ticker":"RIVN","shares":8}, now, E.CFG["costs"], 8)
ck("4 stock positions open (= new max)", len(st["positions"])==4, len(st["positions"]))
ok,why = E.governor_check(st, {**base,"ticker":"PLUG","shares":5}, gov, 5)
ck("5th stock blocked (max 4)", not ok, why)
gold_long = {"kind":"gold","ticker":"XAUUSD","side":"long","state":"BUY_NOW","pattern":"חציית ממוצעים ↑",
             "entry":4000.0,"stop":3986.0,"t1":4021.0,"t2":4042.0,"rr1":1.5,"shares":0.5,
             "score":70,"margin":100.0}
ok,why = E.governor_check(st, gold_long, gov, 7)
ck("🥇 gold NOT counted in stock caps — passes with 4 stocks open", ok, why)
ck("config is self-consistent: 4 stocks x 2% + gold 4% <= heat cap",
   gov["max_open_positions"]*E.CFG["risk_pct_stocks"] + gov["max_gold_positions"]*E.CFG["risk_pct_gold"]
   <= gov["max_total_open_heat_pct"]+1e-9)
heat = sum(p["risk_open"] for p in st["positions"])
ck("total open heat <= 14% of equity", heat <= st["wallet"]["equity"]*gov["max_total_open_heat_pct"]+0.01, f"${heat:.2f}")

print("\n== ledger: T1 half-off -> breakeven -> trail -> exit ==")
st2 = E.fresh_state()
E.open_position(st2, base, now, E.CFG["costs"], 40)
p = st2["positions"][0]
cash0 = st2["wallet"]["cash"]
ck("cash reduced by cost+fee", cash0 < 1000-40*10, f"${cash0:.2f}")
ck("fill worse than signal price (slippage charged)", p["entry"] > 10.0, f'{p["entry"]}')
E.manage_positions(st2, {"SOFI":13.2}, now, E.CFG["costs"])   # hits T1
p = st2["positions"][0]
ck("half sold at T1", p["qty_left"]==20, f'left {p["qty_left"]}')
ck("stop never below breakeven after T1", p["stop"] >= p["entry"]-1e-9, f'stop {p["stop"]} entry {p["entry"]}')
ck("be_moved flag set", p["be_moved"] is True)
ck("realized P/L booked", st2["wallet"]["realized_pnl"]>0, f'${st2["wallet"]["realized_pnl"]}')
E.manage_positions(st2, {"SOFI":13.6}, now, E.CFG["costs"])   # trail
ck("stop trailed up", st2["positions"][0]["stop"] > p["entry"], f'{st2["positions"][0]["stop"]}')
E.manage_positions(st2, {"SOFI":14.5}, now, E.CFG["costs"])   # T2
ck("closed at T2", len(st2["positions"])==0)
E.mark_to_market(st2)
ck("equity > start after a 3R winner", st2["wallet"]["equity"] > 1000, f'${st2["wallet"]["equity"]}')
ck("all cash returned (no leak)", abs(st2["wallet"]["equity"]-st2["wallet"]["cash"])<1e-6)

print("\n== ledger: loser stops out at exactly ~ -1R ==")
st3 = E.fresh_state()
E.open_position(st3, base, now, E.CFG["costs"], 40)
E.manage_positions(st3, {"SOFI":8.5}, now, E.CFG["costs"])
E.mark_to_market(st3)
loss = st3["wallet"]["equity"]-1000
ck("loss close to -$40 (never a runaway)", -46 < loss < -38, f"${loss:.2f}")
ck("cooldown armed after a loss", st3["cooldown"].get("SOFI",0) > 0)
ok,why = E.governor_check(st3, base, gov, 40)
ck("cooldown blocks immediate re-entry", not ok, why)

print("\n== gold shorts: governor + ledger ==")
stg = E.fresh_state()
gshort = {"kind":"gold","ticker":"XAUUSD","side":"short","state":"SELL_NOW","pattern":"חציית ממוצעים ↓",
          "entry":4000.0,"stop":4014.0,"t1":3979.0,"t2":3958.0,"rr1":1.5,"shares":2.0,
          "score":70,"margin":400.0}
ok,why = E.governor_check(stg, gshort, gov, 40)
ck("gold SELL_NOW short passes governor", ok, why)
ck("stock short still blocked",
   not E.governor_check(stg, {**base,"side":"short","state":"SELL_NOW"}, gov, 40)[0])
stg["gold_today"] = {"date": datetime.now(E.IL).strftime("%Y-%m-%d"), "count": 8}
ok,why = E.governor_check(stg, gshort, gov, 40)
ck("9th gold trade of the day blocked (daily cap 8)", not ok, why)
stg["gold_today"] = {"date": "2020-01-01", "count": 8}
ck("cap resets on a new day", E.governor_check(stg, gshort, gov, 40)[0])

E.open_position(stg, gshort, now, E.CFG["costs"], 40)
ck("short opened", len(stg["positions"])==1)
p = stg["positions"][0]
ck("short fill better-side charged (sold below mid)", p["entry"] < 4000.0, p["entry"])
ck("gold_today counter incremented", stg["gold_today"]["count"]==9 or stg["gold_today"]["count"]==1,
   stg["gold_today"])
E.manage_positions(stg, {"XAUUSD":3978.0}, now, E.CFG["costs"])     # T1 (below)
p = stg["positions"][0]
ck("short half off at T1", abs(p["qty_left"]-1.0) < 1e-9, p["qty_left"])
ck("short stop never ABOVE breakeven after T1 (trailing may improve it)",
   p["stop"] <= p["entry"]+1e-9, f'stop {p["stop"]} entry {p["entry"]}')
ck("short be_moved flag set", p["be_moved"] is True)
ck("short T1 profit booked", stg["wallet"]["realized_pnl"] > 0, stg["wallet"]["realized_pnl"])
E.manage_positions(stg, {"XAUUSD":3966.0}, now, E.CFG["costs"])     # trail down
ck("short stop trails DOWN", stg["positions"][0]["stop"] < p["entry"], stg["positions"][0]["stop"])
E.manage_positions(stg, {"XAUUSD":3957.0}, now, E.CFG["costs"])     # T2
ck("short closed at T2", len(stg["positions"])==0)
E.mark_to_market(stg)
ck("short winner grew equity", stg["wallet"]["equity"] > 1000, stg["wallet"]["equity"])
ck("no cash leak on short cycle", abs(stg["wallet"]["equity"]-stg["wallet"]["cash"])<0.011)

stg2 = E.fresh_state()
E.open_position(stg2, gshort, now, E.CFG["costs"], 40)
E.manage_positions(stg2, {"XAUUSD":4020.0}, now, E.CFG["costs"])    # stop (above)
E.mark_to_market(stg2)
sl = stg2["wallet"]["equity"]-1000
ck("short stop-out loses ~ -1R, never runaway", -34 < sl < -26, f"${sl:.2f}")

print("\n== calendar / XP / badges ==")
st4 = E.fresh_state()
today = datetime.now(E.IL); d0 = today.strftime("%Y-%m-%d")
d1 = (today-timedelta(days=1)).strftime("%Y-%m-%d")
d2 = (today-timedelta(days=2)).strftime("%Y-%m-%d")
st4["closed"] = [
  {"ticker":"SOFI","kind":"swing","qty":40,"entry":10,"exit":13,"pnl":118.0,"r":2.95,"reason":"T2","day":d2,"opened":d2,"closed":d2,"followed_rules":True},
  {"ticker":"SNAP","kind":"swing","qty":20,"entry":9,"exit":8.5,"pnl":-41.0,"r":-1.0,"reason":"stop","day":d1,"opened":d1,"closed":d1,"followed_rules":True},
  {"ticker":"AAL","kind":"swing","qty":30,"entry":12,"exit":13,"pnl":29.0,"r":1.4,"reason":"T1_half","day":d0,"opened":d0,"closed":d0,"followed_rules":True},
]
st4["wallet"]["equity"]=1106.0; st4["wallet"]["peak_equity"]=1130.0
E.rebuild_calendar_and_game(st4)
cal = st4["calendar"]
ck("3 calendar days built", len(cal)==3, list(cal.keys()))
ck("green day marked green", cal[d2]["status"]=="green")
ck("red day marked red",     cal[d1]["status"]=="red")
ck("discipline 100 when rules followed", cal[d0]["discipline"]==100)
ck("XP accumulated", st4["game"]["xp"] > 0, st4["game"]["xp"])
ck("level >= 1 with a name", st4["game"]["level"]>=1 and st4["game"]["level_name"])
ck("badge first_win earned", any(b["id"]=="first_win" and b["earned"] for b in st4["game"]["badges"]))
ck("badge k1100 earned at peak 1130", any(b["id"]=="k1100" and b["earned"] for b in st4["game"]["badges"]))
ck("badge k2000 NOT earned", not any(b["id"]=="k2000" and b["earned"] for b in st4["game"]["badges"]))
b4=st4["game"]["boss"]
ck("DAILY boss: target=8% and legend=20% of day-open equity",
   abs(b4["target"]-b4["base"]*0.08)<0.01 and abs(b4["legend"]-b4["base"]*0.20)<0.01, b4)
per = st4["periods"]
ck("period summary day/week/month present", all(k in per for k in ("day","week","month","quarter","half","year")))
ck("week P/L sums the 3 days", abs(per["week"]-106.0)<0.01, per["week"])
E.check_halts(st4)
ck("halts computed", "daily_limit" in st4["halts"], st4["halts"])
stt = E.compute_stats(st4)
ck("stats: 3 trades, PF>1", stt["trades"]==3 and stt["pf"]>1, stt)

print("\n== full main() loop with patched data (12 ticks, no network) ==")
E.STATE_F = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "state_test.json")
if os.path.exists(E.STATE_F): os.remove(E.STATE_F)
UNIV = [t for sec in E.UNI["sectors"].values() for t in sec][:24]
STORE = {tk: mk_daily(200, random.uniform(3,18), random.gauss(0.0014,0.0008), 0.02,
                      breakout_at=random.choice([None,190,193,196])) for tk in UNIV}
STORE["SPY"] = mk_daily(200, 500, 0.0006, 0.008)
def fake_daily(tks, period="8mo"): return {t:STORE[t] for t in tks if t in STORE}
def fake_intra(tks, interval="5m", period="5d"):
    return {t: mk_intra(n=110, start=(4000 if "GC" in t else 10), up=True) for t in tks}
E.fetch_daily, E.fetch_intraday = fake_daily, fake_intra
UNIV_ORDER = [t for t in UNIV]
for i in range(14):
    forced = UNIV_ORDER[i % len(UNIV_ORDER)]
    rp = random.uniform(9.5, 14)           # deterministic breakout shape (proven above)
    STORE[forced] = mk_breakout(start=rp*0.6, res_px=rp, sup_px=rp*0.87)
    for tk in STORE:
        if tk == forced: continue
        b = STORE[tk][-1]
        px = max(0.6, b["c"]*(1+random.gauss(0.001, 0.022)))
        STORE[tk].append({"t":b["t"],"o":b["c"],"h":max(b["c"],px)*1.004,
                          "l":min(b["c"],px)*0.996,"c":px,
                          "v":1_500_000*random.uniform(0.8,1.6)})
    E.main()
st5 = E.load_json(E.STATE_F)
ck("state file written", st5 is not None)
ck("no unhandled error", "last_error" not in st5 or not st5.get("last_error"))
ck("equity is a sane number", 300 < st5["wallet"]["equity"] < 3000, f'${st5["wallet"]["equity"]}')
n_stk = sum(1 for p in st5["positions"] if p["kind"] != "gold")
n_gld = sum(1 for p in st5["positions"] if p["kind"] == "gold")
ck("stock positions <= max (gold excluded)", n_stk<=E.CFG["governor"]["max_open_positions"], n_stk)
ck("gold positions <= max_gold", n_gld<=E.CFG["governor"]["max_gold_positions"], n_gld)
heat = sum(p["risk_open"] for p in st5["positions"])
ck("open heat within cap", heat <= st5["wallet"]["equity"]*(E.CFG["governor"]["max_total_open_heat_pct"]+0.001)+0.5, f"${heat:.2f}")
ck("cash never negative", st5["wallet"]["cash"] >= -0.01, st5["wallet"]["cash"])
ck("signals produced", sum(len(v) for v in st5["signals"].values())>0,
   {k:len(v) for k,v in st5["signals"].items()})
ck("gold signals carry side+pattern",
   all(("side" in x and "pattern" in x) for x in st5["signals"]["gold"]),
   [ (x.get("side"),x.get("pattern")) for x in st5["signals"]["gold"] ])
ck("the engine actually executed trades end-to-end",
   len(st5["closed"])+len(st5["positions"]) > 0,
   f'closed={len(st5["closed"])} open={len(st5["positions"])}')
print("   rejected reasons:", {r["why"] for r in st5.get("rejected",[])})
ck("equity curve recorded", len(st5["equity_curve"])>=1)
ck("game block complete", all(k in st5["game"] for k in ("xp","level","level_name","badges","quests","boss")))
ck("periods block complete", "periods" in st5)
ck("universe_view present with sectors", len(st5.get("universe_view",[]))>10,
   len(st5.get("universe_view",[])))
ck("agents report present (swing/day/gold/guard)",
   all(k in st5.get("agents",{}) for k in ("swing","day","gold","guard")))
ck("gold agent reports scan status", "bars" in st5["agents"]["gold"] and "scanned" in st5["agents"]["gold"],
   st5["agents"]["gold"].get("bars"))
ck("daily boss in live state", st5["game"]["boss"].get("day") is not None)
ck("control state exposed", "halt" in st5.get("control",{}))
ck("health block computed", all(k in st5.get("health",{}) for k in ("swing","gold","day")),
   {k:v.get("status") for k,v in st5.get("health",{}).items()})
ck("wallet named UHTA", st5["wallet"].get("name")=="UHTA")
cj=[t for t in st5["closed"] if t.get("snap")]
ck("journal snapshot saved on closed trades", len(cj)==len(st5["closed"]) or not st5["closed"],
   f'{len(cj)}/{len(st5["closed"])}')
worst = min([t["r"] for t in st5["closed"]], default=0)
ck("no single trade worse than -1.6R", worst > -1.7, f"{worst}R")
print(f"\n   sim result: equity=${st5['wallet']['equity']}  trades={len(st5['closed'])}  "
      f"open={len(st5['positions'])}  lvl={st5['game']['level']} {st5['game'].get('level_name')}  "
      f"xp={st5['game']['xp']}  maxDD={st5['wallet']['max_dd_pct']}%")
try: os.remove(E.STATE_F)
except Exception: pass

print("\n" + ("="*58))
if FAIL:
    print(f"❌ {len(FAIL)} FAILED:"); [print("   -", f) for f in FAIL]; sys.exit(1)
print("✅ ALL SELF-TESTS PASSED")
