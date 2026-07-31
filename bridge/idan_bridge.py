#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
idan_bridge.py  -  Idan Trader execution bridge   (PAPER ACCOUNTS ONLY)

WHAT THIS IS
    The engine on GitHub decides. This program executes. It runs on YOUR PC,
    next to IB Gateway or TWS, and keeps your Interactive Brokers PAPER account
    in sync with data/state.json that the engine publishes.

    It is a reconciler, not an event listener. Every cycle it asks one question:
    "does the broker look like the engine's book?" - and fixes the difference.
    That means it is safe to stop it, restart it, or miss a cycle. It catches up.

WHAT IT WILL NOT DO
    * It will not touch a live account. If the account code does not start with
      DU it exits immediately. There is no flag to override this.
    * It will not connect on a live port. 7496 and 4001 are refused.
    * It will not trade gold. Interactive Brokers has no spot gold through this
      route - gold stays in MetaTrader.
    * It will not size from your broker balance. Size comes from the engine,
      which runs a 1,000 USD wallet. A paper account showing 1,000,000 changes
      nothing.
    * It starts in DRY RUN. Nothing is sent until you pass --live.

SETUP
    pip install ib_async
    In TWS/Gateway:  Settings -> API -> enable ActiveX and Socket Clients,
                     add 127.0.0.1 to trusted IPs, socket port 7497 (TWS paper)
                     or 4002 (Gateway paper).

RUN
    python idan_bridge.py                 # dry run, prints what it would do
    python idan_bridge.py --live          # actually sends orders
    python idan_bridge.py --live --day    # also route the day-trade engine
"""

import argparse
import json
import math
import signal
import sys
import time
import urllib.request
from datetime import datetime, timezone

# --------------------------------------------------------------------------
# CONFIGURATION
# --------------------------------------------------------------------------
REPO_RAW   = "https://raw.githubusercontent.com/Elkingo18/idan-signals/main"
STATE_URL  = REPO_RAW + "/data/state.json"
CTRL_URL   = REPO_RAW + "/data/control.json"

PAPER_PORTS = (7497, 4002)          # TWS paper, Gateway paper
LIVE_PORTS  = (7496, 4001)          # refused on sight

WALLET          = 1000.0            # the managed wallet, never the broker balance
MAX_NOTIONAL    = 350.0             # 35% of the wallet - the engine's own cap
MAX_POSITIONS   = 4                 # governor.max_open_positions
POLL_SECONDS    = 60
EXCHANGE        = "SMART"
CURRENCY        = "USD"

SKIP_KINDS_DEFAULT = {"gold", "day"}   # gold: not tradable here. day: paper_only.

# --------------------------------------------------------------------------

_stop = False


def _sigint(_sig, _frm):
    global _stop
    _stop = True
    log("stop requested - finishing this cycle then disconnecting")


def log(msg):
    print("[%s] %s" % (datetime.now().strftime("%H:%M:%S"), msg), flush=True)


def fetch_json(url):
    """Cache-busted fetch. Returns None on any failure - never raises."""
    try:
        req = urllib.request.Request(
            url + "?cb=" + str(int(time.time())),
            headers={"Cache-Control": "no-cache", "User-Agent": "idan-bridge"},
        )
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception as exc:
        log("could not fetch %s -> %s" % (url.rsplit("/", 1)[-1], exc))
        return None


# --------------------------------------------------------------------------
# WHAT THE BOOK SHOULD LOOK LIKE
# --------------------------------------------------------------------------
def desired_book(state, skip_kinds):
    """
    Turn engine positions into {symbol: target}, using qty_left so a half already
    taken at T1 is reflected.

    Returns (book, quarantine).

    QUARANTINE IS THE IMPORTANT PART. If a record looks wrong - implausible
    levels, a size above the cap, more positions than the governor allows - the
    symbol goes to quarantine, NOT out of the book. Reconcile then leaves that
    symbol completely alone: it places nothing and, critically, it does not sell
    what is already held. Liquidating a real position because of a data quirk is
    a far worse failure than holding one for another cycle.
    """
    book = {}
    quarantine = set()

    for p in state.get("positions", []):
        kind = p.get("kind")
        sym  = p.get("ticker")
        if not sym or kind in skip_kinds:
            continue                       # never ours to hold - safe to flatten
        if p.get("side") != "long":
            continue                       # cash account cannot short

        qty = int(math.floor(float(p.get("qty_left") or 0)))
        if qty < 1:
            continue                       # engine says flat - flatten

        entry = float(p.get("entry") or 0)
        stop  = float(p.get("stop") or 0)
        t1    = float(p.get("t1") or 0)

        # A stop at or above entry is NORMAL for an open position - it means the
        # engine moved to breakeven or started trailing. Only genuine nonsense
        # is rejected here.
        bad = None
        if not (entry > 0 and stop > 0 and t1 > 0):
            bad = "non-positive levels"
        elif t1 <= stop:
            bad = "target is not above the stop"
        elif abs(stop - entry) / entry > 0.60:
            bad = "stop is %.0f%% away from entry" % (abs(stop - entry) / entry * 100)
        elif qty * entry > MAX_NOTIONAL * 1.10:
            bad = "notional %.0f exceeds the %.0f cap" % (qty * entry, MAX_NOTIONAL)

        if bad:
            log("QUARANTINE %-6s - %s (leaving any existing position untouched)" % (sym, bad))
            quarantine.add(sym)
            continue

        book[sym] = {"qty": qty, "stop": round(stop, 2), "t1": round(t1, 2), "kind": kind}

    if len(book) > MAX_POSITIONS:
        extra = list(book)[MAX_POSITIONS:]
        log("engine sent %d positions, cap is %d - quarantining %s"
            % (len(book), MAX_POSITIONS, ", ".join(extra)))
        for sym in extra:
            quarantine.add(sym)
            book.pop(sym)

    return book, quarantine


# --------------------------------------------------------------------------
# BROKER SIDE
# --------------------------------------------------------------------------
class Broker:
    def __init__(self, ib, account, dry):
        self.ib = ib
        self.account = account
        self.dry = dry
        self._contracts = {}

    def contract(self, symbol):
        from ib_async import Stock
        if symbol not in self._contracts:
            c = Stock(symbol, EXCHANGE, CURRENCY)
            details = self.ib.reqContractDetails(c)
            if not details:
                raise RuntimeError("no contract for %s" % symbol)
            self._contracts[symbol] = details[0].contract
        return self._contracts[symbol]

    def positions(self):
        out = {}
        for p in self.ib.positions(self.account):
            if p.contract.secType == "STK" and p.position:
                out[p.contract.symbol] = int(p.position)
        return out

    def open_trades(self):
        out = {}
        for t in self.ib.openTrades():
            if t.contract.secType != "STK":
                continue
            out.setdefault(t.contract.symbol, []).append(t)
        return out

    # -- actions ---------------------------------------------------------
    def buy_market(self, symbol, qty):
        from ib_async import MarketOrder
        if self.dry:
            log("DRY  BUY  %-6s %d @ market" % (symbol, qty))
            return
        o = MarketOrder("BUY", qty)
        o.account = self.account
        o.outsideRth = False
        self.ib.placeOrder(self.contract(symbol), o)
        log("SENT BUY  %-6s %d @ market" % (symbol, qty))

    def sell_market(self, symbol, qty):
        from ib_async import MarketOrder
        if self.dry:
            log("DRY  SELL %-6s %d @ market" % (symbol, qty))
            return
        o = MarketOrder("SELL", qty)
        o.account = self.account
        o.outsideRth = False
        self.ib.placeOrder(self.contract(symbol), o)
        log("SENT SELL %-6s %d @ market" % (symbol, qty))

    def cancel(self, trades):
        for t in trades:
            if self.dry:
                log("DRY  cancel %s %s" % (t.contract.symbol, t.order.orderType))
            else:
                self.ib.cancelOrder(t.order)

    def place_exits(self, symbol, qty, stop, t1):
        """One OCA pair: protective stop and take-profit. Whichever fills kills the other."""
        from ib_async import StopOrder, LimitOrder
        oca = "IDAN-%s-%d" % (symbol, int(time.time()))
        sl = StopOrder("SELL", qty, stop)
        tp = LimitOrder("SELL", qty, t1)
        for o in (sl, tp):
            o.account = self.account
            o.ocaGroup = oca
            o.ocaType = 1            # cancel the sibling and reduce nothing
            o.tif = "GTC"
            o.outsideRth = False
        if self.dry:
            log("DRY  exits %-6s qty %d  stop %.2f  target %.2f" % (symbol, qty, stop, t1))
            return
        c = self.contract(symbol)
        self.ib.placeOrder(c, sl)
        self.ib.placeOrder(c, tp)
        log("SENT exits %-6s qty %d  stop %.2f  target %.2f" % (symbol, qty, stop, t1))


def exits_match(trades, qty, stop, t1):
    """True when the resting orders already say exactly what we want."""
    stops = [t for t in trades if t.order.orderType in ("STP", "STP LMT")]
    limits = [t for t in trades if t.order.orderType == "LMT"]
    if len(stops) != 1 or len(limits) != 1:
        return False
    s, l = stops[0], limits[0]
    return (int(s.order.totalQuantity) == qty
            and int(l.order.totalQuantity) == qty
            and abs(float(s.order.auxPrice) - stop) < 0.005
            and abs(float(l.order.lmtPrice) - t1) < 0.005)


# --------------------------------------------------------------------------
# ONE RECONCILIATION PASS
# --------------------------------------------------------------------------
def reconcile(br, state, control, skip_kinds):
    halted    = bool(control.get("halt"))
    close_all = bool(control.get("close_all"))
    mkt_open  = bool((state.get("market") or {}).get("open"))

    if close_all:
        want, quarantine = {}, set()
    else:
        want, quarantine = desired_book(state, skip_kinds)
    have = br.positions()
    orders = br.open_trades()
    opening = 0        # counts entries issued during THIS pass

    if close_all:
        log("CLOSE ALL is set - flattening everything")

    # 1. positions the engine no longer wants (quarantined ones are never touched)
    for sym, qty in have.items():
        if sym in quarantine:
            log("hold %-6s - quarantined, not selling and not adjusting" % sym)
            continue
        if sym not in want:
            br.cancel(orders.get(sym, []))
            if qty > 0:
                br.sell_market(sym, qty)

    # 2. positions the engine wants
    for sym, tgt in want.items():
        held = have.get(sym, 0)

        if held == 0:
            if halted:
                log("hold %-6s - trading is halted, not opening" % sym)
                continue
            if not mkt_open:
                log("hold %-6s - market is closed" % sym)
                continue
            live_count = len([s for s in have if have[s] > 0]) + opening
            if live_count >= MAX_POSITIONS:
                log("hold %-6s - already at %d open positions" % (sym, MAX_POSITIONS))
                continue
            br.buy_market(sym, tgt["qty"])
            opening = opening + 1
            continue    # exits go in on the next cycle, once the fill is real

        if held > tgt["qty"]:
            br.cancel(orders.get(sym, []))
            br.sell_market(sym, held - tgt["qty"])
            continue
        if held < tgt["qty"]:
            if not halted and mkt_open:
                br.buy_market(sym, tgt["qty"] - held)
            continue

        # right size - make sure the protection is right
        if not exits_match(orders.get(sym, []), held, tgt["stop"], tgt["t1"]):
            br.cancel(orders.get(sym, []))
            br.place_exits(sym, held, tgt["stop"], tgt["t1"])

    line = ", ".join("%s x%d" % (s, q) for s, q in sorted(have.items())) or "flat"
    log("book: %s   |   engine wants: %s   |   halt=%s market=%s%s"
        % (line,
           ", ".join(sorted(want)) or "nothing",
           halted, "open" if mkt_open else "closed",
           ("   |   quarantined: " + ", ".join(sorted(quarantine))) if quarantine else ""))


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--live", action="store_true", help="actually send orders")
    ap.add_argument("--day", action="store_true", help="also route day-trade signals")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=7497)
    ap.add_argument("--client-id", type=int, default=17)
    ap.add_argument("--once", action="store_true", help="one pass then exit")
    args = ap.parse_args()

    if args.port in LIVE_PORTS:
        sys.exit("REFUSED: port %d is a live-trading port. This bridge is paper only." % args.port)
    if args.port not in PAPER_PORTS:
        log("warning: %d is not a standard paper port (%s)" % (args.port, PAPER_PORTS))

    try:
        from ib_async import IB
    except ImportError:
        sys.exit("ib_async is not installed.  Run:  pip install ib_async")

    skip = set(SKIP_KINDS_DEFAULT)
    if args.day:
        skip.discard("day")
        log("day-trade routing is ON - remember the day engine is unvalidated")

    dry = not args.live
    print("=" * 66)
    print(" IDAN TRADER BRIDGE   -   %s" % ("LIVE ORDERS" if args.live else "DRY RUN (nothing is sent)"))
    print(" wallet %.0f USD   max notional %.0f   max positions %d" % (WALLET, MAX_NOTIONAL, MAX_POSITIONS))
    print(" skipping: %s" % ", ".join(sorted(skip)))
    print("=" * 66)

    ib = IB()
    ib.connect(args.host, args.port, clientId=args.client_id, timeout=20)

    accounts = ib.managedAccounts()
    if not accounts:
        ib.disconnect()
        sys.exit("REFUSED: no managed account returned.")
    account = accounts[0]
    if not account.upper().startswith("DU"):
        ib.disconnect()
        sys.exit("REFUSED: account %s is not a paper account. Paper accounts start with DU. "
                 "This bridge will not trade a funded account." % account)
    log("connected to paper account %s" % account)

    br = Broker(ib, account, dry)
    signal.signal(signal.SIGINT, _sigint)

    while not _stop:
        state = fetch_json(STATE_URL)
        ctrl  = fetch_json(CTRL_URL) or {}
        if state is None:
            log("no state - skipping this cycle, keeping existing orders in place")
        else:
            stamp = state.get("updated_israel") or state.get("updated_utc") or "?"
            log("state from %s" % stamp)
            try:
                reconcile(br, state, ctrl, skip)
            except Exception as exc:
                log("reconcile failed: %r  (orders left untouched)" % exc)
        if args.once:
            break
        for _ in range(POLL_SECONDS):
            if _stop:
                break
            ib.sleep(1)

    ib.disconnect()
    log("disconnected. Open orders were left in place at the broker.")


if __name__ == "__main__":
    main()
