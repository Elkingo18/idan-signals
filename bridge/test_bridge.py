"""Offline verification of the reconciler. No broker, no network."""
import types, sys
import idan_bridge as B

class FakeTrade:
    def __init__(self, sym, otype, qty, price):
        self.contract = types.SimpleNamespace(symbol=sym, secType="STK")
        o = types.SimpleNamespace(orderType=otype, totalQuantity=qty,
                                  auxPrice=price if otype=="STP" else 0.0,
                                  lmtPrice=price if otype=="LMT" else 0.0)
        self.order = o

class FakeBroker:
    def __init__(self, pos=None, orders=None):
        self._pos = dict(pos or {}); self._orders = dict(orders or {}); self.acts=[]
    def positions(self): return dict(self._pos)
    def open_trades(self): return {k:list(v) for k,v in self._orders.items()}
    def buy_market(self,s,q): self.acts.append(("BUY",s,q))
    def sell_market(self,s,q): self.acts.append(("SELL",s,q))
    def cancel(self,tr):
        for t in tr: self.acts.append(("CANCEL",t.contract.symbol,t.order.orderType))
    def place_exits(self,s,q,stop,t1): self.acts.append(("EXITS",s,q,stop,t1))

def pos(t,kind="swing",qty=28,left=None,entry=12.41,stop=11.72,t1=13.81,side="long"):
    return {"ticker":t,"kind":kind,"qty":qty,"qty_left":qty if left is None else left,
            "entry":entry,"stop":stop,"t1":t1,"t2":t1+2,"side":side}

def state(positions, open_market=True):
    return {"positions":positions,"market":{"open":open_market},"updated_israel":"test"}

SKIP = {"gold","day"}
fails=[]
def check(name, got, want):
    ok = got==want
    print(("PASS " if ok else "FAIL ")+name)
    if not ok:
        print("   got :",got); print("   want:",want); fails.append(name)

# 1 fresh entry
b=FakeBroker()
B.reconcile(b, state([pos("SOFI")]), {}, SKIP)
check("1 fresh entry buys, no exits yet", b.acts, [("BUY","SOFI",28)])

# 2 held, no exits resting -> place exits
b=FakeBroker({"SOFI":28})
B.reconcile(b, state([pos("SOFI")]), {}, SKIP)
check("2 held with no protection places OCA exits", b.acts, [("EXITS","SOFI",28,11.72,13.81)])

# 3 exits already correct -> do nothing
b=FakeBroker({"SOFI":28}, {"SOFI":[FakeTrade("SOFI","STP",28,11.72),FakeTrade("SOFI","LMT",28,13.81)]})
B.reconcile(b, state([pos("SOFI")]), {}, SKIP)
check("3 correct exits are left alone", b.acts, [])

# 4 engine moved stop to breakeven -> replace exits
b=FakeBroker({"SOFI":28}, {"SOFI":[FakeTrade("SOFI","STP",28,11.72),FakeTrade("SOFI","LMT",28,13.81)]})
B.reconcile(b, state([pos("SOFI",stop=12.41)]), {}, SKIP)
check("4 stop moved to BE re-places exits", b.acts,
      [("CANCEL","SOFI","STP"),("CANCEL","SOFI","LMT"),("EXITS","SOFI",28,12.41,13.81)])

# 5 engine took half at T1 -> sell the difference
b=FakeBroker({"SOFI":28}, {"SOFI":[FakeTrade("SOFI","STP",28,11.72),FakeTrade("SOFI","LMT",28,13.81)]})
B.reconcile(b, state([pos("SOFI",left=14)]), {}, SKIP)
check("5 partial exit sells the difference", b.acts,
      [("CANCEL","SOFI","STP"),("CANCEL","SOFI","LMT"),("SELL","SOFI",14)])

# 6 engine closed it -> flatten
b=FakeBroker({"SOFI":28}, {"SOFI":[FakeTrade("SOFI","STP",28,11.72)]})
B.reconcile(b, state([]), {}, SKIP)
check("6 closed position is flattened", b.acts, [("CANCEL","SOFI","STP"),("SELL","SOFI",28)])

# 7 close_all flattens even what the engine still wants
b=FakeBroker({"SOFI":28,"NU":10}, {})
B.reconcile(b, state([pos("SOFI"),pos("NU")]), {"close_all":True}, SKIP)
check("7 close_all flattens everything", sorted(b.acts), sorted([("SELL","SOFI",28),("SELL","NU",10)]))

# 8 halt blocks new entries but keeps protection
b=FakeBroker({"SOFI":28})
B.reconcile(b, state([pos("SOFI"),pos("NU")]), {"halt":True}, SKIP)
check("8 halt blocks new, still protects held", b.acts, [("EXITS","SOFI",28,11.72,13.81)])

# 9 market closed blocks entries
b=FakeBroker()
B.reconcile(b, state([pos("SOFI")], open_market=False), {}, SKIP)
check("9 closed market opens nothing", b.acts, [])

# 10 gold and day are skipped
b=FakeBroker()
B.reconcile(b, state([pos("XAUUSD",kind="gold"),pos("RIVN",kind="day"),pos("SOFI")]), {}, SKIP)
check("10 gold and day are not routed", b.acts, [("BUY","SOFI",28)])

# 11 shorts refused
b=FakeBroker()
B.reconcile(b, state([pos("SNAP",side="short")]), {}, SKIP)
check("11 shorts refused", b.acts, [])

# 12 oversized notional quarantined, not opened
b=FakeBroker()
B.reconcile(b, state([pos("SOFI",qty=60)]), {}, SKIP)
check("12 oversized notional not opened", b.acts, [])

# 12b oversized while ALREADY HELD -> never liquidated
b=FakeBroker({"SOFI":60}, {"SOFI":[FakeTrade("SOFI","STP",60,11.72)]})
B.reconcile(b, state([pos("SOFI",qty=60)]), {}, SKIP)
check("12b quarantined position is never sold", b.acts, [])

# 13 stop moved ABOVE entry (trailing in profit) is legitimate
b=FakeBroker({"SOFI":28})
B.reconcile(b, state([pos("SOFI",stop=13.0,entry=12.41,t1=13.81)]), {}, SKIP)
check("13 trailing stop above entry is honoured", b.acts, [("EXITS","SOFI",28,13.0,13.81)])

# 13b nonsense levels: target below stop -> quarantine, hold
b=FakeBroker({"SOFI":28})
B.reconcile(b, state([pos("SOFI",stop=13.0,entry=12.41,t1=12.0)]), {}, SKIP)
check("13b target below stop is quarantined", b.acts, [])

# 14 position cap - five wanted, four opened
b=FakeBroker()
five=[pos(t,entry=5.0,stop=4.5,t1=6.0,qty=20) for t in ("A","B","C","D","E")]
B.reconcile(b, state(five), {}, SKIP)
check("14 caps entries at 4", [a for a in b.acts if a[0]=="BUY"],
      [("BUY","A",20),("BUY","B",20),("BUY","C",20),("BUY","D",20)])

# 14b the 5th, if somehow already held, is quarantined not dumped
b=FakeBroker({"E":20})
B.reconcile(b, state(five), {}, SKIP)
check("14b over-cap held position not dumped", [a for a in b.acts if a[0]=="SELL"], [])

# 15 day routing enabled on request
b=FakeBroker()
B.reconcile(b, state([pos("RIVN",kind="day",entry=10.0,stop=9.5,t1=11.0,qty=30)]), {}, {"gold"})
check("15 day routes when asked", b.acts, [("BUY","RIVN",30)])

print()
print("FAILED:" , fails if fails else "none")
sys.exit(1 if fails else 0)
