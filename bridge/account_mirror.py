#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
IDAN TRADER - ACCOUNT MIRROR   (read only)
==========================================

What it does
------------
Connects to IB Gateway on the PAPER account, reads the account, and writes a
snapshot to  data/account.json  so the live site can show the real broker state
next to the engine's own book.

It NEVER sends an order. There is no code path in this file that places,
modifies or cancels anything. It only calls read methods.

The shadow wallet
-----------------
An IB paper account starts with about a million virtual dollars. That number is
meaningless for this system, so we ignore it completely and keep our own
1,000 dollar shadow wallet:

    shadow_equity = 1000 + cumulative_realised + current_unrealised

cumulative_realised is persisted in  bridge/mirror_state.json  so it survives a
restart. Only positions the engine actually opened are counted - anything you
opened by hand in the same account is reported separately under "manual" and
kept out of the shadow wallet, so a manual trade cannot flatter the record.

Publishing to the site
----------------------
GitHub Pages can only read what is in the repo, and this machine is the only
one that can reach IB. So after each snapshot the mirror can push the file to
the repo through the GitHub contents API.

That needs a token, and I am not going to ask you to give one to me. Make it
yourself and keep it on your own disk:

    1. github.com  ->  Settings  ->  Developer settings
       ->  Personal access tokens  ->  Fine-grained tokens  ->  Generate new
    2. Repository access: only  Elkingo18/idan-signals
    3. Permissions: Contents = Read and write. Nothing else.
    4. Save the token into a file next to this script:

           bridge/gh_token.txt

If that file is missing the mirror still runs - it just writes the snapshot
locally and says so. Nothing breaks.

Run
---
    python account_mirror.py               # one snapshot, prints it, exits
    python account_mirror.py --loop 60     # snapshot every 60 seconds
    python account_mirror.py --no-push     # never touch GitHub

Port 4002 is IB Gateway paper. Port 7497 is TWS paper. Use --port to change.
Use a client id that the execution bridge is not using - default here is 77.
"""

import argparse
import base64
import datetime
import json
import os
import signal
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
OUT_LOCAL = os.path.join(REPO, "data", "account.json")
STATE_FILE = os.path.join(HERE, "mirror_state.json")
TOKEN_FILE = os.path.join(HERE, "gh_token.txt")

GH_OWNER = "Elkingo18"
GH_REPO = "idan-signals"
GH_PATH = "data/account.json"
GH_BRANCH = "main"

SHADOW_START = 1000.0
STATE_URL = "https://raw.githubusercontent.com/{}/{}/{}/data/state.json".format(
    GH_OWNER, GH_REPO, GH_BRANCH)

RUN = True


def _stop(_s, _f):
    global RUN
    RUN = False
    log("stopping after this snapshot")


def log(msg):
    print("[{}] {}".format(datetime.datetime.now().strftime("%H:%M:%S"), msg), flush=True)


def read_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def write_json(path, obj):
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)


def fetch_engine_state():
    """The engine's own book, so we can tell engine positions from manual ones."""
    try:
        req = urllib.request.Request(STATE_URL, headers={"User-Agent": "idan-mirror"})
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception as e:
        log("could not read the engine state ({}) - every position will be marked unknown".format(e))
        return {}


# ----------------------------------------------------------------- IB reading

def snapshot(ib, account):
    """Every call here is a read. Nothing in this function can move money."""
    summary = {}
    for row in ib.accountSummary(account):
        summary[row.tag] = row.value

    positions = []
    for p in ib.positions(account):
        c = p.contract
        positions.append({
            "symbol": c.localSymbol or c.symbol,
            "sec_type": c.secType,
            "currency": c.currency,
            "qty": float(p.position),
            "avg_cost": round(float(p.avgCost), 4),
        })

    # unrealised per position comes from the portfolio view, which also carries
    # the live mark. positions() alone does not have it.
    marks = {}
    for pi in ib.portfolio(account):
        key = pi.contract.localSymbol or pi.contract.symbol
        marks[key] = {
            "mark": round(float(pi.marketPrice), 4),
            "value": round(float(pi.marketValue), 2),
            "unrealized": round(float(pi.unrealizedPNL), 2),
            "realized": round(float(pi.realizedPNL), 2),
        }
    for p in positions:
        p.update(marks.get(p["symbol"], {}))

    orders = []
    for t in ib.openTrades():
        if account and t.order.account and t.order.account != account:
            continue
        c = t.contract
        orders.append({
            "symbol": c.localSymbol or c.symbol,
            "action": t.order.action,
            "type": t.order.orderType,
            "qty": float(t.order.totalQuantity),
            "limit": float(t.order.lmtPrice or 0) or None,
            "stop": float(t.order.auxPrice or 0) or None,
            "status": t.orderStatus.status,
            "filled": float(t.orderStatus.filled or 0),
        })

    fills = []
    for f in ib.fills():
        ex = f.execution
        if account and ex.acctNumber and ex.acctNumber != account:
            continue
        fills.append({
            "symbol": f.contract.localSymbol or f.contract.symbol,
            "side": ex.side,
            "qty": float(ex.shares),
            "price": round(float(ex.price), 4),
            "time": str(ex.time),
            "commission": round(float(getattr(f.commissionReport, "commission", 0) or 0), 4),
            "realized": round(float(getattr(f.commissionReport, "realizedPNL", 0) or 0), 2),
        })

    return summary, positions, orders, fills


def build(summary, positions, orders, fills, engine_state, prev):
    """Assemble the file the site reads. Pure arithmetic - no IB calls."""
    engine_syms = set()
    for p in (engine_state.get("positions") or []):
        engine_syms.add(str(p.get("ticker", "")).upper())
    for t in (engine_state.get("closed") or []):
        engine_syms.add(str(t.get("ticker", "")).upper())

    engine_pos, manual_pos = [], []
    for p in positions:
        p["source"] = "engine" if p["symbol"].upper() in engine_syms else "manual"
        (engine_pos if p["source"] == "engine" else manual_pos).append(p)

    unreal = round(sum(float(p.get("unrealized") or 0) for p in engine_pos), 2)

    # Cumulative realised is remembered across restarts. IB resets its own
    # realizedPNL daily, so we accumulate the daily figure ourselves and only
    # ever move it forward when the day rolls over.
    today = datetime.date.today().isoformat()
    day_real = round(sum(float(p.get("realized") or 0) for p in engine_pos), 2)
    carried = float(prev.get("realized_carried", 0.0))
    last_day = prev.get("realized_day")
    if last_day and last_day != today:
        carried = round(carried + float(prev.get("realized_today", 0.0)), 2)
    cum_real = round(carried + day_real, 2)

    equity = round(SHADOW_START + cum_real + unreal, 2)
    now = datetime.datetime.now(datetime.timezone.utc)

    doc = {
        "schema": 1,
        "updated_utc": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "updated_israel": (now + datetime.timedelta(hours=3)).strftime("%Y-%m-%d %H:%M"),
        "mode": "paper",
        "read_only": True,
        "broker": {
            "net_liquidation": _f(summary.get("NetLiquidation")),
            "total_cash": _f(summary.get("TotalCashValue")),
            "buying_power": _f(summary.get("BuyingPower")),
            "currency": summary.get("Currency") or "USD",
            "note": "IB paper starts around 1,000,000 virtual dollars. Ignored on purpose.",
        },
        "shadow_wallet": {
            "name": "UHTA",
            "start": SHADOW_START,
            "equity": equity,
            "realized_pnl": cum_real,
            "open_pnl": unreal,
            "return_pct": round((equity / SHADOW_START - 1) * 100, 2),
        },
        "positions": engine_pos,
        "manual_positions": manual_pos,
        "open_orders": orders,
        "fills_today": [f for f in fills if str(f.get("time", "")).startswith(today)],
        "counts": {
            "engine_positions": len(engine_pos),
            "manual_positions": len(manual_pos),
            "open_orders": len(orders),
        },
    }
    new_prev = {"realized_carried": carried, "realized_today": day_real, "realized_day": today}
    return doc, new_prev


def _f(v):
    try:
        return round(float(v), 2)
    except Exception:
        return None


# --------------------------------------------------------------- publishing

def push_to_github(doc):
    if not os.path.exists(TOKEN_FILE):
        return "no token file - snapshot saved locally only"
    token = open(TOKEN_FILE, "r", encoding="utf-8").read().strip()
    if not token:
        return "token file is empty - snapshot saved locally only"

    api = "https://api.github.com/repos/{}/{}/contents/{}".format(GH_OWNER, GH_REPO, GH_PATH)
    head = {
        "Authorization": "Bearer " + token,
        "Accept": "application/vnd.github+json",
        "User-Agent": "idan-mirror",
    }
    sha = None
    try:
        req = urllib.request.Request(api + "?ref=" + GH_BRANCH, headers=head)
        with urllib.request.urlopen(req, timeout=25) as r:
            sha = json.loads(r.read().decode("utf-8")).get("sha")
    except Exception:
        pass  # first write, file does not exist yet

    body = {
        "message": "account mirror {}".format(doc["updated_israel"]),
        "content": base64.b64encode(
            json.dumps(doc, ensure_ascii=False, indent=1).encode("utf-8")).decode("ascii"),
        "branch": GH_BRANCH,
    }
    if sha:
        body["sha"] = sha
    req = urllib.request.Request(api, data=json.dumps(body).encode("utf-8"),
                                 headers=dict(head, **{"Content-Type": "application/json"}),
                                 method="PUT")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return "pushed to the repo ({})".format(r.status)
    except Exception as e:
        return "push failed: {}".format(e)


# --------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description="Read-only IB account mirror.")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=4002, help="4002 Gateway paper, 7497 TWS paper")
    ap.add_argument("--client-id", type=int, default=77, help="must differ from the execution bridge")
    ap.add_argument("--account", default="", help="leave empty to use the only account")
    ap.add_argument("--loop", type=int, default=0, help="seconds between snapshots, 0 = once")
    ap.add_argument("--no-push", action="store_true")
    args = ap.parse_args()

    try:
        from ib_async import IB
    except ImportError:
        print("ib_async is missing.  pip install ib_async")
        return 2

    signal.signal(signal.SIGINT, _stop)

    ib = IB()
    log("connecting to {}:{} (client {}) - read only".format(args.host, args.port, args.client_id))
    try:
        ib.connect(args.host, args.port, clientId=args.client_id, timeout=20, readonly=True)
    except Exception as e:
        log("could not connect: {}".format(e))
        log("is IB Gateway running and logged into the PAPER account?")
        log("in Gateway: Configure -> Settings -> API -> Enable ActiveX and Socket Clients,")
        log("and make sure the socket port is {}".format(args.port))
        return 1

    account = args.account or (ib.managedAccounts() or [""])[0]
    log("connected. account {}".format(account or "(default)"))

    engine_state = fetch_engine_state()
    code = 0
    try:
        while RUN:
            try:
                ib.sleep(1)
                summary, positions, orders, fills = snapshot(ib, account)
                prev = read_json(STATE_FILE, {})
                doc, new_prev = build(summary, positions, orders, fills, engine_state, prev)
                write_json(OUT_LOCAL, doc)
                write_json(STATE_FILE, new_prev)
                w = doc["shadow_wallet"]
                log("equity {:.2f}  realised {:+.2f}  open {:+.2f}  positions {}  orders {}".format(
                    w["equity"], w["realized_pnl"], w["open_pnl"],
                    doc["counts"]["engine_positions"], doc["counts"]["open_orders"]))
                if not args.no_push:
                    log(push_to_github(doc))
            except Exception as e:
                log("snapshot failed: {}".format(e))
                code = 1
            if not args.loop:
                break
            for _ in range(args.loop):
                if not RUN:
                    break
                time.sleep(1)
            engine_state = fetch_engine_state()
    finally:
        ib.disconnect()
        log("disconnected")
    return code


if __name__ == "__main__":
    sys.exit(main())
