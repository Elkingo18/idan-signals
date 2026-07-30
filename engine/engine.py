#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Idan Signals — Autonomous Paper-Trading Engine  v3.0
====================================================
Runs on GitHub Actions (free). No LLM. No AI API. No paid service. No server.

Every tick it:
  1. loads state.json (the $1000 paper wallet + open positions + history)
  2. manages open positions (stop / T1 half-off / breakeven / trail / T2)
  3. scans for new setups (SWING daily, DAY ORB 5m, GOLD 5m)
  4. passes candidates through the RISK GOVERNOR (heat cap, sector cap, daily stop)
  5. executes on the internal paper ledger WITH realistic costs
  6. recomputes calendar day-cards, equity curve, XP/level/streak/badges
  7. writes data/state.json  ->  the web app reads it. Done.

Design rules learned from the July-2026 audit (all enforced here):
  * fills happen at the CURRENT tick price, never the signal bar's close
  * commission + slippage + gold spread are always charged
  * session VWAP resets each session (never a multi-day cumulative VWAP)
  * position size uses floor(), never round()
  * hard minimum R:R gate
  * universe price / liquidity / premium rules enforced IN CODE
  * no shorts (a $1000 cash account cannot short)
  * portfolio heat cap + per-sector cap + daily & weekly loss limits
"""

from __future__ import annotations
import json, math, os, sys, traceback
from datetime import datetime, timedelta, date, time as dtime
from zoneinfo import ZoneInfo

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENG  = os.path.join(ROOT, "engine")
DATA = os.path.join(ROOT, "data")
os.makedirs(DATA, exist_ok=True)

ET  = ZoneInfo("America/New_York")
IL  = ZoneInfo("Asia/Jerusalem")
UTC = ZoneInfo("UTC")

STATE_F = os.path.join(DATA, "state.json")
CTRL_F  = os.path.join(DATA, "control.json")
CFG_F   = os.path.join(ENG,  "config.json")
UNI_F   = os.path.join(ENG,  "universe.json")

def load_json(p, default=None):
    try:
        with open(p, "r", encoding="utf-8") as f: return json.load(f)
    except Exception:
        return default

def save_json(p, obj):
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1, default=str)
    os.replace(tmp, p)

CFG = load_json(CFG_F, {}) or {}
UNI = load_json(UNI_F, {}) or {}

# ----------------------------------------------------------------------------
# indicators
# ----------------------------------------------------------------------------
def sma(v, n):
    if len(v) < n: return None
    return sum(v[-n:]) / n

def sma_series(v, n):
    out = [None]*len(v)
    if len(v) < n: return out
    s = sum(v[:n]); out[n-1] = s/n
    for i in range(n, len(v)):
        s += v[i] - v[i-n]; out[i] = s/n
    return out

def ema_series(v, n):
    """EMA seeded with an SMA of the first n bars (no first-bar seeding bug)."""
    out = [None]*len(v)
    if len(v) < n: return out
    seed = sum(v[:n])/n
    out[n-1] = seed
    k = 2.0/(n+1.0)
    for i in range(n, len(v)):
        out[i] = v[i]*k + out[i-1]*(1-k)
    return out

def wilder_rsi(closes, n=14):
    if len(closes) < n+1: return None
    gains = losses = 0.0
    for i in range(1, n+1):
        d = closes[i]-closes[i-1]
        gains += max(d, 0.0); losses += max(-d, 0.0)
    ag, al = gains/n, losses/n
    for i in range(n+1, len(closes)):
        d = closes[i]-closes[i-1]
        ag = (ag*(n-1) + max(d, 0.0))/n
        al = (al*(n-1) + max(-d, 0.0))/n
    if al == 0: return 100.0
    rs = ag/al
    return 100.0 - 100.0/(1.0+rs)

def atr(h, l, c, n=14):
    if len(c) < n+1: return None
    trs = []
    for i in range(1, len(c)):
        trs.append(max(h[i]-l[i], abs(h[i]-c[i-1]), abs(l[i]-c[i-1])))
    a = sum(trs[:n])/n
    for i in range(n, len(trs)):
        a = (a*(n-1) + trs[i])/n
    return a

def confirmed_pivots(h, l, left=3, right=3):
    """Returns (last_pivot_high, last_pivot_low) known as of the LAST bar only."""
    ph = pl = None
    for c in range(left, len(h)-right):
        seg_h = h[c-left:c+right+1]; seg_l = l[c-left:c+right+1]
        if h[c] == max(seg_h) and seg_h.count(h[c]) == 1: ph = h[c]
        if l[c] == min(seg_l) and seg_l.count(l[c]) == 1: pl = l[c]
    return ph, pl

def session_vwap(bars):
    """VWAP over ONLY the bars handed in — caller must hand in one session."""
    pv = vv = 0.0
    for b in bars:
        tp = (b["h"]+b["l"]+b["c"])/3.0
        pv += tp*b["v"]; vv += b["v"]
    if vv <= 0:
        return bars[-1]["c"] if bars else None
    return pv/vv

def rvol_same_time(bars_today, prior_days, idx):
    """Relative volume vs the SAME bar-of-day on prior days (not vs last 20 bars)."""
    if not prior_days: return 1.0
    ref = [d[idx]["v"] for d in prior_days if len(d) > idx and d[idx]["v"] > 0]
    if not ref: return 1.0
    m = sum(ref)/len(ref)
    return (bars_today[idx]["v"]/m) if m > 0 else 1.0

# ----------------------------------------------------------------------------
# data layer (yfinance, free)
# ----------------------------------------------------------------------------
def _flat(df, tk):
    try:
        sub = df[tk] if isinstance(df.columns, object) and tk in getattr(df.columns, "levels", [[]])[0] else df
    except Exception:
        sub = df
    return sub

def fetch_daily(tickers, period="8mo"):
    """-> {ticker: [ {t,o,h,l,c,v}, ... ] } daily bars, oldest first."""
    import yfinance as yf
    out = {}
    if not tickers: return out
    try:
        df = yf.download(tickers, period=period, interval="1d",
                         group_by="ticker", auto_adjust=False,
                         progress=False, threads=True)
    except Exception as e:
        print("fetch_daily failed:", e); return out
    import pandas as pd
    for tk in tickers:
        try:
            # single-ticker downloads may still return MultiIndex columns — handle both
            sub = df[tk] if isinstance(df.columns, pd.MultiIndex) else df
            sub = sub.dropna()
            bars = []
            for ts, r in sub.iterrows():
                bars.append({"t": ts.strftime("%Y-%m-%d"),
                             "o": float(r["Open"]), "h": float(r["High"]),
                             "l": float(r["Low"]),  "c": float(r["Close"]),
                             "v": float(r["Volume"])})
            if len(bars) >= 60: out[tk] = bars
        except Exception:
            continue
    return out

def fetch_intraday(tickers, interval="5m", period="5d"):
    """-> {ticker: [bars]} with ET-localised timestamps."""
    import yfinance as yf
    out = {}
    if not tickers: return out
    try:
        df = yf.download(tickers, period=period, interval=interval,
                         group_by="ticker", auto_adjust=False,
                         progress=False, threads=True, prepost=False)
    except Exception as e:
        print("fetch_intraday failed:", e); return out
    import pandas as pd
    for tk in tickers:
        try:
            sub = df[tk] if isinstance(df.columns, pd.MultiIndex) else df
            sub = sub.dropna()
            bars = []
            for ts, r in sub.iterrows():
                t = ts.tz_convert(ET) if ts.tzinfo else ts.tz_localize(UTC).tz_convert(ET)
                bars.append({"t": t.isoformat(), "d": t.strftime("%Y-%m-%d"),
                             "hm": t.strftime("%H:%M"),
                             "o": float(r["Open"]), "h": float(r["High"]),
                             "l": float(r["Low"]),  "c": float(r["Close"]),
                             "v": float(r["Volume"])})
            if len(bars) >= 20: out[tk] = bars
        except Exception:
            continue
    return out

def split_sessions(bars, rth_only=True):
    """Group intraday bars by trading day; optionally keep 09:30-16:00 ET only."""
    days = {}
    for b in bars:
        if rth_only and not ("09:30" <= b["hm"] < "16:00"): continue
        days.setdefault(b["d"], []).append(b)
    keys = sorted(days.keys())
    return [days[k] for k in keys], keys

# ----------------------------------------------------------------------------
# sizing
# ----------------------------------------------------------------------------
def size_stock(entry, stop, cash, risk_dollars, equity=None, max_notional_frac=None):
    """Three caps, tightest wins:
       1. risk cap    -> never risk more than risk_dollars if the stop is hit
       2. notional cap -> never let ONE position eat the whole wallet (diversification)
       3. cash cap
    Cap 2 is why realised risk per trade is often BELOW the 4% setting on a small
    account: a tight stop would otherwise demand a position worth 80% of the wallet."""
    rps = abs(entry-stop)
    if rps <= 0 or entry <= 0: return 0
    caps = [risk_dollars/rps, (cash*0.95)/entry]
    if equity and max_notional_frac:
        caps.append((equity*max_notional_frac)/entry)
    sh = int(math.floor(min(caps)))               # FLOOR, never round
    return max(sh, 0)

def size_gold(entry, stop, wallet, cash, risk_dollars, gcfg):
    dist = abs(entry-stop)
    if dist <= 0: return 0.0
    by_risk = risk_dollars / dist                       # ounces
    lev     = float(gcfg.get("leverage", 20))
    max_marg = wallet * float(gcfg.get("max_margin_frac_of_wallet", 0.35))
    by_margin = (max_marg * lev) / entry
    by_cash   = (cash * 0.9 * lev) / entry
    oz = min(by_risk, by_margin, by_cash)
    oz = math.floor(oz*100)/100.0                       # FLOOR to 0.01 oz
    return max(oz, 0.0)

# ----------------------------------------------------------------------------
# strategies
# ----------------------------------------------------------------------------
def swing_signal(tk, bars, scfg, risk_dollars, cash, equity=None, max_notional_frac=None):
    c = [b["c"] for b in bars]; h = [b["h"] for b in bars]
    l = [b["l"] for b in bars]; v = [b["v"] for b in bars]
    price = c[-1]
    if not (scfg["min_price"] <= price <= scfg["max_price"]): return None
    dv = price * (sma(v, 20) or 0)
    if dv < scfg["min_dollar_volume"]: return None
    ma50 = sma(c, scfg["trend_ma_len"])
    if ma50 is None: return None
    rsi = wilder_rsi(c, scfg["rsi_len"])
    volma = sma(v, scfg["vol_ma_len"])
    if rsi is None or not volma: return None
    res, sup = confirmed_pivots(h, l, scfg["piv_len"], scfg["piv_len"])
    if res is None or sup is None: return None
    trend_up = price > ma50
    vol_ok   = (v[-1]/volma) > scfg["vol_factor"]
    broke    = c[-1] > res and c[-2] <= res
    buy_now  = broke and vol_ok and rsi > 50 and trend_up
    watch    = (not buy_now) and trend_up and rsi > 50 and 0 <= (res-price)/price <= scfg["watch_pct"]
    if not (buy_now or watch): return None

    a = atr(h, l, c, scfg.get("atr_len", 14))
    if not a: return None
    entry = price if buy_now else res
    # STOP = the TIGHTER of (structural pivot low) and (entry - 1.6*ATR).
    # Audit fix: a raw pivot-low stop is often 15-25% away, which both destroys
    # R:R and, at 4% risk, demands a position bigger than the whole wallet.
    stop = max(sup, entry - scfg.get("atr_stop_mult", 1.6)*a)
    if stop >= entry*0.995:
        stop = entry - max(a, entry*0.015)
    risk = entry-stop
    stop_pct = risk/entry*100
    if not (scfg.get("min_stop_pct",1.2) <= stop_pct <= scfg.get("max_stop_pct",12.0)):
        return None
    # targets are R-multiples (audit fix: a fixed +20% target is not an edge)
    t1 = entry + scfg.get("rr_t1", 2.0)*risk
    t2 = entry + scfg.get("rr_t2", 3.5)*risk
    room = res + (res-sup)                     # measured-move reference level
    if room < entry + scfg.get("min_room_r", 1.5)*risk: return None   # no room to run
    shares = size_stock(entry, stop, cash, risk_dollars, equity, max_notional_frac)
    real_risk = round(risk*shares, 2)
    return {"kind": "swing", "ticker": tk, "side": "long",
            "state": "BUY_NOW" if buy_now else "WATCH_BUY",
            "price": round(price, 4), "entry": round(entry, 4), "stop": round(stop, 4),
            "t1": round(t1, 4), "t2": round(t2, 4), "rr1": round(scfg.get("rr_t1",2.0), 2),
            "stop_pct": round(stop_pct, 2), "rsi": round(rsi, 1), "atr": round(a, 3),
            "room": round(room, 4), "pivot_low": round(sup, 4), "pivot_high": round(res, 4),
            "rvol": round(v[-1]/volma, 2), "above_ma50_pct": round((price/ma50-1)*100, 2),
            "shares": shares, "notional": round(shares*entry, 2),
            "risk_dollars": real_risk,
            "risk_pct_actual": round(100*real_risk/equity, 2) if equity else None,
            "stretch_target": round(entry*(1+scfg["t1_pct"]/100.0), 2)}

def day_signal(tk, sessions, dcfg, risk_dollars, cash, now_et, equity=None, max_notional_frac=None):
    if len(sessions) < 2: return None
    today = sessions[-1]; prior = sessions[:-1][-5:]
    if len(today) < dcfg["min_bars_after_open"]: return None
    orb_n = max(1, round(dcfg["orb_minutes"]/dcfg["bar_minutes"]))
    if len(today) <= orb_n: return None
    or_h = max(b["h"] for b in today[:orb_n]); or_l = min(b["l"] for b in today[:orb_n])
    price = today[-1]["c"]
    if price > dcfg["max_price"]: return None
    vw = session_vwap(today)                        # SESSION vwap, resets daily
    c = [b["c"] for b in today]
    rsi = wilder_rsi(c, dcfg["rsi_len"]) if len(c) > dcfg["rsi_len"] else None
    if rsi is None: return None                     # fixed-length RSI only
    rv = rvol_same_time(today, prior, len(today)-1)
    hm = now_et.strftime("%H:%M")
    w0, w1 = dcfg["entry_window_et"]
    in_window = w0 <= hm <= w1
    base = (price > or_h and c[-2] <= or_h and price > vw and rv > dcfg["vol_factor"] and rsi > 50)
    if not base: return None
    ext_pct = abs(price-vw)/vw*100
    rejects = []
    if len(today) < dcfg["min_bars_after_open"]: rejects.append("early_session")
    if ext_pct > dcfg["max_ext_vwap_pct"]:       rejects.append("overextended_vwap")
    if not in_window:                            rejects.append("outside_entry_window")
    entry = price; stop = or_l
    if stop >= entry: return None
    risk = entry-stop
    if risk/entry*100 > dcfg.get("max_stop_pct", 5.0): return None
    t1 = entry + risk*dcfg["rr1"]; t2 = entry + risk*dcfg["rr2"]
    return {"kind": "day", "ticker": tk, "side": "long",
            "state": "BUY_NOW" if not rejects else "WATCH_BUY",
            "price": round(price, 4), "entry": round(entry, 4), "stop": round(stop, 4),
            "t1": round(t1, 4), "t2": round(t2, 4), "rr1": dcfg["rr1"],
            "stop_pct": round(risk/entry*100, 2), "rsi": round(rsi, 1),
            "rvol": round(rv, 2), "vwap": round(vw, 4), "ext_vwap_pct": round(ext_pct, 2),
            "or_high": round(or_h, 4), "or_low": round(or_l, 4),
            "rejects": rejects, "experimental": True, "paper_only": True,
            "shares": size_stock(entry, stop, cash, risk_dollars, equity, max_notional_frac),
            "notional": round(size_stock(entry, stop, cash, risk_dollars, equity, max_notional_frac)*entry, 2),
            "risk_dollars": round(risk*size_stock(entry, stop, cash, risk_dollars, equity, max_notional_frac), 2)}

def gold_signals(bars, gcfg, wallet, cash, risk_dollars):
    """Up to one LONG and one SHORT candidate per tick, from 4 entry patterns:
    fresh EMA cross / pullback-to-wave / VWAP reclaim / range break.
    'trend continuation' with no trigger = WATCH only (never executed).
    Daily execution cap lives in the governor (max_trades_per_day)."""
    out = []
    if len(bars) < 70: return out
    last_day = bars[-1]["d"]
    sess = [b for b in bars if b["d"] == last_day]
    if len(sess) < 12: sess = bars[-80:]
    c = [b["c"] for b in bars]; h = [b["h"] for b in bars]
    l = [b["l"] for b in bars]; v = [b["v"] for b in bars]
    e9  = ema_series(c, gcfg["ema_fast"]); e21 = ema_series(c, gcfg["ema_mid"])
    e50 = ema_series(c, gcfg["ema_slow"])
    if e9[-1] is None or e21[-1] is None or e50[-1] is None: return out
    rsi = wilder_rsi(c, gcfg["rsi_len"]); a = atr(h, l, c, gcfg["atr_len"])
    if rsi is None or not a: return out
    vw = session_vwap(sess)
    vw_prev = session_vwap(sess[:-1]) if len(sess) > 1 else vw
    price = c[-1]
    volma = sma(v, 20) or 0.0
    vol_ok = volma > 0 and v[-1] > 1.3*volma
    def xup(k): return e9[-2-k] is not None and e9[-1-k] > e21[-1-k] and e9[-2-k] <= e21[-2-k]
    def xdn(k): return e9[-2-k] is not None and e9[-1-k] < e21[-1-k] and e9[-2-k] >= e21[-2-k]
    bull = e9[-1] > e21[-1] and price > e50[-1]
    bear = e9[-1] < e21[-1] and price < e50[-1]

    cands = []
    if bull and rsi > 50 and price > vw:
        if   any(xup(k) for k in range(3)):                    cands.append(("long", "חציית ממוצעים", 6))
        elif min(l[-3:]) <= e21[-1] and price > e9[-1] and price > c[-2] and 45 <= rsi <= 70:
                                                               cands.append(("long", "פולבק לגל", 5))
        elif c[-2] <= vw_prev:                                 cands.append(("long", "החזרת VWAP", 4))
        elif price > max(h[-13:-1]) and vol_ok and rsi > 52:   cands.append(("long", "פריצת טווח", 5))
        else:                                                  cands.append(("long", "המשך מגמה", 0))
    if gcfg.get("allow_short") and bear and rsi < 50 and price < vw:
        if   any(xdn(k) for k in range(3)):                    cands.append(("short", "חציית ממוצעים ↓", 6))
        elif max(h[-3:]) >= e21[-1] and price < e9[-1] and price < c[-2] and 30 <= rsi <= 55:
                                                               cands.append(("short", "פולבק לגל ↓", 5))
        elif c[-2] >= vw_prev:                                 cands.append(("short", "שבירת VWAP", 4))
        elif price < min(l[-13:-1]) and vol_ok and rsi < 48:   cands.append(("short", "שבירת טווח", 5))
        else:                                                  cands.append(("short", "המשך מגמה ↓", 0))

    tick = gcfg["tick"]; risk = gcfg["atr_stop"]*a
    for side, pat, bonus in cands:
        sgn = 1 if side == "long" else -1
        entry = price
        stop = round((entry - sgn*risk)/tick)*tick
        t1 = entry + sgn*gcfg["rr1"]*risk; t2 = entry + sgn*gcfg["rr2"]*risk
        oz = size_gold(entry, stop, wallet, cash, risk_dollars, gcfg)
        if bonus > 0:
            state = "BUY_NOW" if side == "long" else "SELL_NOW"
        else:
            state = "WATCH_BUY" if side == "long" else "WATCH_SELL"
        sig = {"kind": "gold", "ticker": gcfg["symbol"], "side": side, "state": state,
               "pattern": pat,
               "price": round(price, 2), "entry": round(entry, 2), "stop": round(stop, 2),
               "t1": round(t1, 2), "t2": round(t2, 2), "rr1": gcfg["rr1"],
               "atr": round(a, 2), "rsi": round(rsi, 1), "vwap": round(vw, 2),
               "stop_pct": round(risk/entry*100, 2),
               "ounces": oz, "notional": round(oz*entry, 2),
               "margin": round(oz*entry/gcfg["leverage"], 2),
               "risk_dollars": round(abs(entry-stop)*oz, 2),
               "shares": oz}
        sig["score"] = min(100, score(sig, True) + bonus)
        out.append(sig)
    return out

# ----------------------------------------------------------------------------
# non-collinear quality score (0-100). Rebuilt after the audit: none of these
# components is already implied by the entry condition.
# ----------------------------------------------------------------------------
def score(sig, regime_ok):
    s = 50.0
    rr = sig.get("rr1") or 0
    s += max(-12, min(24, (rr-1.5)*16))                     # real R:R edge
    sp = sig.get("stop_pct") or 0
    s += 10 if 2.5 <= sp <= 9 else (-8 if sp > 14 else -3)  # sane stop distance
    rv = sig.get("rvol") or 1
    s += 8 if rv >= 2.0 else (4 if rv >= 1.5 else -4)       # conviction of volume
    r = sig.get("rsi") or 50
    if sig.get("side") == "short":
        s += -10 if r < 22 else (6 if 32 <= r <= 45 else 0) # not exhausted (short)
    else:
        s += -10 if r > 78 else (6 if 55 <= r <= 68 else 0) # not exhausted
    s += 8 if regime_ok else -12                            # market regime (SPY>MA50)
    ext = sig.get("above_ma50_pct")
    if ext is not None: s += -8 if ext > 18 else (5 if ext < 8 else 0)
    if sig.get("rejects"): s -= 15
    return int(max(0, min(100, round(s))))

# ----------------------------------------------------------------------------
# risk governor
# ----------------------------------------------------------------------------
def sector_of(tk):
    for sec, names in UNI.get("sectors", {}).items():
        if tk in names: return sec
    return "other"

def governor_check(st, sig, g, risk_dollars):
    """-> (ok, reason)"""
    if st.get("control", {}).get("halt"): return False, "emergency_halt"
    if st["halts"]["daily_stop_hit"]:  return False, "daily_loss_limit"
    if st["halts"]["weekly_stop_hit"]: return False, "weekly_loss_limit"
    if sig["state"] not in ("BUY_NOW", "SELL_NOW"): return False, "watch_only"
    if sig.get("rejects"):             return False, ",".join(sig["rejects"])
    if sig["side"] == "short":
        gold_short_ok = sig["kind"] == "gold" and CFG.get("gold", {}).get("allow_short")
        if not (gold_short_ok or g["allow_shorts"]): return False, "shorts_disabled"
    if (sig.get("rr1") or 0) < g["min_rr_t1"]:           return False, "rr_below_min"
    if sig.get("shares", 0) <= 0:                        return False, "size_zero"
    open_pos = st["positions"]
    if len(open_pos) >= g["max_open_positions"]:         return False, "max_positions"
    if any(p["ticker"] == sig["ticker"] for p in open_pos): return False, "already_open"
    if sig["kind"] == "gold":
        if sum(1 for p in open_pos if p["kind"] == "gold") >= g["max_gold_positions"]:
            return False, "max_gold"
        gt = st.get("gold_today", {})
        today = datetime.now(IL).strftime("%Y-%m-%d")
        if gt.get("date") == today and gt.get("count", 0) >= CFG.get("gold", {}).get("max_trades_per_day", 8):
            return False, "gold_daily_cap"
    else:
        sec = sector_of(sig["ticker"])
        if sum(1 for p in open_pos if p.get("sector") == sec) >= g["max_positions_per_sector"]:
            return False, f"sector_cap:{sec}"
    heat = sum(p["risk_open"] for p in open_pos)
    if (heat + risk_dollars) > st["wallet"]["equity"]*g["max_total_open_heat_pct"]:
        return False, "portfolio_heat_cap"
    cd = st.get("cooldown", {})
    if cd.get(sig["ticker"], 0) > 0: return False, "cooldown_after_loss"
    return True, "ok"

# ----------------------------------------------------------------------------
# ledger
# ----------------------------------------------------------------------------
def stock_commission(shares, costs):
    return max(costs["stock_commission_min"], shares*costs["stock_commission_per_share"])

def open_position(st, sig, now, costs, risk_dollars):
    q = sig["shares"]
    side = sig.get("side", "long")
    sgn = 1 if side == "long" else -1
    if sig["kind"] == "gold":
        fill = sig["entry"] + sgn*costs["gold_spread_per_oz"]/2.0   # long buys ask, short sells bid
        fee  = 0.0
        margin = q*fill/CFG["gold"]["leverage"]
        cash_out = margin
    else:
        if side == "short": return None                            # stocks: long only
        fill = sig["entry"]*(1+costs["stock_slippage_pct"])
        fee  = stock_commission(q, costs)
        cash_out = q*fill + fee
    if cash_out > st["wallet"]["cash"]: return None
    st["wallet"]["cash"] -= cash_out
    pos = {"id": f"{sig['ticker']}-{int(now.timestamp())}", "kind": sig["kind"],
           "ticker": sig["ticker"], "side": side, "sector": sector_of(sig["ticker"]),
           "qty": q, "qty_left": q, "entry": round(fill, 4), "stop": sig["stop"],
           "orig_stop": sig["stop"], "t1": sig["t1"], "t2": sig["t2"],
           "opened": now.isoformat(), "opened_day": now.astimezone(IL).strftime("%Y-%m-%d"),
           "risk_open": round(abs(fill-sig["stop"])*q, 2) if sig["kind"] != "gold"
                        else round(abs(fill-sig["stop"])*q, 2),
           "fees": round(fee, 2), "half_done": False, "be_moved": False,
           "score": sig.get("score"), "pattern": sig.get("pattern"),
           "snap": {"rsi": sig.get("rsi"), "rvol": sig.get("rvol"),
                    "score": sig.get("score"), "stop_pct": sig.get("stop_pct"),
                    "regime_ok": sig.get("regime_ok"), "notional": sig.get("notional")},
           "last": fill, "margin": round(cash_out, 2)
           if sig["kind"] == "gold" else 0.0}
    st["positions"].append(pos)
    if sig["kind"] == "gold":
        today = now.astimezone(IL).strftime("%Y-%m-%d")
        gt = st.get("gold_today", {})
        st["gold_today"] = {"date": today,
                            "count": (gt.get("count", 0) if gt.get("date") == today else 0) + 1}
    log(st, f"OPEN {pos['kind'].upper()} {'SHORT ' if side=='short' else ''}{pos['ticker']} x{q} @ {fill:.4f} stop {sig['stop']} T1 {sig['t1']}")
    return pos

def _exit_qty(st, pos, qty, px, now, costs, reason):
    if qty <= 0: return 0.0
    sgn = 1 if pos.get("side", "long") == "long" else -1
    if pos["kind"] == "gold":
        fill = px - sgn*costs["gold_spread_per_oz"]/2.0   # long sells bid, short buys back ask
        fee = 0.0
        pnl = (fill-pos["entry"])*qty*sgn
        st["wallet"]["cash"] += pnl + pos["margin"]*(qty/pos["qty"])
    else:
        fill = px*(1-costs["stock_slippage_pct"])
        fee  = stock_commission(qty, costs)
        pnl  = (fill-pos["entry"])*qty - fee
        st["wallet"]["cash"] += qty*fill - fee
    pos["qty_left"] = round(pos["qty_left"]-qty, 6)
    pos["fees"] = round(pos["fees"]+fee, 2)
    st["wallet"]["realized_pnl"] = round(st["wallet"]["realized_pnl"]+pnl, 2)
    r_unit = abs(pos["entry"]-pos["orig_stop"])*pos["qty"]
    rec = {"ticker": pos["ticker"], "kind": pos["kind"], "side": pos.get("side","long"),
           "pattern": pos.get("pattern"), "snap": pos.get("snap"),
           "stop": pos.get("orig_stop"), "t1": pos.get("t1"), "t2": pos.get("t2"),
           "fees": round(pos.get("fees", 0.0), 2), "qty": qty,
           "entry": pos["entry"], "exit": round(fill, 4), "pnl": round(pnl, 2),
           "r": round(pnl/r_unit, 2) if r_unit else 0.0, "reason": reason,
           "opened": pos["opened"], "closed": now.isoformat(),
           "day": now.astimezone(IL).strftime("%Y-%m-%d"),
           "held_days": max(0, (now.date()-datetime.fromisoformat(pos["opened"]).date()).days),
           "followed_rules": True}
    st["closed"].insert(0, rec)
    st["closed"] = st["closed"][:400]
    log(st, f"EXIT {pos['ticker']} x{qty} @ {fill:.4f} ({reason}) P/L ${pnl:+.2f} / {rec['r']:+.2f}R")
    if pnl < 0:
        st.setdefault("cooldown", {})[pos["ticker"]] = CFG["governor"]["cooldown_bars_after_loss"]
    return pnl

def manage_positions(st, prices, now, costs):
    """Stop -> exit all. T1 -> half off + stop to breakeven. T2 -> exit rest.
    Trail: once past T1, stop trails to max(be, last - 1.0 * initial risk)."""
    still = []
    for pos in st["positions"]:
        px = prices.get(pos["ticker"])
        if px is None:
            still.append(pos); continue
        pos["last"] = round(px, 4)
        sgn = 1 if pos.get("side", "long") == "long" else -1
        risk_ps = abs(pos["entry"]-pos["orig_stop"])
        if sgn*(px - pos["stop"]) <= 0:
            _exit_qty(st, pos, pos["qty_left"], pos["stop"], now, costs, "stop")
        else:
            if (not pos["half_done"]) and sgn*(px - pos["t1"]) >= 0:
                half = math.floor(pos["qty_left"]/2) if pos["kind"] != "gold" \
                       else math.floor(pos["qty_left"]*50)/100.0
                if half > 0:
                    _exit_qty(st, pos, half, pos["t1"], now, costs, "T1_half")
                pos["half_done"] = True
                pos["stop"] = round(pos["entry"], 4); pos["be_moved"] = True
                log(st, f"BE {pos['ticker']} stop -> breakeven {pos['stop']}")
            if pos["qty_left"] > 0 and sgn*(px - pos["t2"]) >= 0:
                _exit_qty(st, pos, pos["qty_left"], pos["t2"], now, costs, "T2")
            elif pos["half_done"] and pos["qty_left"] > 0:
                trail = px - sgn*risk_ps
                if sgn*(trail - pos["stop"]) > 0:
                    pos["stop"] = round(trail, 4)
        if pos["qty_left"] > 1e-9:
            sgn2 = 1 if pos.get("side", "long") == "long" else -1
            pos["risk_open"] = round(max(0.0, sgn2*(pos["last"]-pos["stop"]))*pos["qty_left"], 2)
            still.append(pos)
    st["positions"] = still

def mark_to_market(st):
    def _sgn(p): return 1 if p.get("side", "long") == "long" else -1
    open_pnl = 0.0
    for p in st["positions"]:
        open_pnl += (p["last"]-p["entry"])*p["qty_left"]*_sgn(p)
    held = sum(p["qty_left"]*p["last"] for p in st["positions"] if p["kind"] != "gold")
    marg = sum(p["margin"]*(p["qty_left"]/p["qty"]) for p in st["positions"] if p["kind"] == "gold")
    gold_pnl = sum((p["last"]-p["entry"])*p["qty_left"]*_sgn(p) for p in st["positions"] if p["kind"] == "gold")
    eq = st["wallet"]["cash"] + held + marg + gold_pnl
    st["wallet"]["open_pnl"] = round(open_pnl, 2)
    st["wallet"]["equity"] = round(eq, 2)
    st["wallet"]["peak_equity"] = round(max(st["wallet"].get("peak_equity", eq), eq), 2)
    pk = st["wallet"]["peak_equity"]
    st["wallet"]["max_dd_pct"] = round(min(st["wallet"].get("max_dd_pct", 0.0),
                                           (eq/pk-1)*100 if pk else 0.0), 2)
    st["wallet"]["return_pct"] = round((eq/st["wallet"]["start"]-1)*100, 2)

# ----------------------------------------------------------------------------
# calendar + gamification
# ----------------------------------------------------------------------------
BADGES = [
    ("first_trade",  "🎬 העסקה הראשונה",        lambda s: len(s["closed"]) >= 1),
    ("first_win",    "🥇 הניצחון הראשון",       lambda s: any(t["pnl"] > 0 for t in s["closed"])),
    ("five_wins",    "🖐️ 5 ניצחונות",           lambda s: sum(1 for t in s["closed"] if t["pnl"] > 0) >= 5),
    ("green_3",      "🔥 3 ימים ירוקים ברצף",   lambda s: s["game"]["best_streak"] >= 3),
    ("green_7",      "🌋 שבוע ירוק שלם",        lambda s: s["game"]["best_streak"] >= 7),
    ("two_r",        "🚀 עסקה של 2R+",          lambda s: any(t["r"] >= 2 for t in s["closed"])),
    ("three_r",      "☄️ עסקה של 3R+",          lambda s: any(t["r"] >= 3 for t in s["closed"])),
    ("survivor",     "🛡️ שרדת יום אדום בכללים", lambda s: any(d["pnl"] < -20 and d.get("discipline", 100) >= 90
                                                              for d in s["calendar"].values())),
    ("k1100",        "💵 $1,100",               lambda s: s["wallet"]["peak_equity"] >= 1100),
    ("k1250",        "💰 $1,250",               lambda s: s["wallet"]["peak_equity"] >= 1250),
    ("k1500",        "🏦 $1,500",               lambda s: s["wallet"]["peak_equity"] >= 1500),
    ("k2000",        "👑 $2,000",               lambda s: s["wallet"]["peak_equity"] >= 2000),
    ("k5000",        "🌌 $5,000 — פותח מסלול ארוך-טווח", lambda s: s["wallet"]["peak_equity"] >= 5000),
    ("no_rule_break","🧘 30 עסקאות בכללים",     lambda s: len(s["closed"]) >= 30 and
                                                          all(t.get("followed_rules") for t in s["closed"][:30])),
    ("gold_win",     "🪙 ניצחון ראשון בזהב",     lambda s: any(t["kind"] == "gold" and t["pnl"] > 0 for t in s["closed"])),
]

LEVELS = ["🥚 טירון", "🐣 מתלמד", "🗡️ סוחר זוטר", "⚔️ סוחר", "🛡️ סוחר בכיר",
          "🏹 צלף", "🧙 מאסטר", "🐉 אלוף השוק", "🌠 אגדה", "🌌 מיתולוגי"]

def xp_for_level(lv): return int(120*(lv**1.6))

def rebuild_calendar_and_game(st):
    cal = {}
    for t in st["closed"]:
        d = t["day"]
        c = cal.setdefault(d, {"pnl": 0.0, "trades": 0, "wins": 0, "losses": 0,
                               "r": 0.0, "tickers": [], "breaks": 0})
        c["pnl"] += t["pnl"]; c["trades"] += 1; c["r"] += t.get("r", 0)
        c["wins"] += 1 if t["pnl"] > 0 else 0
        c["losses"] += 1 if t["pnl"] <= 0 else 0
        if t["ticker"] not in c["tickers"]: c["tickers"].append(t["ticker"])
        if not t.get("followed_rules", True): c["breaks"] += 1
    for d, c in cal.items():
        c["pnl"] = round(c["pnl"], 2); c["r"] = round(c["r"], 2)
        c["discipline"] = int(round(100*(1 - c["breaks"]/max(1, c["trades"]))))
        c["status"] = "green" if c["pnl"] > 0.5 else ("red" if c["pnl"] < -0.5 else "flat")
    # keep manually-added notes from a previous run
    for d, old in (st.get("calendar") or {}).items():
        if d in cal and old.get("note"): cal[d]["note"] = old["note"]
        elif d not in cal and old.get("note"): cal[d] = {**old, "trades": old.get("trades", 0)}
    st["calendar"] = cal

    # streak of green days (chronological, only days with trades)
    days = sorted([d for d, c in cal.items() if c.get("trades")])
    streak = best = 0
    for d in days:
        if cal[d]["status"] == "green": streak += 1; best = max(best, streak)
        elif cal[d]["status"] == "red": streak = 0
    st["game"]["streak"] = streak
    st["game"]["best_streak"] = max(best, st["game"].get("best_streak", 0))

    # XP
    xp = 0
    for t in st["closed"]:
        xp += 10
        if t["pnl"] > 0: xp += 25
        if t.get("r", 0) >= 2: xp += 30
        if t.get("r", 0) >= 3: xp += 40
        if t.get("followed_rules", True): xp += 5
    for d, c in cal.items():
        if c.get("trades") and c.get("discipline", 0) == 100: xp += 15
        if c["status"] == "green": xp += 20
    st["game"]["xp"] = xp
    lv = 1
    while lv < len(LEVELS) and xp >= xp_for_level(lv+1): lv += 1
    st["game"]["level"] = lv
    st["game"]["level_name"] = LEVELS[lv-1]
    st["game"]["xp_this_level"] = xp - xp_for_level(lv)
    st["game"]["xp_next_level"] = xp_for_level(lv+1) - xp_for_level(lv) if lv < len(LEVELS) else 0
    st["game"]["badges"] = [{"id": i, "name": n, "earned": bool(f(st))} for i, n, f in BADGES]

    # DAILY boss (Idan's request): 8% of the day-open equity = boss beaten,
    # 20% = legendary. Honest note: with 2-4% risk per trade this is a rare
    # "perfect day", not the expected outcome — most days end far below.
    now_il = datetime.now(IL); dk = now_il.strftime("%Y-%m-%d")
    gcfg2 = CFG.get("game", {})
    dopen = st.get("day_open", {})
    if dopen.get("date") != dk:
        dopen = {"date": dk, "equity": st["wallet"]["equity"]}
        st["day_open"] = dopen
    day_done = round(st["wallet"]["equity"] - dopen["equity"], 2)
    target   = round(dopen["equity"]*gcfg2.get("daily_target_pct", 0.08), 2)
    legend   = round(dopen["equity"]*gcfg2.get("legendary_target_pct", 0.20), 2)
    st["game"]["boss"] = {"day": dk, "name": "👹 בוס היום",
                          "target": target, "legend": legend, "done": day_done,
                          "base": dopen["equity"],
                          "pct": int(max(0, min(100, round(100*day_done/target)))) if target > 0 else 0,
                          "pct_legend": int(max(0, min(100, round(100*day_done/legend)))) if legend > 0 else 0,
                          "beaten": day_done >= target, "legendary": day_done >= legend}
    mk = now_il.strftime("%Y-%m")
    # periodic P/L summary the user asked for (day/week/month/quarter/half/year)
    st["periods"] = period_summary(cal, st["wallet"]["start"])
    # daily quests
    today = now_il.strftime("%Y-%m-%d"); tc = cal.get(today, {})
    st["game"]["quests"] = [
        {"t": "לא לשבור אף כלל היום", "done": tc.get("discipline", 100) == 100, "xp": 15},
        {"t": "לסיים את היום ירוק",   "done": tc.get("status") == "green",     "xp": 20},
        {"t": "להסתכל על לוח-השנה",   "done": True,                            "xp": 5},
        {"t": "לא יותר מ-4 פוזיציות פתוחות", "done": len(st["positions"]) <= 4, "xp": 10},
    ]

def period_summary(cal, start_equity):
    now = datetime.now(IL).date()
    def total(days):
        c0 = now - timedelta(days=days)
        return round(sum(v["pnl"] for k, v in cal.items()
                         if date.fromisoformat(k) >= c0), 2)
    return {"day": total(0), "week": total(7), "month": total(30),
            "quarter": total(91), "half": total(182), "year": total(365),
            "two_year": total(730), "all": round(sum(v["pnl"] for v in cal.values()), 2),
            "all_pct": round(100*sum(v["pnl"] for v in cal.values())/start_equity, 2)}

def compute_health(st):
    """Rolling last-20 per strategy. ALERT ONLY — never disables (Idan's choice)."""
    hcfg = CFG.get("health", {})
    win = hcfg.get("window", 20); mn = hcfg.get("min_trades", 8)
    out = {}
    for kind in ("swing", "gold", "day"):
        tr = [t for t in st["closed"] if t["kind"] == kind][:win]
        if len(tr) >= mn:
            exp = sum(t["pnl"] for t in tr)/len(tr)
            gp = sum(t["pnl"] for t in tr if t["pnl"] > 0)
            gl = abs(sum(t["pnl"] for t in tr if t["pnl"] <= 0))
            out[kind] = {"n": len(tr), "exp": round(exp, 2),
                         "pf": (round(gp/gl, 2) if gl > 0 else None),
                         "avg_r": round(sum(t.get("r", 0) for t in tr)/len(tr), 2),
                         "status": "warn" if exp < 0 else "ok"}
        else:
            out[kind] = {"n": len(tr), "status": "na"}
    st["health"] = out

def check_halts(st):
    g = CFG["governor"]; cal = st["calendar"]
    now_il = datetime.now(IL); today = now_il.strftime("%Y-%m-%d")
    eq = st["wallet"]["equity"]
    dpnl = cal.get(today, {}).get("pnl", 0.0)
    wk0 = (now_il.date()-timedelta(days=now_il.weekday()+1)).isoformat()
    wpnl = sum(v["pnl"] for k, v in cal.items() if k >= wk0)
    st["halts"] = {
        "daily_stop_hit":  dpnl <= -eq*g["daily_loss_limit_pct"],
        "weekly_stop_hit": wpnl <= -eq*g["weekly_loss_limit_pct"],
        "day_pnl": round(dpnl, 2), "week_pnl": round(wpnl, 2),
        "daily_limit": round(-eq*g["daily_loss_limit_pct"], 2),
        "weekly_limit": round(-eq*g["weekly_loss_limit_pct"], 2)}

def log(st, msg):
    st["log"].insert(0, {"t": datetime.now(IL).strftime("%Y-%m-%d %H:%M"), "m": msg})
    st["log"] = st["log"][:80]

# ----------------------------------------------------------------------------
def fresh_state():
    w = CFG["wallet_start"]
    return {"version": "3.0", "wallet": {"start": w, "cash": w, "equity": w,
            "realized_pnl": 0.0, "open_pnl": 0.0, "peak_equity": w,
            "max_dd_pct": 0.0, "return_pct": 0.0},
            "risk_pct": CFG["risk_pct"], "positions": [], "closed": [],
            "signals": {"swing": [], "day": [], "gold": []},
            "calendar": {}, "equity_curve": [], "cooldown": {},
            "game": {"xp": 0, "level": 1, "streak": 0, "best_streak": 0,
                     "badges": [], "quests": [], "boss": {}},
            "halts": {"daily_stop_hit": False, "weekly_stop_hit": False},
            "log": [], "month_open_equity": {}}

def market_open_now(now_et):
    if now_et.weekday() >= 5: return False
    return dtime(9, 30) <= now_et.time() <= dtime(16, 5)

def main():
    now_utc = datetime.now(UTC); now_et = now_utc.astimezone(ET); now_il = now_utc.astimezone(IL)
    st = load_json(STATE_F) or fresh_state()
    for k, v in fresh_state().items(): st.setdefault(k, v)
    ctrl = load_json(CTRL_F, {"halt": False, "close_all": False}) or {}
    st["control"] = {"halt": bool(ctrl.get("halt")), "close_all": bool(ctrl.get("close_all"))}
    st["risk_pct"] = CFG["risk_pct"]
    st["wallet"]["name"] = CFG.get("wallet_name", "UHTA")
    st["risk_pcts"] = {"stocks": CFG.get("risk_pct_stocks", CFG["risk_pct"]),
                       "gold":   CFG.get("risk_pct_gold",   CFG["risk_pct"])}
    costs = CFG["costs"]; g = CFG["governor"]

    # cooldown decay
    st["cooldown"] = {k: v-1 for k, v in st.get("cooldown", {}).items() if v-1 > 0}

    tradable = [t for sec in UNI["sectors"].values() for t in sec]
    excl = set(UNI.get("low_liquidity_excluded", []))
    tradable = [t for t in tradable if t not in excl]
    premium = UNI.get("premium_watch_only", [])

    # ---------- data ----------
    daily = fetch_daily(tradable + premium + ["SPY"], "8mo")
    spy = daily.get("SPY")
    regime_ok = True
    if spy:
        cl = [b["c"] for b in spy]
        ma = sma(cl, 50)
        regime_ok = bool(ma and cl[-1] > ma)
    st["regime"] = {"spy_above_ma50": regime_ok,
                    "spy": round(spy[-1]["c"], 2) if spy else None}

    prices = {t: b[-1]["c"] for t, b in daily.items()}

    gold_bars = []
    gold_src = None
    for sym in [CFG["gold"]["yf_symbol"], "XAUUSD=X", "MGC=F"]:   # futures -> spot -> micro
        gb = fetch_intraday([sym], "5m", "5d")
        if gb.get(sym) and len(gb[sym]) >= 70:
            gold_bars = gb[sym]; gold_src = sym; break
    if gold_bars: prices[CFG["gold"]["symbol"]] = gold_bars[-1]["c"]

    # ---------- emergency close-all ----------
    if st["control"]["close_all"] and st["positions"]:
        for pos in list(st["positions"]):
            px = prices.get(pos["ticker"], pos["last"])
            _exit_qty(st, pos, pos["qty_left"], px, now_il, costs, "emergency_close")
        st["positions"] = []
        log(st, "🛑 מפסק חירום: כל הפוזיציות נסגרו")
        save_json(CTRL_F, {"halt": True, "close_all": False})
        st["control"] = {"halt": True, "close_all": False}
    if st["control"]["halt"]:
        log(st, "🛑 המסחר מושהה (מפסק חירום) — אין פתיחות חדשות")

    # ---------- 1) manage what is already open ----------
    manage_positions(st, prices, now_il, costs)
    mark_to_market(st)
    rebuild_calendar_and_game(st); check_halts(st)

    risk_stocks = round(st["wallet"]["equity"]*CFG.get("risk_pct_stocks", CFG["risk_pct"]), 2)
    risk_gold   = round(st["wallet"]["equity"]*CFG.get("risk_pct_gold",   CFG["risk_pct"]), 2)

    # ---------- 2) scan ----------
    sigs = {"swing": [], "day": [], "gold": []}
    uview = []
    scfg = CFG["swing"]
    if scfg["enabled"]:
        for tk in tradable:
            bars = daily.get(tk)
            if not bars:
                uview.append({"t": tk, "sec": sector_of(tk), "state": "no_data"})
                continue
            try:
                s = swing_signal(tk, bars, scfg, risk_stocks, st["wallet"]["cash"],
                                 st["wallet"]["equity"], g["max_notional_frac_of_equity"])
            except Exception:
                s = None
            c_ = [b["c"] for b in bars]; v_ = [b["v"] for b in bars]
            ma_ = sma(c_, scfg["trend_ma_len"]); rsi_ = wilder_rsi(c_, scfg["rsi_len"])
            uview.append({"t": tk, "sec": sector_of(tk),
                          "px": round(c_[-1], 2),
                          "trend": (None if not ma_ else round((c_[-1]/ma_-1)*100, 1)),
                          "rsi": (None if rsi_ is None else round(rsi_)),
                          "rvol": round(v_[-1]/(sma(v_, 20) or 1), 1),
                          "state": ("signal" if (s and s["state"] == "BUY_NOW")
                                    else "watch" if s else "none")})
            if s:
                s["score"] = score(s, regime_ok); sigs["swing"].append(s)
    for tk in premium:
        bars = daily.get(tk)
        if bars:
            c_ = [b["c"] for b in bars]; ma_ = sma(c_, 50)
            uview.append({"t": tk, "sec": "premium", "px": round(c_[-1], 2),
                          "trend": (None if not ma_ else round((c_[-1]/ma_-1)*100, 1)),
                          "state": "premium"})
        else:
            uview.append({"t": tk, "sec": "premium", "state": "no_data"})
    st["universe_view"] = uview

    dcfg = CFG["day"]
    if dcfg["enabled"] and market_open_now(now_et):
        focus = [t for t in UNI.get("day_focus", []) if t not in excl]
        intr = fetch_intraday(focus, "5m", "5d")
        for tk, bars in intr.items():
            sess, _ = split_sessions(bars, True)
            try:
                s = day_signal(tk, sess, dcfg, risk_stocks, st["wallet"]["cash"], now_et,
                               st["wallet"]["equity"], g["max_notional_frac_of_equity"])
            except Exception:
                s = None
            if s:
                s["score"] = score(s, regime_ok); sigs["day"].append(s)
            if bars: prices[tk] = bars[-1]["c"]

    gcfg = CFG["gold"]
    if gcfg["enabled"] and gold_bars:
        try:
            sigs["gold"] = gold_signals(gold_bars, gcfg, st["wallet"]["equity"],
                                        st["wallet"]["cash"], risk_gold)
        except Exception:
            sigs["gold"] = []

    for k in sigs: sigs[k].sort(key=lambda x: -x["score"])
    st["signals"] = sigs

    # ---------- 3) execute, strongest first ----------
    cands = sorted(sigs["swing"] + sigs["gold"] +
                   ([] if dcfg.get("paper_only") is False else sigs["day"]),
                   key=lambda x: -x["score"])
    st["rejected"] = []
    for c in cands:
        c["regime_ok"] = regime_ok
        rd = risk_gold if c["kind"] == "gold" else risk_stocks
        ok, why = governor_check(st, c, g, rd)
        if not ok:
            if why not in ("watch_only",):
                st["rejected"].append({"ticker": c["ticker"], "kind": c["kind"], "why": why})
            continue
        if open_position(st, c, now_il, costs, rd):
            manage_positions(st, prices, now_il, costs)   # instant-stop safety
            mark_to_market(st)

    # ---------- agents report (who works on what, live) ----------
    open_heat = sum(p["risk_open"] for p in st["positions"])
    hlt = st.get("health", {})
    st["agents"] = {
        "swing": {"icon": "📈", "name": "סוכן הסווינג", "domain": f"{len(tradable)} מניות ≤$20 · גרף יומי",
                  "with_data": sum(1 for u in uview if u.get("state") not in (None, "no_data") and u.get("sec") != "premium"),
                  "signals": len(sigs["swing"]),
                  "health": hlt.get("swing", {}),
                  "desc": "פריצות מעל שיא משמעותי עם ווליום, מגמה ו-RSI. סטופ = ההדוק מבין השפל ל-1.6×ATR. יעדים 2R/3.5R."},
        "day":   {"icon": "⚡", "name": "סוכן הדיי-טרייד 🧪", "domain": f"{len(UNI.get('day_focus', []))} מניות · 5 דק' · חלון 17:05-18:00",
                  "active": market_open_now(now_et), "signals": len(sigs["day"]),
                  "paper_only": True,
                  "desc": "פריצת טווח פתיחה עם VWAP וזרימה. ניסיוני — נייר בלבד, לא מבוצע אוטומטית."},
        "gold":  {"icon": "🪙", "name": "סוכן הזהב", "domain": "XAUUSD · 5 דק' · קנייה+מכירה · עד 8/יום",
                  "bars": len(gold_bars), "scanned": bool(gold_bars), "source": gold_src,
                  "last_price": (round(gold_bars[-1]["c"], 2) if gold_bars else None),
                  "signals": len(sigs["gold"]),
                  "today_trades": st.get("gold_today", {}).get("count", 0)
                                  if st.get("gold_today", {}).get("date") == now_il.strftime("%Y-%m-%d") else 0,
                  "health": hlt.get("gold", {}),
                  "desc": "4 תבניות: חציית ממוצעים / פולבק לגל / החזרת VWAP / פריצת טווח — לשני הכיוונים. סטופ 1.5×ATR, יעדים 1.5R/3R."},
        "guard": {"icon": "🛡️", "name": "שומר הסיכון", "domain": "כל עסקה עוברת דרכו",
                  "open": len(st["positions"]), "heat": round(open_heat, 2),
                  "halt": st["control"]["halt"],
                  "desc": "תקרות: 3 פוזיציות, heat 12.5%, סקטור אחד, עצירה יומית/שבועית, R:R≥1.5, מכסת זהב יומית."},
    }

    # ---------- 4) finalise ----------
    mark_to_market(st)
    rebuild_calendar_and_game(st); check_halts(st); compute_health(st)
    today = now_il.strftime("%Y-%m-%d")
    ec = [p for p in st["equity_curve"] if p[0] != today]
    ec.append([today, st["wallet"]["equity"]])
    st["equity_curve"] = ec[-400:]
    st["updated_utc"] = now_utc.isoformat()
    st["updated_israel"] = now_il.strftime("%Y-%m-%d %H:%M")
    st["market"] = {"open": market_open_now(now_et), "et": now_et.strftime("%H:%M"),
                    "il": now_il.strftime("%H:%M")}
    st["stats"] = compute_stats(st)
    save_json(STATE_F, st)
    print(f"OK  equity={st['wallet']['equity']}  open={len(st['positions'])}  "
          f"signals={sum(len(v) for v in sigs.values())}  lvl={st['game']['level']}")

def compute_stats(st):
    cl = st["closed"]
    if not cl:
        return {"trades": 0, "win_rate": 0, "pf": 0, "avg_r": 0, "expectancy": 0,
                "best": 0, "worst": 0, "fees": 0}
    wins = [t["pnl"] for t in cl if t["pnl"] > 0]; losses = [t["pnl"] for t in cl if t["pnl"] <= 0]
    gp = sum(wins); gl = abs(sum(losses))
    return {"trades": len(cl),
            "win_rate": round(100*len(wins)/len(cl), 1),
            "pf": round(gp/gl, 2) if gl > 0 else None,
            "avg_r": round(sum(t.get("r", 0) for t in cl)/len(cl), 2),
            "expectancy": round(sum(t["pnl"] for t in cl)/len(cl), 2),
            "best": round(max(t["pnl"] for t in cl), 2),
            "worst": round(min(t["pnl"] for t in cl), 2)}

if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        st = load_json(STATE_F) or fresh_state()
        log(st, "❌ שגיאה בריצה — המצב נשמר ללא שינוי")
        st["last_error"] = traceback.format_exc()[-1200:]
        save_json(STATE_F, st)
        sys.exit(0)   # never fail the workflow; never corrupt state
