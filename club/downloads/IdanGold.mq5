//+------------------------------------------------------------------+
//|                                                     IdanGold.mq5 |
//|                    Idan Trader - gold signals + automatic engine |
//+------------------------------------------------------------------+
//  WHAT THIS IS
//    A signal engine for gold that also executes. It draws what it sees on
//    the chart and trades it by itself, one position at a time.
//
//  WHAT IT IS NOT
//    It is not a grid and it is not a martingale. There is no averaging
//    down, no rescue leg and no basket anywhere in this file. The previous
//    robot on this machine had all three and gave back 1,472 dollars over
//    1,804 trades with a profit factor of 0.638. The shape of that failure
//    was: many tiny wins, a few enormous losses. This file is built to have
//    the opposite shape - small capped losses, winners allowed to run.
//
//  HOW IT LEARNS
//    Every tunable number lives in  MQL5\Files\IdanGold\params.json  and is
//    re-read while running. The daily review agent rewrites that file. The
//    engine also records every decision it makes, taken or skipped, plus the
//    bars themselves, so the agent can replay a proposed change against real
//    history instead of guessing.
//
//  ASCII only on purpose. MetaEditor is not reliable with other encodings.
//+------------------------------------------------------------------+
#property copyright "Idan Trader"
#property link      "https://elkingo18.github.io/idan-signals/"
#property version   "5.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- these are defaults. params.json overrides any of them at runtime.
input long   InpMagic              = 7700101;   // magic number
input double InpRiskPct            = 1.0;       // risk per trade, % of equity
input bool   InpEnabled            = true;      // trading enabled
input bool   InpDrawOnChart        = true;      // draw signals on the chart
input string InpFolder             = "IdanGold";// folder under MQL5\Files

#define P_FILE   "params.json"
#define S_FILE   "status.json"
#define T_FILE   "trades.csv"
#define G_FILE   "signals.csv"


//+------------------------------------------------------------------+
//| every tunable in one place                                       |
//+------------------------------------------------------------------+
struct Params
  {
   bool     enabled;
   double   risk_pct;
   //--- regime, on H1
   int      h1_fast;
   int      h1_slow;
   int      adx_period;
   double   adx_min;
   //--- setup, on M15
   int      ema_fast;
   int      ema_slow;
   int      rsi_period;
   double   rsi_long_max;      // do not buy into an exhausted push
   double   rsi_short_min;
   double   pullback_atr;      // how close to the fast EMA counts as a pullback
   int      pullback_lookback; // bars allowed since the touch
   //--- WHICH ENTRY RULE DECIDES. Added 11.8.2026.
   //--- 0 = the classic setup above: H1 trend, M15 EMA agreement, a pullback to
   //---     the fast EMA, a resumption bar, RSI and the structure filters.
   //--- 1 = the burst rule. "price moved burst_atr x ATR in burst_bars bars -
   //---     go with it." Nothing else. No H1 regime, no EMA, no pullback, no
   //---     RSI, no fib / fvg / sweep. Measured 11.8.2026 on 2.3 years of M15
   //---     history that the search never touched: +0.1518R over 3731 trades,
   //---     positive LONG and SHORT, positive every year, and a permutation
   //---     test that replaced the direction call with a coin flip 200 times
   //---     could not match it once (p < 0.005, 3.62 sd). The classic rule over
   //---     the SAME years and the same exit machinery scored +0.0196R above a
   //---     coin flip; this scored +0.0525R.
   //--- Switching back is this one number. No recompile.
   int      entry_mode;
   int      burst_bars;        // lookback in M15 bars. 4 = one hour.
   double   burst_atr;         // size of the move, in ATR, that counts as a burst
   //--- THE RISK LADDER. Added 12.8.2026 for the fresh 2,500$ account.
   //--- Idan's instruction, verbatim: "risk 3-9% per trade, and don't hurt the
   //--- win/loss ratio". Sizing cannot touch the ratio (it never changes entry
   //--- or exit), and a fixed number is not a 3-9% policy - so the percent now
   //--- BREATHES with the account, measured on 4,000 bootstrapped months:
   //--- press toward 9% while the account sits at its high-water mark, ease
   //--- down as a drawdown deepens, survival size when badly wounded. That
   //--- combination kept almost all of flat-6%'s growth while cutting the
   //--- 1-in-20 worst hole from -64% to -51% and halving risk to 0.2%.
   //--- risk_mode 0 = the old behaviour (fixed_lots / flat risk_pct).
   int      risk_mode;
   double   rp_peak;           // at or above the high-water mark
   double   rp_norm;           // drawdown up to dd1_pct
   double   rp_dd1;            // drawdown between dd1_pct and dd2_pct
   double   rp_dd2;            // deeper than dd2_pct - survival size
   double   dd1_pct;           // first band edge, percent below the peak
   double   dd2_pct;           // second band edge
   //--- risk shape
   int      atr_period;
   double   sl_atr;            // stop = sl_atr * ATR
   double   tp1_r;             // first target in R
   double   tp2_r;             // second target in R
   double   tp1_close_frac;    // fraction closed at tp1
   double   be_at_r;           // move to break even at this R
   double   trail_atr;         // trail distance after tp1, in ATR
   //--- gates
   double   max_spread_frac;   // spread / stop distance. the old engine died here
   double   atr_min_points;
   double   atr_max_points;
   string   blocked_hours;     // server hours, comma separated
   int      max_trades_day;
   double   daily_loss_stop_pct;
   int      max_consec_losses;
   int      cooldown_bars;
   //--- market structure filters
   int      use_fib;           // entry must sit inside the retracement zone of the last swing
   double   fib_lo;
   double   fib_hi;
   int      swing_k;           // pivot half width
   int      use_fvg;           // require an unfilled imbalance in the trade direction
   int      fvg_lookback;
   double   fvg_min_atr;
   int      use_sweep;         // require liquidity to have been taken and reclaimed
   int      sweep_lookback;
   //--- profit lock: once the best point reaches lock_at_r, the stop follows
   //--- lock_give_r behind it and never goes back. 0 = off.
   double   lock_at_r;
   double   lock_give_r;
   //--- how much room the trade gets as it gets further ahead. the stop gives
   //--- back the LARGER of lock_give_r and peak_r * lock_give_frac.
   //--- 0 = a fixed leash. measured better than any growing one, because the
   //--- ratchet already lets a real trend run; a longer leash only hands more
   //--- back every time the trend pauses.
   double   lock_give_frac;
   //--- fixed position size in lots. 0 = size by risk_pct, which is the sane
   //--- behaviour. anything above 0 overrides the risk calculation entirely.
   double   fixed_lots;
   //--- CEILING ON THE MONEY, NOT ON THE LOT. Added 7.8.2026 after the evening
   //--- of the 7th: a fixed lot freezes the SIZE, but the stop is 1 x ATR, so
   //--- the DOLLARS at stake float with volatility. The same -1R that cost
   //--- 59.77 at 03:13 that morning cost 109.91 at 16:57 that evening - the
   //--- lot never moved, the ATR nearly doubled. This is the number that says
   //--- "whatever the lot setting is, never put more than this percentage of
   //--- the account on one trade". 0 = no ceiling (old behaviour).
   double   max_stake_pct;
   //--- trading timeframe in minutes: 1, 5, 15, 30 or 60
   int      tf_minutes;
   //--- housekeeping
   int      version;
  };

Params      P;
CTrade      Trade;
CPositionInfo Pos;
CSymbolInfo Sym;

string   g_sym;
ENUM_TIMEFRAMES g_tf = PERIOD_M15;   // trading timeframe, set from params
int      h_ema_f, h_ema_s, h_atr, h_rsi, h_h1f, h_h1s, h_adx;
datetime g_last_bar     = 0;
datetime g_params_seen  = 0;
ulong    g_ticket       = 0;
double   g_entry        = 0, g_stop0 = 0, g_risk_pts = 0;
bool     g_tp1_done     = false;
double   g_peak_r       = 0;         // best R this position has reached
int      g_dir          = 0;         // 1 long, -1 short
double   g_day_start_eq = 0;
int      g_trades_today = 0;
int      g_consec_loss  = 0;
int      g_cooldown     = 0;
int      g_day          = -1;
string   g_last_reason  = "";
int      g_signals      = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_sym = _Symbol;
   if(!Sym.Name(g_sym))
     {
      Print("cannot select symbol ", g_sym);
      return(INIT_FAILED);
     }

   SetDefaults();
   LoadParams(true);
   g_tf = TFFromMinutes(P.tf_minutes);

   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetTypeFillingBySymbol(g_sym);
   Trade.SetDeviationInPoints(30);

   if(!BuildHandles())
      return(INIT_FAILED);

   EnsureHeaders();
   g_day_start_eq = AccountInfoDouble(ACCOUNT_EQUITY);
   g_day          = DayOfYearNow();
   LoadHighWater();
   AdoptExistingPosition();

   EventSetTimer(20);
   Print("IdanGold ready on ", g_sym, "  params v", P.version,
         "  enabled=", P.enabled, "  risk=", P.risk_pct, "%");
   WriteStatus();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, "IG_");
   WriteStatus();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   LoadParams(false);      // pick up whatever the agent wrote
   WriteStatus();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!Sym.RefreshRates())
      return;

   RollDay();
   UpdateHighWater();      // the ladder's reference point - writes only on a new peak
   ManageOpen();           // stops and targets need every tick

   datetime bt = iTime(g_sym, g_tf, 0);
   if(bt == g_last_bar)
      return;
   g_last_bar = bt;        // a new M15 bar just opened; bar 1 is closed

   RecordBar();

   if(g_cooldown > 0)
      g_cooldown--;

   if(HasPosition())
     {
      LogSignal("hold", 0, "position open");
      return;
     }

   EvaluateAndMaybeTrade();
  }

ENUM_TIMEFRAMES TFFromMinutes(int m)
  {
   if(m == 1)  return(PERIOD_M1);
   if(m == 5)  return(PERIOD_M5);
   if(m == 30) return(PERIOD_M30);
   if(m == 60) return(PERIOD_H1);
   return(PERIOD_M15);
  }

//+------------------------------------------------------------------+
//| defaults - deliberately conservative                             |
//+------------------------------------------------------------------+
void SetDefaults()
  {
   P.enabled            = InpEnabled;
   P.tf_minutes         = 15;
   P.risk_pct           = InpRiskPct;
   P.h1_fast            = 50;
   P.h1_slow            = 200;
   P.adx_period         = 14;
   P.adx_min            = 20.0;
   P.ema_fast           = 20;
   P.ema_slow           = 50;
   P.rsi_period         = 14;
   P.rsi_long_max       = 72.0;
   P.rsi_short_min      = 28.0;
   P.pullback_atr       = 0.60;
   P.pullback_lookback  = 6;
   //--- default is the classic rule, so a params.json that predates 11.8.2026
   //--- behaves exactly as it did before. Nothing changes until it is asked to.
   P.entry_mode         = 0;
   P.burst_bars         = 4;
   P.burst_atr          = 2.00;
   P.risk_mode          = 0;      // off by default - nothing changes until asked
   P.rp_peak            = 9.0;
   P.rp_norm            = 6.0;
   P.rp_dd1             = 4.5;
   P.rp_dd2             = 3.0;
   P.dd1_pct            = 15.0;
   P.dd2_pct            = 30.0;
   P.atr_period         = 14;
   P.sl_atr             = 1.60;
   P.tp1_r              = 1.50;
   P.tp2_r              = 3.00;
   //--- Both of these are OFF, and that is a finding rather than an omission.
   //--- Replayed over 60,000 real XAUUSD bars, moving the stop to break even
   //--- and banking half at the first target cost 0.064R per trade with
   //--- p = 0.005. Nearly 15% of trades were ending at zero because the stop
   //--- had been walked up to the entry and then tapped by noise.
   P.tp1_close_frac     = 0.00;
   P.be_at_r            = 99.0;
   P.trail_atr          = 2.00;
   P.max_spread_frac    = 0.10;   // spread may not eat more than 10% of the stop
   P.atr_min_points     = 60.0;
   P.atr_max_points     = 1200.0;
   P.blocked_hours      = "";
   P.max_trades_day     = 4;
   P.daily_loss_stop_pct= 3.0;
   P.max_consec_losses  = 3;
   P.cooldown_bars      = 8;
   //--- Fibonacci is ON. It earned it: on the window the search never saw, it
   //--- lifted expectancy from 0.122R to 0.376R with t = 2.33 and halved the
   //--- drawdown. The wide zone and the wide pivot are deliberate - the deep
   //--- narrow variants looked better still on a dozen trades, which is noise.
   P.use_fib            = 1;
   P.fib_lo             = 0.236;
   P.fib_hi             = 0.618;
   P.swing_k            = 8;
   //--- These two are implemented and switched off. They did not clear the
   //--- out-of-sample bar today. The review agent can turn them on by itself
   //--- the day the data earns it, without anyone recompiling anything.
   P.use_fvg            = 0;
   P.fvg_lookback       = 48;
   P.fvg_min_atr        = 0.35;
   P.use_sweep          = 0;
   P.sweep_lookback     = 20;
   //--- Off until the data earns it, like everything else here. The sweep on
   //--- 3.8.2026 said lock_at_r 1.0 with lock_give_r 0.3 roughly halves the
   //--- drawdown out of sample and makes more money after costs, but it does
   //--- it by taking more trades for a smaller edge each, so the review gate
   //--- rejects it on per-trade edge. That disagreement is a real one and is
   //--- written up in strategy/profit-lock.md.
   P.lock_at_r          = 0.0;
   P.lock_give_r        = 1.0;
   P.lock_give_frac     = 0.0;
   P.fixed_lots         = 0.0;
   P.max_stake_pct      = 0.0;
   P.version            = 0;
  }

//+------------------------------------------------------------------+
bool BuildHandles()
  {
   h_ema_f = iMA (g_sym, g_tf, P.ema_fast, 0, MODE_EMA, PRICE_CLOSE);
   h_ema_s = iMA (g_sym, g_tf, P.ema_slow, 0, MODE_EMA, PRICE_CLOSE);
   h_atr   = iATR(g_sym, g_tf, P.atr_period);
   h_rsi   = iRSI(g_sym, g_tf, P.rsi_period, PRICE_CLOSE);
   h_h1f   = iMA (g_sym, PERIOD_H1,  P.h1_fast, 0, MODE_EMA, PRICE_CLOSE);
   h_h1s   = iMA (g_sym, PERIOD_H1,  P.h1_slow, 0, MODE_EMA, PRICE_CLOSE);
   h_adx   = iADX(g_sym, PERIOD_H1,  P.adx_period);

   if(h_ema_f==INVALID_HANDLE || h_ema_s==INVALID_HANDLE || h_atr==INVALID_HANDLE ||
      h_rsi==INVALID_HANDLE   || h_h1f==INVALID_HANDLE   || h_h1s==INVALID_HANDLE ||
      h_adx==INVALID_HANDLE)
     {
      Print("indicator handle failed");
      return(false);
     }
   return(true);
  }

void ReleaseHandles()
  {
   IndicatorRelease(h_ema_f); IndicatorRelease(h_ema_s); IndicatorRelease(h_atr);
   IndicatorRelease(h_rsi);   IndicatorRelease(h_h1f);   IndicatorRelease(h_h1s);
   IndicatorRelease(h_adx);
  }

//+------------------------------------------------------------------+
double Buf(int handle, int buffer, int shift)
  {
   double v[];
   if(CopyBuffer(handle, buffer, shift, 1, v) != 1)
      return(EMPTY_VALUE);
   return(v[0]);
  }


//+------------------------------------------------------------------+
//| market structure                                                  |
//| A pivot is only knowable k bars after it printed, so every lookup |
//| here starts at shift k+1. Nothing in this section can see forward.|
//+------------------------------------------------------------------+
bool LastPivot(bool wantHigh, int k, int maxLook, double &price, int &shift)
  {
   for(int j = k + 1; j <= maxLook; j++)
     {
      bool ok = true;
      double v = wantHigh ? iHigh(g_sym, g_tf, j) : iLow(g_sym, g_tf, j);
      for(int m = j - k; m <= j + k; m++)
        {
         if(m == j)
            continue;
         double w = wantHigh ? iHigh(g_sym, g_tf, m) : iLow(g_sym, g_tf, m);
         if(wantHigh && w > v) { ok = false; break; }
         if(!wantHigh && w < v) { ok = false; break; }
        }
      if(ok)
        {
         price = v;
         shift = j;
         return(true);
        }
     }
   return(false);
  }

//--- for a long: the last swing low, then a swing high after it, define the
//--- up leg. price should be sitting inside the retracement band of that leg.
bool FibZoneOk(int dir, double price, double &zlo, double &zhi)
  {
   double H = 0, L = 0;
   int hs = 0, ls = 0;
   int look = P.swing_k * 12 + 40;
   if(!LastPivot(true,  P.swing_k, look, H, hs)) return(false);
   if(!LastPivot(false, P.swing_k, look, L, ls)) return(false);
   double rng = H - L;
   if(rng <= 0) return(false);

   if(dir > 0)
     {
      if(hs > ls) return(false);          // the high must be the more recent one
      zhi = H - P.fib_lo * rng;
      zlo = H - P.fib_hi * rng;
     }
   else
     {
      if(ls > hs) return(false);
      zlo = L + P.fib_lo * rng;
      zhi = L + P.fib_hi * rng;
     }
   return(price >= zlo && price <= zhi);
  }

//--- a three bar imbalance that price has not yet filled
bool FvgOk(int dir)
  {
   double a = Buf(h_atr, 0, 1);
   if(a == EMPTY_VALUE || a <= 0) return(false);
   double last = iClose(g_sym, g_tf, 1);
   for(int j = 1; j <= P.fvg_lookback; j++)
     {
      double h0 = iHigh(g_sym, g_tf, j + 2);
      double l0 = iLow (g_sym, g_tf, j + 2);
      double h2 = iHigh(g_sym, g_tf, j);
      double l2 = iLow (g_sym, g_tf, j);
      if(dir > 0)
        {
         if(l2 > h0 && (l2 - h0) >= P.fvg_min_atr * a && last > h0)
            return(true);
        }
      else
        {
         if(h2 < l0 && (l0 - h2) >= P.fvg_min_atr * a && last < l0)
            return(true);
        }
     }
   return(false);
  }

//--- price dipped under the recent low and closed back above it
bool SweepOk(int dir)
  {
   for(int j = 1; j <= 4; j++)
     {
      double ref = 0;
      if(dir > 0)
        {
         ref = iLow(g_sym, g_tf, iLowest(g_sym, g_tf, MODE_LOW, P.sweep_lookback, j + 1));
         if(iLow(g_sym, g_tf, j) < ref && iClose(g_sym, g_tf, j) > ref)
            return(true);
        }
      else
        {
         ref = iHigh(g_sym, g_tf, iHighest(g_sym, g_tf, MODE_HIGH, P.sweep_lookback, j + 1));
         if(iHigh(g_sym, g_tf, j) > ref && iClose(g_sym, g_tf, j) < ref)
            return(true);
        }
     }
   return(false);
  }

void DrawZone(int dir, double zlo, double zhi)
  {
   if(!InpDrawOnChart) return;
   string n = "IG_ZONE";
   datetime t0 = iTime(g_sym, g_tf, P.swing_k * 6);
   datetime t1 = iTime(g_sym, g_tf, 0) + 20 * 15 * 60;
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_RECTANGLE, 0, t0, zlo, t1, zhi);
   else
     {
      ObjectMove(0, n, 0, t0, zlo);
      ObjectMove(0, n, 1, t1, zhi);
     }
   ObjectSetInteger(0, n, OBJPROP_COLOR, dir > 0 ? clrSeaGreen : clrFireBrick);
   ObjectSetInteger(0, n, OBJPROP_FILL, true);
   ObjectSetInteger(0, n, OBJPROP_BACK, true);
   ObjectSetString(0, n, OBJPROP_TOOLTIP, "Fibonacci retracement zone");
  }

//+------------------------------------------------------------------+
//| the decision                                                     |
//+------------------------------------------------------------------+
void EvaluateAndMaybeTrade()
  {
   if(!P.enabled)                       { LogSignal("skip", 0, "disabled");        return; }
   if(g_cooldown > 0)                   { LogSignal("skip", 0, "cooldown");        return; }
   if(g_trades_today >= P.max_trades_day){ LogSignal("skip", 0, "max trades");     return; }

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_day_start_eq > 0)
     {
      double dd = (eq / g_day_start_eq - 1.0) * 100.0;
      if(dd <= -P.daily_loss_stop_pct)  { LogSignal("skip", 0, "daily loss stop"); return; }
     }

   int hr = HourNow();
   if(HourBlocked(hr))                  { LogSignal("skip", 0, "blocked hour");    return; }

   double atr = Buf(h_atr, 0, 1);
   if(atr == EMPTY_VALUE || atr <= 0)   { LogSignal("skip", 0, "no atr");          return; }
   double atr_pts = atr / _Point;
   if(atr_pts < P.atr_min_points)       { LogSignal("skip", 0, "atr too low");     return; }
   if(atr_pts > P.atr_max_points)       { LogSignal("skip", 0, "atr too high");    return; }

   //--- last closed bar's extremes. Declared out here because the chart marker
   //--- at the bottom of this function needs them whichever entry rule ran.
   double h1 = iHigh(g_sym, g_tf, 1);
   double l1 = iLow (g_sym, g_tf, 1);

   int dir = 0;

   if(P.entry_mode == 1)
     {
      //--- THE BURST RULE. Everything above this line still applies - the daily
      //--- loss stop, the cooldown, the ATR band, the hour list - because those
      //--- are safety, not signal. Everything the classic rule uses to pick a
      //--- direction is deliberately absent: no H1 regime, no EMA agreement, no
      //--- pullback, no resumption bar, no RSI, no fib / fvg / sweep.
      //---
      //--- The whole rule: price has moved burst_atr x ATR over the last
      //--- burst_bars bars. Go with it.
      //---
      //--- Bar 1 is the last CLOSED bar, so the move measured is
      //--- close[1] - close[1+burst_bars], exactly what was replayed. Using the
      //--- forming bar would be reading a number that has not finished yet.
      int nb = P.burst_bars;
      if(nb < 1) nb = 1;
      double cNow  = iClose(g_sym, g_tf, 1);
      double cThen = iClose(g_sym, g_tf, 1 + nb);
      if(cNow <= 0 || cThen <= 0)       { LogSignal("skip", 0, "no burst data");   return; }

      double move_r = (cNow - cThen) / atr;
      if(move_r >=  P.burst_atr)      dir =  1;
      else if(move_r <= -P.burst_atr) dir = -1;

      if(dir == 0)
        {
         LogSignal("skip", 0, "no burst " + DoubleToString(move_r, 2) + "atr");
         return;
        }
     }
   else
     {
      //--- regime, decided on H1 only
      double h1f = Buf(h_h1f, 0, 1);
      double h1s = Buf(h_h1s, 0, 1);
      double adx = Buf(h_adx, 0, 1);
      if(h1f == EMPTY_VALUE || h1s == EMPTY_VALUE || adx == EMPTY_VALUE)
                                        { LogSignal("skip", 0, "no regime");       return; }
      if(adx < P.adx_min)               { LogSignal("skip", 0, "adx flat");        return; }

      if(h1f > h1s) dir =  1;
      if(h1f < h1s) dir = -1;
      if(dir == 0)                      { LogSignal("skip", 0, "no trend");        return; }

      //--- setup, on M15: a pullback to the fast EMA that has resumed
      double ef = Buf(h_ema_f, 0, 1);
      double es = Buf(h_ema_s, 0, 1);
      double rsi= Buf(h_rsi,   0, 1);
      if(ef == EMPTY_VALUE || es == EMPTY_VALUE || rsi == EMPTY_VALUE)
                                        { LogSignal("skip", dir, "no setup data"); return; }

      if(dir > 0 && !(ef > es))         { LogSignal("skip", dir, "m15 against h1"); return; }
      if(dir < 0 && !(ef < es))         { LogSignal("skip", dir, "m15 against h1"); return; }

      bool touched = false;
      for(int i = 1; i <= P.pullback_lookback; i++)
        {
         double lo = iLow (g_sym, g_tf, i);
         double hi = iHigh(g_sym, g_tf, i);
         double e  = Buf(h_ema_f, 0, i);
         if(e == EMPTY_VALUE) continue;
         if(dir > 0 && lo <= e + P.pullback_atr * atr) { touched = true; break; }
         if(dir < 0 && hi >= e - P.pullback_atr * atr) { touched = true; break; }
        }
      if(!touched)                      { LogSignal("skip", dir, "no pullback");   return; }

      double c1 = iClose(g_sym, g_tf, 1);
      double o1 = iOpen (g_sym, g_tf, 1);
      double c2 = iClose(g_sym, g_tf, 2);

      //--- the resumption bar: closes in the trend direction, beyond the fast EMA,
      //--- and takes out the previous close. one bar, no pattern zoo.
      bool go = false;
      if(dir > 0) go = (c1 > o1 && c1 > ef && c1 > c2);
      else        go = (c1 < o1 && c1 < ef && c1 < c2);
      if(!go)                           { LogSignal("skip", dir, "no trigger");    return; }

      if(dir > 0 && rsi > P.rsi_long_max)  { LogSignal("skip", dir, "rsi stretched"); return; }
      if(dir < 0 && rsi < P.rsi_short_min) { LogSignal("skip", dir, "rsi stretched"); return; }

      //--- market structure. each of these can be switched on or off from
      //--- params.json by the review agent, without recompiling anything.
      if(P.use_fib)
        {
         double zlo = 0, zhi = 0;
         if(!FibZoneOk(dir, c1, zlo, zhi))
           {
            LogSignal("skip", dir, "outside fib zone");
            return;
           }
         DrawZone(dir, zlo, zhi);
        }
      if(P.use_fvg && !FvgOk(dir))     { LogSignal("skip", dir, "no imbalance");     return; }
      if(P.use_sweep && !SweepOk(dir)) { LogSignal("skip", dir, "no liquidity sweep"); return; }
     }

   //--- risk shape
   double sl_dist = P.sl_atr * atr;
   double stops   = (double)SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(sl_dist < stops * 1.2) sl_dist = stops * 1.2;

   double spread = (Sym.Ask() - Sym.Bid());
   if(sl_dist <= 0)                     { LogSignal("skip", dir, "no stop");       return; }
   if(spread / sl_dist > P.max_spread_frac)
     {
      LogSignal("skip", dir, "spread too wide");
      return;
     }

   double price = (dir > 0) ? Sym.Ask() : Sym.Bid();
   double sl    = (dir > 0) ? price - sl_dist : price + sl_dist;
   double tp    = (dir > 0) ? price + P.tp2_r * sl_dist : price - P.tp2_r * sl_dist;

   double lots  = LotsForRisk(sl_dist);
   if(lots <= 0)                        { LogSignal("skip", dir, "size too small"); return; }

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   bool ok = (dir > 0) ? Trade.Buy(lots, g_sym, 0.0, sl, tp, "IdanGold")
                       : Trade.Sell(lots, g_sym, 0.0, sl, tp, "IdanGold");
   if(!ok)
     {
      LogSignal("fail", dir, "order rejected " + IntegerToString(Trade.ResultRetcode()));
      Print("order failed ", Trade.ResultRetcode(), " ", Trade.ResultRetcodeDescription());
      return;
     }

   g_ticket   = Trade.ResultOrder();
   g_entry    = Trade.ResultPrice();
   if(g_entry <= 0) g_entry = price;
   g_stop0    = sl;
   g_risk_pts = MathAbs(g_entry - sl);
   g_tp1_done = false;
   g_peak_r   = 0;
   g_dir      = dir;
   g_trades_today++;
   g_signals++;

   //--- 13.8.2026, FAULT FOUND IN THE LIVE JOURNAL: the ladder printed
   //--- "risking 1.5% = 156.00" and the broker's copy of the order carried a
   //--- stop 4.46x further out - the hit cost 695.38, not 156. The lots and
   //--- the stop must describe the same trade, so after the fill the BROKER'S
   //--- stop is read back and, if the money at that stop exceeds what the
   //--- ladder asked for by more than 30%, the stop is pulled in to the sized
   //--- distance. The broker's book is the only one that pays out - it is the
   //--- one that gets verified.
   if(PositionSelect(g_sym))
     {
      double sl_broker = PositionGetDouble(POSITION_SL);
      double d_broker  = (sl_broker > 0) ? MathAbs(g_entry - sl_broker) : 0.0;
      if(sl_broker <= 0 || d_broker > sl_dist * 1.3)
        {
         double fix = (dir > 0) ? g_entry - sl_dist : g_entry + sl_dist;
         fix = NormalizeDouble(fix, _Digits);
         Print("STOP MISMATCH - sized for ", DoubleToString(sl_dist, 2),
               " away but the broker holds ", DoubleToString(d_broker, 2),
               " away. Repairing to ", DoubleToString(fix, 2), ".");
         bool repaired = Trade.PositionModify(g_sym, fix, tp);
         if(repaired)
           {
            g_stop0    = fix;
            g_risk_pts = MathAbs(g_entry - fix);
            Print("STOP REPAIRED - the trade now risks what the ladder asked for.");
           }
         else
           {
            Print("STOP REPAIR FAILED (", Trade.ResultRetcode(),
                  ") - closing the position, a trade with an unknown risk is not a trade.");
            if(!Trade.PositionClose(g_sym))
               Print("EMERGENCY CLOSE ALSO FAILED - human needed NOW.");
           }
        }
     }

   LogSignal("take", dir, "entry");
   DrawMark(dir, iTime(g_sym, g_tf, 1), (dir > 0) ? l1 : h1);
   WriteStatus();
  }

//+------------------------------------------------------------------+
//--- On 3.8.2026 this function sized a trade at 0.26 lots on a 1,000 dollar
//--- account with risk_pct = 3. The stop was 11.30 away and gold is 100 ounces
//--- to the lot, so the real money at risk was 293.80 - twenty nine percent of
//--- the account, on one trade, when three percent was asked for.
//--- The formula was not wrong. The broker's tick data was: SYMBOL_TRADE_TICK_VALUE
//--- and SYMBOL_TRADE_TICK_SIZE for this symbol do not agree with what a point
//--- actually pays, and the error is a factor of ten in the dangerous direction.
//--- So the tick figure is no longer trusted on its own. It is computed two ways
//--- and the more expensive answer wins. If they disagree badly, that is written
//--- to the log, because a silent ten-fold error is how accounts die.
//--- The high-water mark, persisted per account so a restart (or the nightly
//--- MetaTrader reload) never forgets how high the account has been. Without
//--- persistence the ladder would reset to "at the peak" after every reload
//--- and press 9% into the middle of a drawdown - the exact opposite of its job.
double g_high_water = 0.0;

string HighWaterFile()
  {
   return("IdanGold\\highwater_" +
          IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) + ".txt");
  }

void LoadHighWater()
  {
   g_high_water = AccountInfoDouble(ACCOUNT_EQUITY);
   int h = FileOpen(HighWaterFile(), FILE_READ | FILE_TXT | FILE_ANSI);
   if(h != INVALID_HANDLE)
     {
      double v = StringToDouble(FileReadString(h));
      FileClose(h);
      if(v > g_high_water) g_high_water = v;
     }
   Print("high-water mark loaded: ", DoubleToString(g_high_water, 2));
  }

void UpdateHighWater()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= g_high_water) return;
   g_high_water = eq;
   int h = FileOpen(HighWaterFile(), FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h != INVALID_HANDLE)
     {
      FileWriteString(h, DoubleToString(g_high_water, 2));
      FileClose(h);
     }
  }

double LadderPct(double eq)
  {
   if(g_high_water <= 0 || eq >= g_high_water) return(P.rp_peak);
   double dd = (1.0 - eq / g_high_water) * 100.0;
   if(dd <= P.dd1_pct) return(P.rp_norm);
   if(dd <= P.dd2_pct) return(P.rp_dd1);
   return(P.rp_dd2);
  }

double LotsForRisk(double sl_dist)
  {
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   double pct  = P.risk_pct;
   if(P.risk_mode == 1)
     {
      pct = LadderPct(eq);
      double dd = (g_high_water > 0) ? (1.0 - eq / g_high_water) * 100.0 : 0.0;
      Print("LADDER: equity ", DoubleToString(eq, 2), " is ",
            DoubleToString(dd, 1), "% below the high-water mark (",
            DoubleToString(g_high_water, 2), ") -> risking ",
            DoubleToString(pct, 1), "% = ",
            DoubleToString(eq * pct / 100.0, 2), " on this trade.");
     }
   double risk = eq * pct / 100.0;

   //--- FIXED SIZE. Set by the account owner on 3.8.2026 after being shown the
   //--- measurement three times: on the real 1,855 trade record, a fixed 0.16
   //--- lots empties this account after 7 trades, and 0.30 after 5. He asked
   //--- for it anyway, on a demo account, and it is his account. So it is built,
   //--- it is reversible with one click, and every single entry prints what
   //--- percentage of the account it is putting at stake - so the record can
   //--- never be argued about later.
   //--- ladder mode is percent-based by definition; a fixed lot would defeat
   //--- the whole idea of breathing with the account, so it is bypassed.
   if(P.fixed_lots > 0.0 && P.risk_mode != 1)
     {
      double fmin = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);
      double fmax = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MAX);
      double fstp = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);
      if(fstp <= 0) fstp = 0.01;
      double f = MathFloor(P.fixed_lots / fstp) * fstp;
      if(f < fmin) f = fmin;
      if(f > fmax) f = fmax;
      double cs_f = SymbolInfoDouble(g_sym, SYMBOL_TRADE_CONTRACT_SIZE);
      if(cs_f <= 0) cs_f = 100.0;
      double stake = sl_dist * f * cs_f;

      //--- The ceiling. It is applied to the MONEY, after the lot has been
      //--- chosen, because that is the quantity that actually varies. If the
      //--- lot has to come down to respect it, it comes down - and if even the
      //--- broker's minimum lot would break the ceiling, the trade is refused
      //--- outright rather than quietly taken at a size nobody agreed to. A
      //--- ceiling that rounds up is not a ceiling.
      if(P.max_stake_pct > 0.0 && eq > 0.0)
        {
         double limit = eq * P.max_stake_pct / 100.0;
         if(stake > limit)
           {
            double want = limit / (sl_dist * cs_f);
            want = MathFloor(want / fstp) * fstp;
            if(want < fmin)
              {
               Print("REFUSED - the ceiling allows ", DoubleToString(limit, 2),
                     " on this trade but the smallest lot the broker will take (",
                     DoubleToString(fmin, 2), ") already risks ",
                     DoubleToString(sl_dist * fmin * cs_f, 2),
                     ". Volatility is too high for this account size right now.");
               return(0);
              }
            Print("CEILING ", DoubleToString(P.max_stake_pct, 1), "% - cutting ",
                  DoubleToString(f, 2), " lots to ", DoubleToString(want, 2),
                  " so the trade risks ", DoubleToString(sl_dist * want * cs_f, 2),
                  " instead of ", DoubleToString(stake, 2), ". ATR is ",
                  DoubleToString(sl_dist, 2), ".");
            f = want;
            stake = sl_dist * f * cs_f;
           }
        }

      Print("FIXED SIZE ", DoubleToString(f, 2), " lots - this trade risks ",
            DoubleToString(stake, 2), " = ",
            DoubleToString(100.0 * stake / MathMax(eq, 1.0), 1),
            "% of the account. Owner's setting, not a calculated size.");
      return(NormalizeDouble(f, 2));
     }

   double tv   = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_VALUE);
   double ts   = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_SIZE);
   double cs   = SymbolInfoDouble(g_sym, SYMBOL_TRADE_CONTRACT_SIZE);

   double by_tick = (tv > 0 && ts > 0) ? (sl_dist / ts) * tv : 0.0;

   //--- the contract cross-check is only meaningful when the instrument settles
   //--- in the account currency. XAUUSD on a USD account does.
   double by_contract = 0.0;
   if(cs > 0 && SymbolInfoString(g_sym, SYMBOL_CURRENCY_PROFIT) ==
                AccountInfoString(ACCOUNT_CURRENCY))
      by_contract = sl_dist * cs;

   double loss_per_lot = MathMax(by_tick, by_contract);
   if(loss_per_lot <= 0) return(0);

   if(by_tick > 0 && by_contract > 0)
     {
      double ratio = by_contract / by_tick;
      if(ratio > 1.5 || ratio < 0.667)
         Print("WARNING sizing sources disagree by ", DoubleToString(ratio, 2),
               "x  (tick says ", DoubleToString(by_tick, 2),
               " per lot, contract says ", DoubleToString(by_contract, 2),
               "). using the larger.");
     }

   double lots = risk / loss_per_lot;

   double vmin = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MAX);
   double vstp = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);
   if(vstp <= 0) vstp = 0.01;

   lots = MathFloor(lots / vstp) * vstp;
   if(lots < vmin) return(0);          // too small to express the risk - skip, never round up
   if(lots > vmax) lots = vmax;

   //--- last line of defence. whatever the arithmetic said, a single trade may
   //--- not put more than the asked-for risk plus a rounding step at stake.
   double would_lose = lots * loss_per_lot;
   if(would_lose > risk * 1.25)
     {
      Print("REFUSED size ", lots, " lots - it risks ", DoubleToString(would_lose, 2),
            " but ", DoubleToString(risk, 2), " was asked for");
      return(0);
     }
   return(NormalizeDouble(lots, 2));
  }

//+------------------------------------------------------------------+
//| management - break even, partial, trail. no averaging, ever.      |
//+------------------------------------------------------------------+
void ManageOpen()
  {
   if(!HasPosition())
     {
      if(g_ticket != 0) OnPositionClosed();
      return;
     }

   if(!Pos.SelectByTicket(g_ticket)) return;

   double atr = Buf(h_atr, 0, 1);
   if(atr == EMPTY_VALUE || atr <= 0) return;

   double open  = Pos.PriceOpen();
   double sl    = Pos.StopLoss();
   double tp    = Pos.TakeProfit();
   double vol   = Pos.Volume();
   bool   isBuy = (Pos.PositionType() == POSITION_TYPE_BUY);
   double cur   = isBuy ? Sym.Bid() : Sym.Ask();
   if(g_risk_pts <= 0) g_risk_pts = MathAbs(open - sl);
   if(g_risk_pts <= 0) return;

   double r_now = isBuy ? (cur - open) / g_risk_pts : (open - cur) / g_risk_pts;
   if(r_now > g_peak_r) g_peak_r = r_now;

   //--- Reaching the first target and banking part of the position are two
   //--- different events. They used to be one: g_tp1_done was only ever set
   //--- inside the partial-close block, which is gated on tp1_close_frac > 0.
   //--- With partial closing switched off - which it has been since the review
   //--- measured it as harmful - the flag stayed false forever and the trail
   //--- below never ran once. Nothing moved the stop, ever. A trade could go
   //--- far into profit and hand every cent of it back, and that is exactly
   //--- what it did. The flag now follows price, and only the partial depends
   //--- on the fraction.
   if(!g_tp1_done && r_now >= P.tp1_r)
     {
      if(P.tp1_close_frac > 0.0)
        {
         double vstp = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);
         double vmin = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);
         if(vstp <= 0) vstp = 0.01;
         double part = MathFloor((vol * P.tp1_close_frac) / vstp) * vstp;
         if(part >= vmin && (vol - part) >= vmin)
           {
            if(Trade.PositionClosePartial(g_ticket, part))
               Print("tp1 partial closed ", part);
           }
        }
      g_tp1_done = true;
     }

   //--- the new stop is worked out first and applied once, so that the three
   //--- rules below cannot fight each other with three separate order changes.
   double want = sl;

   //--- break even
   if(r_now >= P.be_at_r)
     {
      double be = open + (isBuy ? 1 : -1) * (2 * _Point);
      if(isBuy ? (be > want) : (be < want)) want = be;
     }

   //--- trail once the trade is meaningfully in profit. Used to wait for
   //--- tp1; 13.8.2026 Idan asked for a stop that follows the price once the
   //--- trade is winning, so the trail now arms at +1R on its own - the
   //--- profit lock below already covers the ground before that.
   if(P.trail_atr > 0.0 && (g_tp1_done || r_now >= 1.0))
     {
      double t = isBuy ? cur - P.trail_atr * atr : cur + P.trail_atr * atr;
      if(isBuy ? (t > want) : (t < want)) want = t;
     }

   //--- Profit lock. Once the trade's best point has reached lock_at_r, the
   //--- stop follows lock_give_r behind that best point and never goes back.
   //--- This is what Idan asked for on 3.8.2026, put in R instead of dollars
   //--- so it keeps meaning the same thing as the account grows.
   if(P.lock_at_r > 0.0 && g_peak_r >= P.lock_at_r)
     {
      double give = P.lock_give_r;
      double grow = g_peak_r * P.lock_give_frac;
      if(grow > give) give = grow;
      double keep = (g_peak_r - give) * g_risk_pts;
      double lock = open + (isBuy ? 1 : -1) * keep;
      if(isBuy ? (lock > want) : (lock < want)) want = lock;
     }

   if(isBuy ? (want > sl) : (want < sl)) ModifyStop(want, tp);
  }

void ModifyStop(double sl, double tp)
  {
   sl = NormalizeDouble(sl, _Digits);
   double stops = (double)SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double cur   = (Pos.PositionType() == POSITION_TYPE_BUY) ? Sym.Bid() : Sym.Ask();
   if(MathAbs(cur - sl) < stops) return;
   Trade.PositionModify(g_ticket, sl, tp);
  }

//+------------------------------------------------------------------+
bool HasPosition()
  {
   if(g_ticket == 0) return(false);
   if(!PositionSelectByTicket(g_ticket)) return(false);
   if(PositionGetInteger(POSITION_MAGIC) != InpMagic) return(false);
   return(true);
  }

//--- if the terminal restarted while a trade was live, take it back over
void AdoptExistingPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_sym)    continue;
      g_ticket   = t;
      g_entry    = PositionGetDouble(POSITION_PRICE_OPEN);
      g_stop0    = PositionGetDouble(POSITION_SL);
      g_risk_pts = MathAbs(g_entry - g_stop0);
      g_dir      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      g_tp1_done = false;
      g_peak_r   = 0;
      Print("adopted running position ", t);
      return;
     }
  }

//+------------------------------------------------------------------+
//| a position just disappeared - write the trade down                |
//+------------------------------------------------------------------+
void OnPositionClosed()
  {
   ulong t = g_ticket;
   g_ticket = 0;

   if(!HistorySelect(TimeCurrent() - 7 * 24 * 3600, TimeCurrent() + 60))
     { g_dir = 0; return; }

   double profit = 0, vol = 0, price_out = 0, price_in = 0;
   datetime t_in = 0, t_out = 0;
   int deals = 0;

   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetInteger(d, DEAL_POSITION_ID) != (long)t) continue;
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      double pr  = HistoryDealGetDouble(d, DEAL_PRICE);
      double pf  = HistoryDealGetDouble(d, DEAL_PROFIT)
                 + HistoryDealGetDouble(d, DEAL_SWAP)
                 + HistoryDealGetDouble(d, DEAL_COMMISSION);
      datetime tm = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      if(entry == DEAL_ENTRY_IN)
        { price_in = pr; t_in = tm; vol += HistoryDealGetDouble(d, DEAL_VOLUME); }
      else
        { price_out = pr; if(tm > t_out) t_out = tm; profit += pf; }
      deals++;
     }
   if(deals == 0) { g_dir = 0; return; }

   double r = 0;
   if(g_risk_pts > 0 && price_in > 0 && price_out > 0)
      r = ((g_dir > 0) ? (price_out - price_in) : (price_in - price_out)) / g_risk_pts;

   if(profit > 0) g_consec_loss = 0;
   else
     {
      g_consec_loss++;
      if(g_consec_loss >= P.max_consec_losses)
        {
         g_cooldown    = P.cooldown_bars;
         g_consec_loss = 0;
         Print("cooldown for ", g_cooldown, " bars after consecutive losses");
        }
     }

   string row = StringFormat("%s,%I64u,%s,%.2f,%.5f,%.5f,%.2f,%.3f,%s,%d,%d",
                  TimeToString(t_out, TIME_DATE | TIME_SECONDS), t,
                  (g_dir > 0 ? "BUY" : "SELL"), vol, price_in, price_out,
                  profit, r, TimeToString(t_in, TIME_DATE | TIME_SECONDS),
                  P.version, g_tp1_done ? 1 : 0);
   Append(T_FILE, row);

   g_dir = 0;
   g_risk_pts = 0;
   WriteStatus();
  }

//+------------------------------------------------------------------+
//| bookkeeping                                                       |
//+------------------------------------------------------------------+
int DayOfYearNow()
  {
   MqlDateTime s; TimeToStruct(TimeCurrent(), s);
   return(s.day_of_year);
  }

int HourNow()
  {
   MqlDateTime s; TimeToStruct(TimeCurrent(), s);
   return(s.hour);
  }

void RollDay()
  {
   int d = DayOfYearNow();
   if(d == g_day) return;
   g_day          = d;
   g_day_start_eq = AccountInfoDouble(ACCOUNT_EQUITY);
   g_trades_today = 0;
   g_consec_loss  = 0;
   LoadParams(true);
   Print("new day. equity ", g_day_start_eq, " params v", P.version);
  }

bool HourBlocked(int hr)
  {
   if(StringLen(P.blocked_hours) == 0) return(false);
   string parts[];
   int n = StringSplit(P.blocked_hours, ',', parts);
   for(int i = 0; i < n; i++)
     {
      string s = parts[i];
      StringTrimLeft(s); StringTrimRight(s);
      if(StringLen(s) == 0) continue;
      if((int)StringToInteger(s) == hr) return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| files                                                             |
//+------------------------------------------------------------------+
string Path(string name) { return(InpFolder + "\\" + name); }
string BarsFile() { return("bars_m" + IntegerToString(P.tf_minutes) + ".csv"); }

void Append(string name, string line)
  {
   int h = FileOpen(Path(name), FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, line + "\r\n");
   FileClose(h);
  }

bool Exists(string name) { return(FileIsExist(Path(name))); }

void EnsureHeaders()
  {
   if(!Exists(T_FILE))
      Append(T_FILE, "closed,ticket,side,volume,entry,exit,profit,r,opened,params_v,tp1");
   if(!Exists(G_FILE))
      Append(G_FILE, "time,decision,dir,reason,close,ema_f,ema_s,atr_pts,rsi,adx,h1_fast,h1_slow,spread_pts,hour,equity");
   if(!Exists(BarsFile()))
      Append(BarsFile(), "time,open,high,low,close,tickvol,ema_f,ema_s,atr,rsi,adx,h1f,h1s,spread_pts");
  }

//--- every decision, taken or skipped, with the numbers behind it
void LogSignal(string decision, int dir, string reason)
  {
   g_last_reason = decision + ": " + reason;
   string row = StringFormat("%s,%s,%d,%s,%.5f,%.5f,%.5f,%.1f,%.2f,%.2f,%.5f,%.5f,%.1f,%d,%.2f",
      TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), decision, dir, reason,
      iClose(g_sym, g_tf, 1),
      Buf(h_ema_f, 0, 1), Buf(h_ema_s, 0, 1),
      Buf(h_atr, 0, 1) / _Point, Buf(h_rsi, 0, 1), Buf(h_adx, 0, 1),
      Buf(h_h1f, 0, 1), Buf(h_h1s, 0, 1),
      (Sym.Ask() - Sym.Bid()) / _Point, HourNow(),
      AccountInfoDouble(ACCOUNT_EQUITY));
   Append(G_FILE, row);
  }

//--- the replay dataset the review agent needs
void RecordBar()
  {
   string row = StringFormat("%s,%.5f,%.5f,%.5f,%.5f,%I64d,%.5f,%.5f,%.5f,%.2f,%.2f,%.5f,%.5f,%.1f",
      TimeToString(iTime(g_sym, g_tf, 1), TIME_DATE | TIME_SECONDS),
      iOpen (g_sym, g_tf, 1), iHigh(g_sym, g_tf, 1),
      iLow  (g_sym, g_tf, 1), iClose(g_sym, g_tf, 1),
      iTickVolume(g_sym, g_tf, 1),
      Buf(h_ema_f, 0, 1), Buf(h_ema_s, 0, 1), Buf(h_atr, 0, 1),
      Buf(h_rsi, 0, 1), Buf(h_adx, 0, 1), Buf(h_h1f, 0, 1), Buf(h_h1s, 0, 1),
      (Sym.Ask() - Sym.Bid()) / _Point);
   Append(BarsFile(), row);
  }

//+------------------------------------------------------------------+
//| params.json - flat, numbers and one string. re-read while running |
//+------------------------------------------------------------------+
void LoadParams(bool force)
  {
   if(!Exists(P_FILE))
     {
      if(force) WriteParamsTemplate();
      return;
     }
   datetime mod = (datetime)FileGetInteger(Path(P_FILE), FILE_MODIFY_DATE, false);
   if(!force && mod == g_params_seen) return;
   g_params_seen = mod;

   int h = FileOpen(Path(P_FILE), FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE) return;
   string txt = "";
   while(!FileIsEnding(h)) txt += FileReadString(h) + " ";
   FileClose(h);
   if(StringLen(txt) < 5) return;

   int old_v = P.version;
   int of = P.ema_fast, os = P.ema_slow, oa = P.atr_period, orsi = P.rsi_period;
   int ohf = P.h1_fast, ohs = P.h1_slow, oadx = P.adx_period;
   int otf = P.tf_minutes;

   P.enabled             = JBool(txt, "enabled",              P.enabled);
   P.risk_pct            = JNum (txt, "risk_pct",             P.risk_pct);
   P.h1_fast             = (int)JNum(txt, "h1_fast",           P.h1_fast);
   P.h1_slow             = (int)JNum(txt, "h1_slow",           P.h1_slow);
   P.adx_period          = (int)JNum(txt, "adx_period",        P.adx_period);
   P.adx_min             = JNum (txt, "adx_min",              P.adx_min);
   P.ema_fast            = (int)JNum(txt, "ema_fast",          P.ema_fast);
   P.ema_slow            = (int)JNum(txt, "ema_slow",          P.ema_slow);
   P.rsi_period          = (int)JNum(txt, "rsi_period",        P.rsi_period);
   P.rsi_long_max        = JNum (txt, "rsi_long_max",         P.rsi_long_max);
   P.rsi_short_min       = JNum (txt, "rsi_short_min",        P.rsi_short_min);
   P.pullback_atr        = JNum (txt, "pullback_atr",         P.pullback_atr);
   P.pullback_lookback   = (int)JNum(txt, "pullback_lookback", P.pullback_lookback);
   P.entry_mode          = (int)JNum(txt, "entry_mode",        P.entry_mode);
   P.burst_bars          = (int)JNum(txt, "burst_bars",        P.burst_bars);
   P.burst_atr           = JNum (txt, "burst_atr",             P.burst_atr);
   P.risk_mode           = (int)JNum(txt, "risk_mode",         P.risk_mode);
   P.rp_peak             = JNum (txt, "rp_peak",               P.rp_peak);
   P.rp_norm             = JNum (txt, "rp_norm",               P.rp_norm);
   P.rp_dd1              = JNum (txt, "rp_dd1",                P.rp_dd1);
   P.rp_dd2              = JNum (txt, "rp_dd2",                P.rp_dd2);
   P.dd1_pct             = JNum (txt, "dd1_pct",               P.dd1_pct);
   P.dd2_pct             = JNum (txt, "dd2_pct",               P.dd2_pct);
   P.atr_period          = (int)JNum(txt, "atr_period",        P.atr_period);
   P.sl_atr              = JNum (txt, "sl_atr",               P.sl_atr);
   P.tp1_r               = JNum (txt, "tp1_r",                P.tp1_r);
   P.tp2_r               = JNum (txt, "tp2_r",                P.tp2_r);
   P.tp1_close_frac      = JNum (txt, "tp1_close_frac",       P.tp1_close_frac);
   P.be_at_r             = JNum (txt, "be_at_r",              P.be_at_r);
   P.trail_atr           = JNum (txt, "trail_atr",            P.trail_atr);
   P.max_spread_frac     = JNum (txt, "max_spread_frac",      P.max_spread_frac);
   P.atr_min_points      = JNum (txt, "atr_min_points",       P.atr_min_points);
   P.atr_max_points      = JNum (txt, "atr_max_points",       P.atr_max_points);
   P.blocked_hours       = JStr (txt, "blocked_hours",        P.blocked_hours);
   P.max_trades_day      = (int)JNum(txt, "max_trades_day",    P.max_trades_day);
   P.daily_loss_stop_pct = JNum (txt, "daily_loss_stop_pct",  P.daily_loss_stop_pct);
   P.max_consec_losses   = (int)JNum(txt, "max_consec_losses", P.max_consec_losses);
   P.cooldown_bars       = (int)JNum(txt, "cooldown_bars",     P.cooldown_bars);
   P.use_fib             = (int)JNum(txt, "use_fib",           P.use_fib);
   P.fib_lo              = JNum (txt, "fib_lo",               P.fib_lo);
   P.fib_hi              = JNum (txt, "fib_hi",               P.fib_hi);
   P.swing_k             = (int)JNum(txt, "swing_k",           P.swing_k);
   P.use_fvg             = (int)JNum(txt, "use_fvg",           P.use_fvg);
   P.fvg_lookback        = (int)JNum(txt, "fvg_lookback",      P.fvg_lookback);
   P.fvg_min_atr         = JNum (txt, "fvg_min_atr",          P.fvg_min_atr);
   P.use_sweep           = (int)JNum(txt, "use_sweep",         P.use_sweep);
   P.sweep_lookback      = (int)JNum(txt, "sweep_lookback",    P.sweep_lookback);
   P.lock_at_r           = JNum (txt, "lock_at_r",            P.lock_at_r);
   P.lock_give_r         = JNum (txt, "lock_give_r",          P.lock_give_r);
   P.lock_give_frac      = JNum (txt, "lock_give_frac",       P.lock_give_frac);
   P.fixed_lots          = JNum (txt, "fixed_lots",           P.fixed_lots);
   P.max_stake_pct       = JNum (txt, "max_stake_pct",        P.max_stake_pct);
   P.tf_minutes          = (int)JNum(txt, "tf_minutes",        P.tf_minutes);
   P.version             = (int)JNum(txt, "version",           P.version);

   Clamp();
   g_tf = TFFromMinutes(P.tf_minutes);

   //--- indicator periods changed, so the handles must be rebuilt
   if(of != P.ema_fast || os != P.ema_slow || oa != P.atr_period ||
      orsi != P.rsi_period || ohf != P.h1_fast || ohs != P.h1_slow || oadx != P.adx_period ||
      otf != P.tf_minutes)
     {
      ReleaseHandles();
      if(!BuildHandles()) Print("WARNING could not rebuild handles after a params change");
      if(otf != P.tf_minutes)
        {
         g_last_bar = 0;
         EnsureHeaders();
         Print("timeframe switched to M", P.tf_minutes);
        }
     }

   if(P.version != old_v)
      Print("params reloaded, version ", P.version, " enabled=", P.enabled, " risk=", P.risk_pct);
  }

//--- the agent may set anything. these bounds only stop values that would
//--- make the engine nonsensical or unable to place an order at all.
void Clamp()
  {
   if(P.risk_pct <= 0)   P.risk_pct = 0.1;
   if(P.risk_pct > 5.0)  P.risk_pct = 5.0;
   if(P.sl_atr   <= 0.2) P.sl_atr   = 0.2;
   if(P.tp1_r    <= 0.1) P.tp1_r    = 0.1;
   if(P.tp2_r    <  P.tp1_r) P.tp2_r = P.tp1_r;
   if(P.tp1_close_frac < 0) P.tp1_close_frac = 0;
   if(P.tp1_close_frac > 0.9) P.tp1_close_frac = 0.9;
   if(P.ema_fast < 2)  P.ema_fast = 2;
   if(P.ema_slow < 3)  P.ema_slow = 3;
   if(P.atr_period < 2) P.atr_period = 2;
   if(P.rsi_period < 2) P.rsi_period = 2;
   if(P.h1_fast < 2)   P.h1_fast = 2;
   if(P.h1_slow < 3)   P.h1_slow = 3;
   if(P.adx_period < 2) P.adx_period = 2;
   if(P.pullback_lookback < 1)  P.pullback_lookback = 1;
   if(P.pullback_lookback > 50) P.pullback_lookback = 50;
   //--- an unknown entry_mode falls back to the classic rule rather than to
   //--- nothing. A typo in params.json must never leave the robot with no way
   //--- to pick a direction.
   if(P.entry_mode != 0 && P.entry_mode != 1) P.entry_mode = 0;
   if(P.burst_bars < 1)   P.burst_bars = 1;
   if(P.burst_bars > 200) P.burst_bars = 200;
   //--- burst_atr <= 0 would fire on literally every bar in both directions.
   if(P.burst_atr < 0.10) P.burst_atr = 0.10;
   if(P.burst_atr > 20.0) P.burst_atr = 20.0;
   //--- the ladder. 12% is the hard roof on any rung - above that, one bad
   //--- week ends the account, and no measurement has ever justified it.
   if(P.risk_mode != 0 && P.risk_mode != 1) P.risk_mode = 0;
   if(P.rp_peak < 0.1)  P.rp_peak = 0.1;   if(P.rp_peak > 12.0) P.rp_peak = 12.0;
   if(P.rp_norm < 0.1)  P.rp_norm = 0.1;   if(P.rp_norm > 12.0) P.rp_norm = 12.0;
   if(P.rp_dd1  < 0.1)  P.rp_dd1  = 0.1;   if(P.rp_dd1  > 12.0) P.rp_dd1  = 12.0;
   if(P.rp_dd2  < 0.1)  P.rp_dd2  = 0.1;   if(P.rp_dd2  > 12.0) P.rp_dd2  = 12.0;
   if(P.dd1_pct < 1.0)  P.dd1_pct = 1.0;   if(P.dd1_pct > 90.0) P.dd1_pct = 90.0;
   if(P.dd2_pct <= P.dd1_pct) P.dd2_pct = P.dd1_pct + 1.0;
   if(P.dd2_pct > 95.0) P.dd2_pct = 95.0;
   if(P.max_trades_day < 1) P.max_trades_day = 1;
   if(P.max_spread_frac <= 0) P.max_spread_frac = 0.01;
   if(P.daily_loss_stop_pct <= 0) P.daily_loss_stop_pct = 100.0;
   if(P.cooldown_bars < 0) P.cooldown_bars = 0;
   if(P.swing_k < 2)   P.swing_k = 2;
   if(P.swing_k > 40)  P.swing_k = 40;
   if(P.fib_lo < 0.0)  P.fib_lo = 0.0;
   if(P.fib_hi > 2.0)  P.fib_hi = 2.0;
   if(P.fib_hi < P.fib_lo) P.fib_hi = P.fib_lo;
   if(P.fvg_lookback < 2)   P.fvg_lookback = 2;
   if(P.fvg_lookback > 300) P.fvg_lookback = 300;
   if(P.sweep_lookback < 2)   P.sweep_lookback = 2;
   if(P.sweep_lookback > 300) P.sweep_lookback = 300;
   if(P.lock_at_r < 0)    P.lock_at_r = 0;
   if(P.lock_at_r > 10)   P.lock_at_r = 10;
   if(P.lock_give_r < 0.05) P.lock_give_r = 0.05;
   if(P.lock_give_frac < 0)   P.lock_give_frac = 0;
   if(P.lock_give_frac > 0.9) P.lock_give_frac = 0.9;
   if(P.fixed_lots < 0)    P.fixed_lots = 0;
   if(P.fixed_lots > 0.30) P.fixed_lots = 0.30;
   if(P.max_stake_pct < 0)    P.max_stake_pct = 0;
   if(P.max_stake_pct > 100)  P.max_stake_pct = 100;
   //--- giving back more than you locked is not a lock at all
   if(P.lock_at_r > 0 && P.lock_give_r >= P.lock_at_r)
      P.lock_give_r = P.lock_at_r * 0.5;
  }

double JNum(string t, string key, double def)
  {
   string k = "\"" + key + "\"";
   int p = StringFind(t, k);
   if(p < 0) return(def);
   p = StringFind(t, ":", p);
   if(p < 0) return(def);
   p++;
   string num = "";
   bool started = false;
   for(int i = p; i < StringLen(t); i++)
     {
      ushort ch = StringGetCharacter(t, i);
      if(ch == ' ' && !started) continue;
      if((ch >= '0' && ch <= '9') || ch == '.' || ch == '-' || ch == '+' || ch == 'e' || ch == 'E')
        { num += ShortToString(ch); started = true; continue; }
      break;
     }
   if(StringLen(num) == 0) return(def);
   return(StringToDouble(num));
  }

bool JBool(string t, string key, bool def)
  {
   string k = "\"" + key + "\"";
   int p = StringFind(t, k);
   if(p < 0) return(def);
   p = StringFind(t, ":", p);
   if(p < 0) return(def);
   int tp = StringFind(t, "true",  p);
   int fp = StringFind(t, "false", p);
   int cp = StringFind(t, ",",     p);
   int bp = StringFind(t, "}",     p);
   int end = (cp < 0) ? bp : ((bp < 0) ? cp : MathMin(cp, bp));
   if(end < 0) end = StringLen(t);
   if(tp >= 0 && tp < end) return(true);
   if(fp >= 0 && fp < end) return(false);
   return(def);
  }

string JStr(string t, string key, string def)
  {
   string k = "\"" + key + "\"";
   int p = StringFind(t, k);
   if(p < 0) return(def);
   p = StringFind(t, ":", p);
   if(p < 0) return(def);
   int q1 = StringFind(t, "\"", p);
   if(q1 < 0) return(def);
   int q2 = StringFind(t, "\"", q1 + 1);
   if(q2 < 0) return(def);
   return(StringSubstr(t, q1 + 1, q2 - q1 - 1));
  }

void WriteParamsTemplate()
  {
   int h = FileOpen(Path(P_FILE), FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) return;
   FileWriteString(h, ParamsJson());
   FileClose(h);
   Print("wrote a starting params.json");
  }

string ParamsJson()
  {
   string s = "{\n";
   s += "  \"version\": "               + IntegerToString(P.version)      + ",\n";
   s += "  \"tf_minutes\": "            + IntegerToString(P.tf_minutes)   + ",\n";
   s += "  \"enabled\": "               + (P.enabled ? "true" : "false")  + ",\n";
   s += "  \"risk_pct\": "              + DoubleToString(P.risk_pct, 3)   + ",\n";
   s += "  \"h1_fast\": "               + IntegerToString(P.h1_fast)      + ",\n";
   s += "  \"h1_slow\": "               + IntegerToString(P.h1_slow)      + ",\n";
   s += "  \"adx_period\": "            + IntegerToString(P.adx_period)   + ",\n";
   s += "  \"adx_min\": "               + DoubleToString(P.adx_min, 2)    + ",\n";
   s += "  \"ema_fast\": "              + IntegerToString(P.ema_fast)     + ",\n";
   s += "  \"ema_slow\": "              + IntegerToString(P.ema_slow)     + ",\n";
   s += "  \"rsi_period\": "            + IntegerToString(P.rsi_period)   + ",\n";
   s += "  \"rsi_long_max\": "          + DoubleToString(P.rsi_long_max,2)+ ",\n";
   s += "  \"rsi_short_min\": "         + DoubleToString(P.rsi_short_min,2)+ ",\n";
   s += "  \"pullback_atr\": "          + DoubleToString(P.pullback_atr,3)+ ",\n";
   s += "  \"pullback_lookback\": "     + IntegerToString(P.pullback_lookback) + ",\n";
   s += "  \"entry_mode\": "            + IntegerToString(P.entry_mode)   + ",\n";
   s += "  \"burst_bars\": "            + IntegerToString(P.burst_bars)   + ",\n";
   s += "  \"burst_atr\": "             + DoubleToString(P.burst_atr, 3)  + ",\n";
   s += "  \"risk_mode\": "             + IntegerToString(P.risk_mode)    + ",\n";
   s += "  \"rp_peak\": "               + DoubleToString(P.rp_peak, 2)    + ",\n";
   s += "  \"rp_norm\": "               + DoubleToString(P.rp_norm, 2)    + ",\n";
   s += "  \"rp_dd1\": "                + DoubleToString(P.rp_dd1, 2)     + ",\n";
   s += "  \"rp_dd2\": "                + DoubleToString(P.rp_dd2, 2)     + ",\n";
   s += "  \"dd1_pct\": "               + DoubleToString(P.dd1_pct, 1)    + ",\n";
   s += "  \"dd2_pct\": "               + DoubleToString(P.dd2_pct, 1)    + ",\n";
   s += "  \"atr_period\": "            + IntegerToString(P.atr_period)   + ",\n";
   s += "  \"sl_atr\": "                + DoubleToString(P.sl_atr, 3)     + ",\n";
   s += "  \"tp1_r\": "                 + DoubleToString(P.tp1_r, 3)      + ",\n";
   s += "  \"tp2_r\": "                 + DoubleToString(P.tp2_r, 3)      + ",\n";
   s += "  \"tp1_close_frac\": "        + DoubleToString(P.tp1_close_frac,3) + ",\n";
   s += "  \"be_at_r\": "               + DoubleToString(P.be_at_r, 3)    + ",\n";
   s += "  \"trail_atr\": "             + DoubleToString(P.trail_atr, 3)  + ",\n";
   s += "  \"max_spread_frac\": "       + DoubleToString(P.max_spread_frac,4) + ",\n";
   s += "  \"atr_min_points\": "        + DoubleToString(P.atr_min_points,1)  + ",\n";
   s += "  \"atr_max_points\": "        + DoubleToString(P.atr_max_points,1)  + ",\n";
   s += "  \"blocked_hours\": \""       + P.blocked_hours                 + "\",\n";
   s += "  \"max_trades_day\": "        + IntegerToString(P.max_trades_day)   + ",\n";
   s += "  \"daily_loss_stop_pct\": "   + DoubleToString(P.daily_loss_stop_pct,2) + ",\n";
   s += "  \"max_consec_losses\": "     + IntegerToString(P.max_consec_losses) + ",\n";
   s += "  \"cooldown_bars\": "         + IntegerToString(P.cooldown_bars) + ",\n";
   s += "  \"use_fib\": "               + IntegerToString(P.use_fib)       + ",\n";
   s += "  \"fib_lo\": "                + DoubleToString(P.fib_lo, 3)      + ",\n";
   s += "  \"fib_hi\": "                + DoubleToString(P.fib_hi, 3)      + ",\n";
   s += "  \"swing_k\": "               + IntegerToString(P.swing_k)       + ",\n";
   s += "  \"use_fvg\": "               + IntegerToString(P.use_fvg)       + ",\n";
   s += "  \"fvg_lookback\": "          + IntegerToString(P.fvg_lookback)  + ",\n";
   s += "  \"fvg_min_atr\": "           + DoubleToString(P.fvg_min_atr, 3) + ",\n";
   s += "  \"use_sweep\": "             + IntegerToString(P.use_sweep)     + ",\n";
   s += "  \"sweep_lookback\": "        + IntegerToString(P.sweep_lookback)+ ",\n";
   s += "  \"lock_at_r\": "             + DoubleToString(P.lock_at_r, 3)   + ",\n";
   s += "  \"lock_give_r\": "           + DoubleToString(P.lock_give_r, 3) + ",\n";
   s += "  \"lock_give_frac\": "        + DoubleToString(P.lock_give_frac,3) + ",\n";
   s += "  \"fixed_lots\": "            + DoubleToString(P.fixed_lots, 2)  + ",\n";
   s += "  \"max_stake_pct\": "         + DoubleToString(P.max_stake_pct,2) + "\n";
   s += "}\n";
   return(s);
  }

//+------------------------------------------------------------------+
//| status.json - what the dashboard reads                            |
//+------------------------------------------------------------------+
void WriteStatus()
  {
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double day_pnl = (g_day_start_eq > 0) ? (eq - g_day_start_eq) : 0.0;

   string pos = "null";
   if(HasPosition() && Pos.SelectByTicket(g_ticket))
     {
      pos = "{";
      pos += "\"ticket\": "   + IntegerToString((long)g_ticket) + ",";
      pos += "\"side\": \""   + (Pos.PositionType() == POSITION_TYPE_BUY ? "BUY" : "SELL") + "\",";
      pos += "\"volume\": "   + DoubleToString(Pos.Volume(), 2) + ",";
      pos += "\"entry\": "    + DoubleToString(Pos.PriceOpen(), _Digits) + ",";
      pos += "\"sl\": "       + DoubleToString(Pos.StopLoss(), _Digits) + ",";
      pos += "\"tp\": "       + DoubleToString(Pos.TakeProfit(), _Digits) + ",";
      pos += "\"price\": "    + DoubleToString(Pos.PriceCurrent(), _Digits) + ",";
      pos += "\"pnl\": "      + DoubleToString(Pos.Profit(), 2) + ",";
      pos += "\"peak_r\": "   + DoubleToString(g_peak_r, 2) + ",";
      pos += "\"tp1_done\": " + (g_tp1_done ? "true" : "false");
      pos += "}";
     }

   string s = "{\n";
   s += "  \"schema\": 1,\n";
   //--- The version of the CODE that is actually in memory, not the file on
   //--- disk. On 3.8.2026 the fixed build sat compiled on disk for hours while
   //--- MetaTrader kept running the old image - compiling does not swap the
   //--- running program, only a restart does - and there was no way to see it.
   //--- Now there is. If this number does not match the newest build, restart.
   //--- 6 = the build that knows about entry_mode / the burst rule (11.8.2026).
   //--- 7 = adds the risk ladder + persistent high-water mark (12.8.2026).
   //--- If status.json shows a lower number, MetaTrader is running an old
   //--- binary and the newer params fields are being ignored.
   s += "  \"code_version\": 8,\n";
   s += "  \"updated\": \""      + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "\",\n";
   s += "  \"symbol\": \""       + g_sym + "\",\n";
   s += "  \"account\": "        + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ",\n";
   s += "  \"server\": \""       + AccountInfoString(ACCOUNT_SERVER) + "\",\n";
   s += "  \"is_demo\": "        + ((AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO) ? "true" : "false") + ",\n";
   s += "  \"currency\": \""     + AccountInfoString(ACCOUNT_CURRENCY) + "\",\n";
   s += "  \"balance\": "        + DoubleToString(bal, 2) + ",\n";
   s += "  \"equity\": "         + DoubleToString(eq, 2) + ",\n";
   s += "  \"day_start_equity\": " + DoubleToString(g_day_start_eq, 2) + ",\n";
   s += "  \"day_pnl\": "        + DoubleToString(day_pnl, 2) + ",\n";
   s += "  \"trades_today\": "   + IntegerToString(g_trades_today) + ",\n";
   s += "  \"cooldown_bars\": "  + IntegerToString(g_cooldown) + ",\n";
   s += "  \"enabled\": "        + (P.enabled ? "true" : "false") + ",\n";
   s += "  \"params_version\": " + IntegerToString(P.version) + ",\n";
   //--- named, not numbered, so a human reading status.json can see at a glance
   //--- which rule is actually deciding trades right now.
   s += "  \"entry_rule\": \""   + (P.entry_mode == 1
        ? ("burst " + DoubleToString(P.burst_atr,1) + "atr/"
           + IntegerToString(P.burst_bars) + "bars")
        : "classic ema+pullback") + "\",\n";
   //--- what the NEXT trade would actually risk, so the phone page and the
   //--- log never have to guess which mode and which rung is in force.
   double eq_now = AccountInfoDouble(ACCOUNT_EQUITY);
   double pct_now = (P.risk_mode == 1) ? LadderPct(eq_now)
                    : (P.fixed_lots > 0.0 ? 0.0 : P.risk_pct);
   s += "  \"risk_mode\": \""    + (P.risk_mode == 1 ? "ladder 3-9 by drawdown" : (P.fixed_lots > 0.0 ? "fixed lots" : "flat percent")) + "\",\n";
   s += "  \"risk_now_pct\": "   + DoubleToString(pct_now, 2) + ",\n";
   s += "  \"high_water\": "     + DoubleToString(g_high_water, 2) + ",\n";
   s += "  \"risk_pct\": "       + DoubleToString(P.risk_pct, 2) + ",\n";
   s += "  \"tf_minutes\": "     + IntegerToString(P.tf_minutes) + ",\n";
   s += "  \"last_decision\": \"" + g_last_reason + "\",\n";
   s += "  \"spread_points\": "  + DoubleToString((Sym.Ask() - Sym.Bid()) / _Point, 1) + ",\n";
   s += "  \"position\": "       + pos + "\n";
   s += "}\n";

   int h = FileOpen(Path(S_FILE), FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) return;
   FileWriteString(h, s);
   FileClose(h);
  }

//+------------------------------------------------------------------+
void DrawMark(int dir, datetime when, double price)
  {
   if(!InpDrawOnChart) return;
   string n = "IG_" + IntegerToString((int)when);
   if(ObjectFind(0, n) >= 0) return;
   ObjectCreate(0, n, OBJ_ARROW, 0, when, price);
   ObjectSetInteger(0, n, OBJPROP_ARROWCODE, dir > 0 ? 233 : 234);
   ObjectSetInteger(0, n, OBJPROP_COLOR, dir > 0 ? clrSeaGreen : clrFireBrick);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, 2);
  }
//+------------------------------------------------------------------+
