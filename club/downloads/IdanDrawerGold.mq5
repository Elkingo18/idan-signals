//+------------------------------------------------------------------+
//|  IdanDrawerGold.mq5                                              |
//|  The spare copy of the bot we copy from - kept in the drawer.    |
//|                                                                  |
//|  This is not a guess and it is not a new idea.  Every number      |
//|  below was measured on 2026-08-18 from the master's own closed    |
//|  record: 80,538 positions, 2026-05-15 -> 2026-08-12, grouped      |
//|  into 46,500 baskets.  Where the measurement was noisy the        |
//|  header says so.                                                 |
//|                                                                  |
//|  WHAT THE MASTER ACTUALLY DOES                                   |
//|    one basket at a time, one direction  (buy and sell baskets     |
//|        overlapped in only 0.76% of cases - it does not hedge)     |
//|    direction is a coin flip.  Tested against 1/3/5/15/30/60/240   |
//|        minute returns, RSI(14), range position and the EMA20 gap: |
//|        every quintile came out 48-50% sells.  There is no         |
//|        measurable directional edge.  None.                        |
//|    lots      0.01 then x1.68 rounded to 2dp, chained:             |
//|              .01 .02 .03 .05 .08 .13 .22 .37 .62 1.04 1.75 2.94   |
//|              4.94   (the mode at every rung, exactly)             |
//|    spacing   $1.19 for rungs 2-6, then $1.81 for rungs 7+.        |
//|              Fixed dollars, not a percentage: the step held at    |
//|              1.17-1.20 while gold went 4527 -> 4070 -> 4282.      |
//|    take      close the WHOLE basket when the volume-weighted      |
//|              position is $0.43 in profit.  Same distance for a    |
//|              1-leg and a 13-leg basket (0.430 vs 0.428 median).   |
//|    give up   when the ladder is full the target flips: the basket |
//|              is closed at about $1.35 against the weighted        |
//|              average.  Measured on the 12-leg losers, n=28:       |
//|              p10 -1.63  p50 -1.37  p90 -1.28.                     |
//|    depth     13 rungs.  Every basket that ever reached 13 legs    |
//|              lost.  46,500 baskets -> 78 losers (0.17%).          |
//|                                                                  |
//|  WHAT IT EARNED, LIVE, ON ~$185,000                               |
//|    +$8,579 over 62 trading days  (~1.5% a month)                  |
//|    99.83% of baskets won, median win $0.45                        |
//|    worst basket -$4,332.97   worst day -$7,343.03 (-3.9%)         |
//|    69% of days green                                             |
//|                                                                  |
//|  WHY InpMaxLegs DEFAULTS TO 11 AND NOT 13                        |
//|    Replayed on Idan's own M1 gold feed (113,391 bars, sub-minute  |
//|    bridge, spread charged): 13 legs lost on all four seeds        |
//|    (-14.6k / -30.3k / -51.2k / -39.3k); 11 legs made money on all |
//|    four (+7.3k / +0.8k / +14.7k / +0.6k) and cut the worst        |
//|    basket from -$1,952 to -$691.  The last two rungs carry the    |
//|    ruin and almost none of the profit.  13 is the master's        |
//|    number; 11 is the one that survived the test.                  |
//|                                                                  |
//|  THE PART THAT MATTERS MOST                                      |
//|    A full 13-rung ladder is 12.20 lots = about $5.3 MILLION of    |
//|    gold.  0.01 is the smallest lot a broker will accept, so this  |
//|    ladder CANNOT be scaled down.  The master's worst day was      |
//|    -$7,343: that is -3.9% of his $185k and -73% of a $10,000      |
//|    account.  On a small account the only real dial is InpMaxLegs. |
//|    Read strategy/the-drawer-bot-2026-08-18.md before arming.      |
//|                                                                  |
//|  v1.11 - what changed after two rounds of adversarial audit       |
//|  (none of the measured rules moved; these are guards the master   |
//|  does not have):                                                  |
//|    * every leg now carries a REAL broker stop at the basket's     |
//|      emergency level, recomputed on each add.  Before this the    |
//|      only stop was tick-driven: a stalled feed, a disconnect or   |
//|      a weekend meant nothing was watching the ladder at all.      |
//|    * the loss-side exits refuse to fire on a blown-out spread     |
//|      (a rollover widening was enough to flush a full basket at    |
//|      the give-up price).  The broker stop covers a real runaway.  |
//|    * a partially closed basket is finished, not re-laddered.      |
//|    * the day's P&L is read from the account balance and survives  |
//|      a restart, so the daily stop can no longer be cleared by     |
//|      restarting the terminal or nudging an input.                 |
//|    * adds are spread-gated, level-gated and day-gated too.        |
//|    * every input is validated; a mixed-direction book, a second   |
//|      instance on the same magic, a wrong volume step or a bad     |
//|      quote all stop the bot instead of being traded through.      |
//|    * the broker stop is never clamped to just under the market:   |
//|      when price is already through the emergency level the stop   |
//|      is left alone, because clamping it turned a disaster stop    |
//|      into a two-cent trailing stop that fired into the spike.     |
//|    * a broker that refuses to close is retried at 2s, then 10s,   |
//|      then once a minute, instead of thirty rejected orders a      |
//|      second forever (switching AutoTrading off was enough).       |
//|    * a ladder frozen short of its cap - by the Friday cutoff, the |
//|      day stop, or a disarm - can still take the cheap give-up     |
//|      instead of riding all the way to the emergency stop.         |
//|    * a stale instance lock is retaken once it expires, so a       |
//|      crashed terminal cannot lock the bot out of its own magic.   |
//|                                                                   |
//|  v1.12 - the account-size rule is now measured, not assumed.      |
//|    The master's own 46,498 baskets were re-run at every depth cap |
//|    from 7 to 13.  The worst DAY came out 6.6x to 8.8x the worst   |
//|    single basket at every one of them - not the 1.7x I had        |
//|    guessed from the single worst day of the live run.  The gate   |
//|    now uses the give-up loss x8, and the refusal message tells    |
//|    you the deepest ladder your balance actually carries.          |
//|    What that measurement also showed, and it corrects something   |
//|    written above: on the master's own record the profit does NOT  |
//|    clearly favour 11 over 13.  Re-run at a clean give-up, caps    |
//|    8/9/10/11/12/13 paid +3.6k/+10.0k/+14.6k/+10.6k/+5.9k/+18.3k   |
//|    over three months - all of it decided by about 120 rare        |
//|    events, which is not a ranking anyone should trust.  What      |
//|    DOES scale cleanly with the cap is the size of the worst       |
//|    basket: $123 at 8 rungs, $583 at 11, $1,647 at 13.  Choose     |
//|    the depth by what the account can absorb, not by backtest.     |
//|    One exception, and the gate warns about it: below 8 rungs the  |
//|    ladder is cut so often that the bad days stack - the measured  |
//|    worst day at 7 rungs was 14.6x the worst basket, not 8x, and   |
//|    7 rungs LOST money on the master's own record (-$6,898 over    |
//|    three months).  The x8 rule understates the risk down there.   |
//|                                                                  |
//|  DISARMED BY DEFAULT.  InpArmed=false opens nothing - no basket,  |
//|  no extra rung.  It does NOT walk away from a basket that is      |
//|  already open: the take, the give-up, the emergency stop and the  |
//|  Friday flat all still run, because abandoning a live martingale  |
//|  is worse than managing it out.  From cold, with nothing open,    |
//|  it is completely inert.                                          |
//+------------------------------------------------------------------+
//|  v1.14 - the day can be REOPENED, on the side that is safe to.    |
//|    Idan, 19.8 night: "and I can turn it back on at any moment -   |
//|    it is just the daily profit it reaches and stops at."  The day |
//|    file now remembers WHY it closed (target / loss).  A day closed|
//|    by the PROFIT TARGET follows the input: raise InpDailyTargetUsd|
//|    or set it to 0, press OK, and the day reopens until the new    |
//|    number.  A day closed by the LOSS stop stays closed - restarts |
//|    and input changes were never allowed to clear that one, and    |
//|    still are not.  The heartbeat now also reports the LOADED      |
//|    day_target and day_loss_stop, so "armed but running without    |
//|    the target" can be seen on the club screen instead of guessed. |
//+------------------------------------------------------------------+
//|  v1.20 - one voice on the shared wire: the FIXED heartbeat file   |
//|    (idan_drawer_gold.json) is now written ONLY by the primary     |
//|    drawer (magic 770118). Tonight a second drawer-family bot      |
//|    (GBPJPY on ...0413, magic 770121) comes alive on this machine, |
//|    and two writers on one fixed name would make the club card     |
//|    flicker between accounts. Every instance still writes its own  |
//|    per-magic file - the mirror upgrade will read those.           |
//|  v1.19 - the machine learns other symbols' money: every place     |
//|    that turned "price move x lots" into account money used the    |
//|    CONTRACT SIZE, which is only correct when the quote currency   |
//|    is the account currency (gold in USD).  On GBPJPY it was off   |
//|    by the USDJPY rate (~x158), so the wallet brake would have     |
//|    bent a pound-yen ladder to 1 rung.  Now g_unitVal =            |
//|    tick_value/tick_size (the broker's own conversion) prices a    |
//|    full 1.0 move per lot in ACCOUNT currency on any symbol;       |
//|    gold keeps the exact same number (100) it always had.          |
//|  v1.18 - Idan's 21.8 order, given with the wipe risk spelled out  |
//|    and accepted ("אני מודע לסיכון של מחיקת החשבון"): the BASKET    |
//|    ONLY closes in total profit.  InpNeverLoss=true removes the    |
//|    give-up, the hard stop, the per-leg broker stops, and a red    |
//|    Friday flatten (a green one still flattens).  The one exit     |
//|    left on a runaway is the broker's margin call.  Demo only.     |
//|  v1.17 - the wallet decides the depth (Idan, 20.8: "עד 5 לוט,     |
//|    לפי נפח הארנק").  A ceiling the balance cannot carry no longer |
//|    refuses to arm: it BENDS to the deepest rung the balance does  |
//|    carry (same 10% worst-day rule), then re-fits once an hour,    |
//|    between baskets, as the wallet grows or shrinks.  A typed      |
//|    InpMinBalance floor still refuses - the bot does not argue     |
//|    with typed floors.  The heartbeat reports both depths:         |
//|    max_legs (working) and max_legs_ask (the ceiling asked for).   |
//|  v1.16 - the heartbeat learns its own name: each instance also    |
//|    writes idan_drawer_gold_<magic>.json, so three drawers on one  |
//|    server (the 20.8 plan) stop overwriting each other's pulse.    |
//|  v1.15 - a deposit is money MOVED, not money MADE.  The day's     |
//|    P&L now subtracts every DEAL_TYPE_BALANCE operation since the  |
//|    day's anchor (kept in the day file), refreshed every 5s.  So a |
//|    mid-day deposit can no longer fake the +$1,200 daily target,   |
//|    a withdrawal can no longer fake the daily loss stop, and the   |
//|    heartbeat says day_deposits out loud so the club screen can    |
//|    show "הופקדו היום +$X - לא נספר ברווח".                        |
//+------------------------------------------------------------------+
#property copyright "Idan Trader"
#property link      "idan money club"
#property version   "1.20"
#property description "Drawer replica of the copied gold bot. Disarmed until InpArmed=true."

#include <Trade/Trade.mqh>

#define MAX_RUNGS 16
// measured on the master's own record: the worst day of a 3-month run came out
// 6.6x to 8.8x the worst single basket, at every depth cap from 7 to 12.
#define WORST_DAY_MULT 8.0

//--- the switch ----------------------------------------------------
input group           "=== ARMING ==="
input bool   InpArmed          = false;  // ARMED? false = opens nothing (a basket already open is still managed out)
input bool   InpDemoOnly       = true;   // refuse to run on a real account
input double InpMinBalance     = 0.0;    // 0 = derive it from InpWorstDayPctCap
input double InpWorstDayPctCap = 10.0;   // a bad day must cost at most this % of the account

//--- the measured machine ------------------------------------------
input group           "=== THE LADDER (measured) ==="
input double InpBaseLots       = 0.01;   // leg 1
input double InpLotMult        = 1.68;   // x1.68 chained, rounded to 2dp
input double InpStepNearUsd    = 1.19;   // spacing for rungs 2..6
input double InpStepFarUsd     = 1.81;   // spacing for rungs 7 and deeper
input int    InpStepBreakLeg   = 6;      // rung at which the spacing widens
input int    InpMaxLegs        = 11;     // ladder depth cap (master's own is 13)

input group           "=== THE EXITS (measured) ==="
input double InpTakeUsd        = 0.43;   // close the basket this far past the weighted average
input double InpGiveUpUsd      = 1.35;   // ladder full -> close it this far the wrong way
input double InpHardStopUsd    = 4.85;   // emergency: close at any depth past this

//--- the guards (mine, not the master's) ---------------------------
input group           "=== GUARDS (added, not copied) ==="
input bool   InpBrokerStop     = true;   // put a real stop-loss at the emergency level on every leg
input bool   InpNeverLoss      = false;  // 21.8: basket closes ONLY in total profit - no give-up/hard stop/broker stops; red Friday holds the weekend; margin call is the one exit left
input double InpDailyStopUsd   = 0.0;    // stop for the day after this much realised loss (0=off)
input double InpDailyTargetUsd = 0.0;    // bank the day and stop after this much realised PROFIT (0=off)
input double InpMaxSpreadUsd   = 0.40;   // do not open or add on a spread wider than this
input double InpLossExitSpread = 1.00;   // do not take a LOSS exit on a spread wider than this
input double InpMarginBuffer   = 1.50;   // need free margin >= requirement * this
input int    InpFridayStopHour = 20;     // server hour after which no new basket on Friday
input int    InpFridayFlatHour = 21;     // server hour at which any open basket is closed on Friday
input double InpSlippageUsd    = 0.60;   // market order deviation, in dollars
input long   InpMagic          = 770118; // this bot's positions only
input string InpSymbolOverride = "";     // "" = this chart's symbol

//--- direction -----------------------------------------------------
input group           "=== DIRECTION ==="
input int    InpDirMode        = 0;      // 0=coin flip (what the master does) 1=alternate 2=long only 3=short only
input int    InpCooldownSec    = 3;      // wait this long after a basket closes before opening the next

//--- forward declarations ------------------------------------------
void   Show(int legs, int dir, double vol, double vwap, string note);
void   Beat();
void   CloseBasket(string why);
void   SetBasketStop(int dir, double vwap);
bool   ReadBasket(int &legs, int &dir, double &vol, double &vwap, double &worstEntry, bool &mixed);
string WantExit(int legs, int dir, double vwap, bool flatten, bool frozen);
bool   FridayShut(bool &flatten);
double DayPnl();
void   SaveDay();
void   RollDay();
void   RefreshDayDeposits();
double LadderSum(int legs);
double LadderReach();
double StepFor(int rung);
double ExitPrice(int dir);
double EntryPrice(int dir);
double SpreadUsd();
bool   QuoteOk();
void   HoldLock();
int    DeepestAffordable(double bal);
int    CloseBackoffSec();
bool   ClaimLock();

//+------------------------------------------------------------------+
CTrade   trade;
bool     g_ok        = false;
string   g_why       = "";
string   g_sym       = "";
double   g_lots[MAX_RUNGS];
int      g_nlots     = 0;
int      g_legsCap   = 0;          // WORKING depth: the wallet-fitted cap
int      g_legsAsk   = 0;          // the ceiling the preset asked for
datetime g_lastDepthChk = 0;       // hourly wallet re-fit, between baskets
int      g_lastDir   = 1;
double   g_contract  = 100.0;      // ounces per lot, read from the symbol
double   g_unitVal   = 100.0;      // ACCOUNT money for a 1.0 price move on 1 lot (tick_value/tick_size)
double   g_point     = 0.01;
int      g_digits    = 2;
double   g_stopsLvl  = 0.0;

double   g_dayStartBal = 0.0;
string   g_dayKey      = "";
bool     g_dayStop     = false;
string   g_dayWhy      = "";       // why the day closed: target or loss
string   g_dayKind     = "";       // what the day file remembers: "" / "target" / "loss"
datetime g_dayAnchor   = 0;        // when the day's baseline was anchored
double   g_dayDeposits = 0.0;      // balance ops since the anchor - moved, not made

bool     g_closing   = false;      // a close is unfinished: finish it, never build on it
double   g_lastLevel = 0.0;        // price level of the leg we last SENT
uint     g_lastActMs = 0;
datetime g_lastActSec = 0;
datetime g_lastBeat  = 0;
datetime g_lastFinish = 0;
int      g_stopFails  = 0;
int      g_closeFails = 0;

double   g_minBal      = 0.0;
double   g_worstBasket = 0.0;
double   g_worstDay    = 0.0;
string   g_lockOwner   = "";
string   g_lockBeat    = "";
bool     g_lockWait    = false;

//+------------------------------------------------------------------+
//| the lot ladder, exactly as the master's rungs came out            |
//+------------------------------------------------------------------+
void BuildLadder()
{
   double v = InpBaseLots;
   g_nlots = 0;
   for(int i = 0; i < g_legsCap && i < MAX_RUNGS; i++)
   {
      g_lots[i] = NormalizeDouble(v, 2);
      g_nlots++;
      v = NormalizeDouble(v * InpLotMult, 2);
   }
}

double LadderSum(int legs)
{
   double s = 0;
   for(int i = 0; i < legs && i < g_nlots; i++) s += g_lots[i];
   return NormalizeDouble(s, 2);
}

double StepFor(int rung)
{
   return (rung <= InpStepBreakLeg) ? InpStepNearUsd : InpStepFarUsd;
}

double LadderReach()                 // how far below leg 1 the last rung sits
{
   double d = 0;
   for(int i = 2; i <= g_legsCap; i++) d += StepFor(i);
   return d;
}

//+------------------------------------------------------------------+
//| the deepest ladder this balance can carry under the same rule -    |
//| so the refusal tells the operator what to type, not just no.       |
//+------------------------------------------------------------------+
int DeepestAffordable(double bal)
{
   double v = InpBaseLots, sum = 0;
   int    best = 0;
   for(int n = 1; n <= MAX_RUNGS; n++)
   {
      sum += NormalizeDouble(v, 2);
      v    = NormalizeDouble(v * InpLotMult, 2);
      double day  = InpGiveUpUsd * NormalizeDouble(sum, 2) * g_unitVal * WORST_DAY_MULT;
      double need = day * (100.0 / MathMax(InpWorstDayPctCap, 0.5));
      if(bal >= need) best = n; else break;
   }
   return best;
}

//+------------------------------------------------------------------+
//| v1.17: one place sets the working depth and re-derives every      |
//| number that hangs off it - ladder, worst basket, worst day, floor.|
//+------------------------------------------------------------------+
void ApplyDepth(int cap)
{
   g_legsCap = cap;
   BuildLadder();
   double full   = LadderSum(g_legsCap);
   g_worstBasket = InpGiveUpUsd * full * g_unitVal;
   g_worstDay    = g_worstBasket * WORST_DAY_MULT;
   g_minBal      = (InpMinBalance > 0) ? InpMinBalance
                                       : g_worstDay * (100.0 / MathMax(InpWorstDayPctCap, 0.5));
}

//+------------------------------------------------------------------+
double NormLot(double v)
{
   double st = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);
   double mn = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MAX);
   if(st <= 0) st = 0.01;
   double r = MathFloor(v / st + 0.5) * st;
   r = NormalizeDouble(r, 8);
   int    dg = (st >= 0.1) ? 1 : 2;
   r = NormalizeDouble(r, dg);
   if(r < mn) r = mn;
   if(r > mx) r = mx;
   return r;
}

//+------------------------------------------------------------------+
//| every input is checked here.  A bad one stops the bot, it never   |
//| quietly changes what the bot does.                                |
//+------------------------------------------------------------------+
string ValidateInputs()
{
   if(InpBaseLots      <= 0)            return "InpBaseLots must be positive.";
   if(InpLotMult       <  1.0 || InpLotMult > 3.0)
      return "InpLotMult must be between 1.0 and 3.0 (the master's is 1.68).";
   if(InpStepNearUsd   <= 0.05)         return "InpStepNearUsd is too small - the ladder would fill on noise.";
   if(InpStepFarUsd    <= 0.05)         return "InpStepFarUsd is too small - the ladder would fill on noise.";
   if(InpStepBreakLeg  <  1)            return "InpStepBreakLeg must be at least 1.";
   if(InpMaxLegs       <  1 || InpMaxLegs > MAX_RUNGS)
      return StringFormat("InpMaxLegs must be between 1 and %d. The master never went past 13.", MAX_RUNGS);
   if(InpTakeUsd       <= 0)            return "InpTakeUsd must be positive, or the basket closes the moment it opens.";
   if(InpGiveUpUsd     <= 0)            return "InpGiveUpUsd must be positive.";
   if(InpHardStopUsd   <= InpGiveUpUsd) return "InpHardStopUsd must be further out than InpGiveUpUsd.";
   if(InpMarginBuffer  <  1.0)          return "InpMarginBuffer must be at least 1.0 - below that it is not a check.";
   if(InpWorstDayPctCap <  0.5 || InpWorstDayPctCap > 50.0)
      return "InpWorstDayPctCap must be between 0.5 and 50. Above 50 the guard means nothing.";
   if(InpMaxSpreadUsd  <= 0)            return "InpMaxSpreadUsd must be positive.";
   if(InpLossExitSpread <= 0)           return "InpLossExitSpread must be positive.";
   if(InpFridayStopHour < 0 || InpFridayStopHour > 23) return "InpFridayStopHour must be 0..23.";
   if(InpFridayFlatHour < 0 || InpFridayFlatHour > 23) return "InpFridayFlatHour must be 0..23.";
   if(InpCooldownSec   <  0)            return "InpCooldownSec cannot be negative.";
   if(InpSlippageUsd   <= 0)            return "InpSlippageUsd must be positive.";
   if(InpDirMode       <  0 || InpDirMode > 3) return "InpDirMode must be 0..3.";
   return "";
}

//+------------------------------------------------------------------+
//| the day's realised P&L, read from the balance so it includes      |
//| commission and swap, and written to disk so a restart cannot      |
//| erase a daily stop that is still in force.                        |
//+------------------------------------------------------------------+
string DayKey()
{
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   return StringFormat("%04d-%02d-%02d", t.year, t.mon, t.day);
}

string DayFile() { return "idan_drawer_day_" + IntegerToString((long)InpMagic) + ".txt"; }

void SaveDay()
{
   int h = FileOpen(DayFile(), FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileWriteString(h, StringFormat("%s|%.2f|%d|%s|%s", g_dayKey, g_dayStartBal, (g_dayStop ? 1 : 0), g_dayKind, IntegerToString((long)g_dayAnchor)));
   FileClose(h);
}

void LoadDay()
{
   g_dayKey      = DayKey();
   g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayStop     = false;
   g_dayWhy      = "";
   g_dayAnchor   = TimeCurrent();
   int h = FileOpen(DayFile(), FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h != INVALID_HANDLE)
   {
      string s = FileReadString(h);
      FileClose(h);
      string p[];
      int n = StringSplit(s, '|', p);
      if(n >= 3 && p[0] == g_dayKey)
      {
         double b = StringToDouble(p[1]);
         if(b > 0)                       // a truncated or garbled file must not
         {                               // silently re-anchor the day at zero
            g_dayStartBal = b;
            g_dayStop     = (p[2] == "1");
            // v1.14: the file remembers WHY the day closed.  An old 3-field
            // file cannot say, so a stop it carries is treated as the sticky
            // kind - guessing "target" would let a restart reopen a day the
            // loss stop closed.
            g_dayKind     = (n >= 4) ? p[3] : (g_dayStop ? "loss" : "");
            // v1.15: the file also remembers WHEN the baseline was anchored,
            // so deposits are counted from that moment and not double-counted.
            // A legacy file without the field anchors at the day's midnight -
            // right for a bot that rolls its own day at midnight.
            g_dayAnchor   = (n >= 5) ? (datetime)StringToInteger(p[4])
                                     : StringToTime(g_dayKey + " 00:00:00");
            if(g_dayAnchor <= 0) g_dayAnchor = StringToTime(g_dayKey + " 00:00:00");
         }
         else
            Print("IdanDrawerGold: the day file is unreadable - starting the day from the current balance");
      }
   }
   RefreshDayDeposits();
   // v1.14 - "I can turn it back on at any moment."  A day closed by the
   // PROFIT TARGET follows the input: if the target was raised past today's
   // profit, or switched off, the day reopens.  A day closed by the LOSS
   // stop does not follow the input - that one was made restart-proof on
   // purpose and stays that way.
   if(g_dayStop && g_dayKind == "target" &&
      (InpDailyTargetUsd <= 0 ||
       AccountInfoDouble(ACCOUNT_BALANCE) - g_dayStartBal < InpDailyTargetUsd))
   {
      g_dayStop = false;
      g_dayKind = "";
      Print("IdanDrawerGold: the day reopened - the profit target moved past today's profit");
   }
   if(g_dayStop && g_dayWhy == "")
      g_dayWhy = (g_dayKind == "target")
                 ? "daily target reached - no new ladders today (restored from the day file)"
                 : "daily stop restored from the day file";
   SaveDay();
}

//+------------------------------------------------------------------+
//| deposits and withdrawals are money MOVED, not money MADE.  v1.15  |
//| reads them from the deal history (DEAL_TYPE_BALANCE) so a deposit |
//| in the middle of the day cannot fake the daily target, and a      |
//| withdrawal cannot fake the daily loss stop.  Idan, 20.8: "if you  |
//| deposited more - it is written down and calculated."              |
//+------------------------------------------------------------------+
void RefreshDayDeposits()
{
   if(g_dayAnchor <= 0) return;                    // no anchor, keep the cache
   if(!HistorySelect(g_dayAnchor, TimeCurrent() + 3600)) return;
   double s = 0;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      if((ENUM_DEAL_TYPE)HistoryDealGetInteger(tk, DEAL_TYPE) != DEAL_TYPE_BALANCE) continue;
      s += HistoryDealGetDouble(tk, DEAL_PROFIT);  // deposit positive, withdrawal negative
   }
   g_dayDeposits = s;
}

double DayPnl() { return AccountInfoDouble(ACCOUNT_BALANCE) - g_dayStartBal - g_dayDeposits; }

//+------------------------------------------------------------------+
//| The day is over when it hits either edge.                         |
//|                                                                   |
//| Idan, 19.8.2026, the day the source blew up: "the moment it makes |
//| $1,200 in a day it should close automatically."                   |
//|                                                                   |
//| Hitting the target does NOT dump the open basket at whatever the  |
//| screen says. It closes the door on NEW ladders and lets the one    |
//| that is open finish the way it always does - at +$0.43 from its    |
//| weighted average, which on this machine is usually seconds away.   |
//| Selling a basket at a random price to honour a round number is how |
//| a good day gets turned into a bad one.                             |
//+------------------------------------------------------------------+
bool DayEdgeHit()
{
   if(g_dayStop) return true;
   double p = DayPnl();
   if(InpDailyTargetUsd > 0 && p >= InpDailyTargetUsd)
   {
      g_dayStop = true;
      g_dayKind = "target";
      g_dayWhy  = StringFormat("daily target reached: +%.2f of %.2f - no new ladders today",
                               p, InpDailyTargetUsd);
      PrintFormat("IdanDrawerGold: %s", g_dayWhy);
      SaveDay();
      return true;
   }
   if(InpDailyStopUsd > 0 && p <= -InpDailyStopUsd)
   {
      g_dayStop = true;
      g_dayKind = "loss";
      g_dayWhy  = StringFormat("daily loss stop: %.2f - flat for the rest of the day", p);
      PrintFormat("IdanDrawerGold: %s", g_dayWhy);
      SaveDay();
      return true;
   }
   return false;
}

void RollDay()
{
   string k = DayKey();
   if(k == g_dayKey) return;
   g_dayKey      = k;
   g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayStop     = false;
   g_dayWhy      = "";
   g_dayKind     = "";
   g_dayAnchor   = TimeCurrent();
   g_dayDeposits = 0.0;
   RefreshDayDeposits();
   SaveDay();
}

//+------------------------------------------------------------------+
//| one instance per magic+symbol.  Two of them share a book and the  |
//| weighted average becomes a number that means nothing.             |
//+------------------------------------------------------------------+
bool ClaimLock()
{
   // keyed on the magic ALONE, not magic+symbol: the day file and the
   // heartbeat are per magic too, so two symbols sharing one magic would
   // clobber each other's baseline.  One magic, one instance.
   string tag  = "IdanDrawer_" + IntegerToString((long)InpMagic);
   g_lockOwner = tag + "_owner";
   g_lockBeat  = tag + "_beat";
   double owner = 0, beat = 0;
   double me    = (double)(ChartID() % 1000000000);   // a double holds 9 digits exactly
   bool   has   = GlobalVariableGet(g_lockOwner, owner) && GlobalVariableGet(g_lockBeat, beat);
   if(has && owner != me && (TimeCurrent() - (datetime)beat) < 120)
      return false;                        // somebody else is alive on this magic
   GlobalVariableSet(g_lockOwner, me);
   GlobalVariableSet(g_lockBeat,  (double)TimeCurrent());
   return true;
}
void HoldLock()
{
   if(g_lockBeat == "") return;
   double owner = 0;
   if(GlobalVariableGet(g_lockOwner, owner) && owner != (double)(ChartID() % 1000000000)) return;
   GlobalVariableSet(g_lockBeat, (double)TimeCurrent());
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_sym    = (InpSymbolOverride != "") ? InpSymbolOverride : _Symbol;
   g_legsCap = (InpMaxLegs >= 1 && InpMaxLegs <= MAX_RUNGS) ? InpMaxLegs : 1;
   g_legsAsk = g_legsCap;
   g_lastDepthChk = TimeCurrent();
   BuildLadder();

   g_contract = SymbolInfoDouble(g_sym, SYMBOL_TRADE_CONTRACT_SIZE);
   if(g_contract <= 0) g_contract = 100.0;
   // v1.19: money per 1.0 price move per lot, in the ACCOUNT currency - the
   // broker's own tick_value already carries the quote->account conversion.
   // On XAUUSD/USD this is exactly the contract size; on GBPJPY it is
   // 100,000/USDJPY.  Falls back to contract size if the broker reports 0.
   double tv = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_SIZE);
   g_unitVal = (tv > 0 && ts > 0) ? tv / ts : g_contract;
   g_point    = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   if(g_point <= 0) g_point = 0.01;
   g_digits   = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   g_stopsLvl = (double)SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL) * g_point;

   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints((ulong)MathMax(1.0, MathRound(InpSlippageUsd / g_point)));
   trade.SetTypeFillingBySymbol(g_sym);
   MathSrand((int)(GetTickCount() ^ (uint)TimeLocal()));

   // A normal bad basket is the give-up: -InpGiveUpUsd per ounce on the whole
   // ladder.  How many of those land on one day is not a guess - the master's
   // own 46,498 baskets were re-run at every depth cap, and the worst day came
   // out between 6.6x and 8.8x the worst basket at every one of them.  8x is
   // the middle of that.  (Worked example at 11 rungs: 1.35 x 4.32 x 100 =
   // $583 a basket, x8 = $4,664 a day.  The measured worst day was $4,486.)
   ApplyDepth(g_legsCap);
   LoadDay();

   string bad = ValidateInputs();

   // v1.17: bend, don't refuse - and do it BEFORE the guard chain, so the
   // balance gate passes at the bent depth and the lock still gets claimed.
   // Only the derived floor bends; a typed InpMinBalance still refuses.
   if(bad == "" && InpMinBalance <= 0 &&
      AccountInfoDouble(ACCOUNT_BALANCE) < g_minBal)
   {
      int deepNow = DeepestAffordable(AccountInfoDouble(ACCOUNT_BALANCE));
      if(deepNow >= 1 && deepNow < g_legsCap)
      {
         ApplyDepth(deepNow);
         PrintFormat("IdanDrawerGold: depth bent to the wallet - %d rungs (%.2f lots full) of the %d asked; it grows back by itself as the balance does.",
                     g_legsCap, LadderSum(g_legsCap), g_legsAsk);
      }
   }
   double vmin = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);
   double vstp = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);

   g_ok = true; g_why = "";
   if(!InpArmed)
      { g_ok = false; g_why = "DISARMED - opens nothing. Anything already open is still managed out."; }
   else if(bad != "")
      { g_ok = false; g_why = "INPUT: " + bad; }
   else if(InpDemoOnly && AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO)
      { g_ok = false; g_why = "REAL ACCOUNT and InpDemoOnly is true - refusing."; }
   else if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      { g_ok = false; g_why = "This account is NETTING. The ladder needs a HEDGING account."; }
   else if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      { g_ok = false; g_why = "Algo trading is off in the terminal."; }
   else if(!SymbolInfoInteger(g_sym, SYMBOL_SELECT))
      { g_ok = false; g_why = "Symbol " + g_sym + " is not in Market Watch."; }
   else if(vmin > InpBaseLots + 1e-8 || vstp > 0.01 + 1e-8)
      { g_ok = false;
        g_why = StringFormat("This broker's minimum lot is %.2f and its step is %.2f. The ladder needs 0.01/0.01 - at %.2f the first rungs collapse into one size and the recovery stops working.", vmin, vstp, vstp); }
   else if(AccountInfoDouble(ACCOUNT_BALANCE) < g_minBal)
      { g_ok = false;
        g_why = StringFormat("Balance %.0f is under the %.0f that %d rungs (%.2f lots) needs: a bad day here costs about %.0f, which is %.0f%% of this account. The deepest ladder this balance carries is InpMaxLegs=%d.",
                             AccountInfoDouble(ACCOUNT_BALANCE), g_minBal, g_legsCap, LadderSum(g_legsCap),
                             g_worstDay, g_worstDay / MathMax(AccountInfoDouble(ACCOUNT_BALANCE), 1.0) * 100.0,
                             DeepestAffordable(AccountInfoDouble(ACCOUNT_BALANCE))); }
   else if(!ClaimLock())
      { g_ok = false; g_lockWait = true;
        g_why = "Another chart is already running magic " + IntegerToString((long)InpMagic) + " on " + g_sym + ". Two of them share one book and the weighted average becomes meaningless."; }

   if(g_legsCap < 8)
      Print("IdanDrawerGold: WARNING - below 8 rungs the ladder is cut so often that the bad days stack. On the master's own record 7 rungs lost $6,898 over three months and its worst day was 14.6x its worst basket, so the account-size gate understates the risk at this depth.");
   PrintFormat("IdanDrawerGold v1.20 %s | sym=%s depth=%d/%d full=%.2f lots reach=$%.2f contract=%.0f needs>=%.0f | day target %s | day loss stop %s | %s",
               (g_ok ? "READY" : "HELD"), g_sym, g_legsCap, g_legsAsk, LadderSum(g_legsCap), LadderReach(), g_contract, g_minBal,
               (InpDailyTargetUsd > 0 ? StringFormat("+$%.0f", InpDailyTargetUsd) : "off"),
               (InpDailyStopUsd   > 0 ? StringFormat("-$%.0f", InpDailyStopUsd)   : "off"),
               (g_why == "" ? "ok" : g_why));
   EventSetTimer(5);
   Beat();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
   if(g_lockOwner != "")
   {
      double owner = 0;
      if(GlobalVariableGet(g_lockOwner, owner) && owner == (double)(ChartID() % 1000000000))
      {
         GlobalVariableDel(g_lockOwner);
         GlobalVariableDel(g_lockBeat);
      }
   }
}

//+------------------------------------------------------------------+
//| read the basket straight off the open positions - restart safe    |
//+------------------------------------------------------------------+
bool ReadBasket(int &legs, int &dir, double &vol, double &vwap, double &worstEntry, bool &mixed)
{
   legs = 0; dir = 0; vol = 0; vwap = 0; worstEntry = 0; mixed = false;
   double wsum = 0;
   int    seen = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)  != g_sym)   continue;
      long   ty = PositionGetInteger(POSITION_TYPE);
      double v  = PositionGetDouble(POSITION_VOLUME);
      double p  = PositionGetDouble(POSITION_PRICE_OPEN);
      int    d  = (ty == POSITION_TYPE_BUY) ? 1 : -1;
      if(seen == 0) { dir = d; worstEntry = p; }
      else if(d != dir) mixed = true;
      seen++;
      legs++; vol += v; wsum += v * p;
      if(d == dir)
      {
         if(dir > 0 && p < worstEntry) worstEntry = p;
         if(dir < 0 && p > worstEntry) worstEntry = p;
      }
   }
   if(legs == 0) return false;
   vol  = NormalizeDouble(vol, 2);
   vwap = wsum / vol;
   return true;
}

//+------------------------------------------------------------------+
double Bid()       { return SymbolInfoDouble(g_sym, SYMBOL_BID); }
double Ask()       { return SymbolInfoDouble(g_sym, SYMBOL_ASK); }
double SpreadUsd() { return Ask() - Bid(); }
bool   QuoteOk()   { double b = Bid(), a = Ask(); return (b > 0 && a > 0 && a >= b && (a - b) < 50.0); }
double ExitPrice(int dir)  { return (dir > 0) ? Bid() : Ask(); }   // a buy is closed at the bid
double EntryPrice(int dir) { return (dir > 0) ? Ask() : Bid(); }   // a buy pays the ask

//+------------------------------------------------------------------+
//| a REAL stop at the emergency level on every leg.  Without this    |
//| the only stop is a tick arriving, and a stalled feed or a weekend |
//| means nothing at all is watching a live ladder.                   |
//+------------------------------------------------------------------+
void SetBasketStop(int dir, double vwap)
{
   if(!InpBrokerStop || InpNeverLoss || dir == 0) return;
   double sl  = (dir > 0) ? vwap - InpHardStopUsd : vwap + InpHardStopUsd;
   double px  = ExitPrice(dir);
   double gap = MathMax(g_stopsLvl, 2 * g_point);
   // If the market is ALREADY through the emergency level, do not clamp the
   // stop to just under the current price - that would turn a disaster stop
   // into a two-cent trailing stop and flush the basket into whatever spread
   // happens to be showing.  Leave the stop alone and let the tick logic
   // decide, because that is the code that knows about spread.
   if(dir > 0 && sl > px - gap) return;
   if(dir < 0 && sl < px + gap) return;
   sl = NormalizeDouble(sl, g_digits);
   if(sl <= 0) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)  != g_sym)   continue;
      double cur = PositionGetDouble(POSITION_SL);
      if(MathAbs(cur - sl) < g_point / 2) continue;
      if(!trade.PositionModify(tk, sl, 0.0))
      {
         g_stopFails++;
         if(g_stopFails <= 5 || g_stopFails % 200 == 0)
            PrintFormat("IdanDrawerGold: stop on %s refused (%d so far) ret=%d %s",
                        IntegerToString((long)tk), g_stopFails,
                        (int)trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
   }
}

//+------------------------------------------------------------------+
//| close every leg.  If anything is left the basket is NOT flat and  |
//| g_closing keeps us finishing it instead of laddering on top.      |
//+------------------------------------------------------------------+
void CloseBasket(string why)
{
   int closed = 0;
   for(int pass = 0; pass < 3; pass++)
   {
      bool again = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong tk = PositionGetTicket(i);
         if(tk == 0) continue;
         if(!PositionSelectByTicket(tk)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         if(PositionGetString(POSITION_SYMBOL)  != g_sym)   continue;
         if(trade.PositionClose(tk)) closed++;
         else
         {
            again = true;
            g_closeFails++;
            if(g_closeFails <= 5 || g_closeFails % 100 == 0)
               PrintFormat("IdanDrawerGold: close %s failed (%d so far) ret=%d %s",
                           IntegerToString((long)tk), g_closeFails,
                           (int)trade.ResultRetcode(), trade.ResultRetcodeDescription());
         }
      }
      if(!again) break;
      Sleep(200);
   }
   int legs, dir; double vol, vwap, we; bool mixed;
   bool left = ReadBasket(legs, dir, vol, vwap, we, mixed);
   g_closing = left;
   if(!left) g_closeFails = 0;
   if(closed > 0 || left)
   {
      g_lastActMs = GetTickCount(); g_lastActSec = TimeCurrent();
      g_lastLevel = 0;
      PrintFormat("IdanDrawerGold: basket close (%s) closed=%d left=%d day=%.2f",
                  why, closed, legs, DayPnl());
   }
   //  a basket just closed, so today's realised number just moved: this is
   //  the moment to ask whether the day is done - at EITHER edge.
   if(!left)
   {
      DayEdgeHit();
   }
}

//+------------------------------------------------------------------+
//| 2s, then 10s, then a minute.  A broker that keeps saying no is not |
//| going to say yes on the thirtieth try in the same second.          |
//+------------------------------------------------------------------+
int CloseBackoffSec()
{
   if(g_closeFails <= 3)  return 2;
   if(g_closeFails <= 20) return 10;
   return 60;
}

//+------------------------------------------------------------------+
bool MarginOk(int dir, double lots, double price)
{
   double need = 0;
   ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcMargin(ot, g_sym, lots, price, need)) return false;
   return (AccountInfoDouble(ACCOUNT_MARGIN_FREE) >= need * InpMarginBuffer);
}

//+------------------------------------------------------------------+
int PickDirection()
{
   if(InpDirMode == 2) return  1;
   if(InpDirMode == 3) return -1;
   if(InpDirMode == 1) { g_lastDir = -g_lastDir; return g_lastDir; }
   return (MathRand() % 2 == 0) ? 1 : -1;      // the master's coin flip
}

//+------------------------------------------------------------------+
bool FridayShut(bool &flatten)
{
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   flatten = false;
   if(t.day_of_week != 5) return false;
   if(t.hour >= InpFridayFlatHour) { flatten = true; return true; }
   return (t.hour >= InpFridayStopHour);
}

//+------------------------------------------------------------------+
//| the exit rules.  Take is always allowed - a wide spread only ever |
//| makes it harder.  The loss exits are held back on a blown-out     |
//| spread, because a rollover widening was enough to flush a full    |
//| basket at the give-up price and then revert one second later.     |
//| A real runaway is covered by the broker stop on every leg.        |
//+------------------------------------------------------------------+
string WantExit(int legs, int dir, double vwap, bool flatten, bool frozen)
{
   double move = (ExitPrice(dir) - vwap) * dir;
   if(move >= InpTakeUsd) return "take";
   if(InpNeverLoss)
   {
      // 21.8, Idan: "אין מצב בחיים שהוא יוצא בהפסד". The red exits are gone.
      // A Friday flatten happens only if the basket is green right now; a red
      // basket holds through the weekend - his stated, informed choice.
      if(flatten && move > 0) return "friday";
      return "";
   }
   bool spreadSane = (SpreadUsd() <= InpLossExitSpread);
   if(spreadSane)
   {
      if(move <= -InpHardStopUsd) return "hard";
      // "frozen" means the ladder cannot grow any further - either it is full,
      // or the friday cutoff / the day stop / a disarm has closed the door on
      // new legs.  A half-built ladder that can never reach its cap would
      // otherwise have no exit but the full emergency stop, which costs far
      // more than the give-up it was supposed to take.
      if((legs >= g_legsCap || frozen) && move <= -InpGiveUpUsd) return "giveup";
   }
   if(flatten) return "friday";   // deliberately NOT spread-gated: being flat
   return "";                     // before the weekend outranks the spread
}

//+------------------------------------------------------------------+
void OnTick()
{
   HoldLock();
   RollDay();
   int legs, dir; double vol, vwap, worstEntry; bool mixed;
   bool have = ReadBasket(legs, dir, vol, vwap, worstEntry, mixed);
   if(!QuoteOk()) { Show(have ? legs : 0, dir, vol, vwap, "no usable quote"); return; }

   if(mixed)
   {
      // never trade a book we cannot describe: the weighted average of a long
      // and a short is a number that matches no position on the account.
      Show(legs, dir, vol, vwap, "MIXED DIRECTIONS on this magic - trading stopped, close them by hand");
      return;
   }

   bool flatten = false;
   bool shut    = FridayShut(flatten);

   // ---- a basket is open (or a close is unfinished) --------------------
   if(have)
   {
      if(g_closing)
      {
         if(TimeCurrent() - g_lastFinish >= CloseBackoffSec()) { g_lastFinish = TimeCurrent(); CloseBasket("finish"); }
         else                                   SetBasketStop(dir, vwap);
         Show(legs, dir, vol, vwap, "finishing a close that did not complete");
         return;
      }
      // "frozen" = the ladder can no longer grow.  A deliberate disarm counts;
      // a transient HELD (a balance read as zero at startup, say) does not,
      // because that must not cut a healthy basket at a loss.
      bool frozen = shut || g_dayStop || !InpArmed;
      string why = WantExit(legs, dir, vwap, flatten, frozen);
      if(why != "") { CloseBasket(why); Show(0,0,0,0,""); return; }
      if(!g_ok) { SetBasketStop(dir, vwap); Show(legs, dir, vol, vwap, ""); return; }

      if(legs < g_legsCap && !shut && !g_dayStop && SpreadUsd() <= InpMaxSpreadUsd)
      {
         double need = StepFor(legs + 1);
         double nxt  = EntryPrice(dir);
         bool   far  = (worstEntry - nxt) * dir >= need;
         bool   dupe = (g_lastLevel > 0 && MathAbs(nxt - g_lastLevel) < need * 0.5);
         if(far && !dupe && GetTickCount() - g_lastActMs >= 800)
         {
            double lot = NormLot(g_lots[legs]);
            if(MarginOk(dir, lot, nxt))
            {
               g_lastActMs = GetTickCount();
               bool sent = (dir > 0) ? trade.Buy(lot, g_sym, 0, 0, 0, "drawer")
                                     : trade.Sell(lot, g_sym, 0, 0, 0, "drawer");
               g_lastActMs = GetTickCount();
               uint rc = trade.ResultRetcode();
               if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL))
               {
                  g_lastLevel = nxt;
                  int l2, d2; double v2, w2, e2; bool m2;
                  if(ReadBasket(l2, d2, v2, w2, e2, m2) && !m2) SetBasketStop(d2, w2);
               }
               else
                  PrintFormat("IdanDrawerGold: leg %d refused ret=%d %s", legs + 1, rc,
                              trade.ResultRetcodeDescription());
            }
            else
               PrintFormat("IdanDrawerGold: leg %d skipped - free margin %.0f will not carry %.2f lots",
                           legs + 1, AccountInfoDouble(ACCOUNT_MARGIN_FREE), lot);
         }
      }
      SetBasketStop(dir, vwap);
      Show(legs, dir, vol, vwap, "");
      return;
   }

   g_closing = false;
   g_lastLevel = 0;

   // ---- flat: should a new basket open? --------------------------------
   if(!g_ok)                                       { Show(0,0,0,0,""); return; }
   RollDay();
   DayEdgeHit();   // target or loss - checked every tick, not only after a close
   if(g_dayStop || shut)                           { Show(0,0,0,0,""); return; }
   if(SpreadUsd() > InpMaxSpreadUsd)               { Show(0,0,0,0,""); return; }
   if(TimeCurrent() - g_lastActSec < InpCooldownSec) { Show(0,0,0,0,""); return; }
   if(GetTickCount() - g_lastActMs < 1500)         { Show(0,0,0,0,""); return; }

   int    d   = PickDirection();
   double lot = NormLot(g_lots[0]);
   double px  = EntryPrice(d);
   if(!MarginOk(d, lot, px)) { Show(0,0,0,0,""); return; }
   g_lastActMs = GetTickCount(); g_lastActSec = TimeCurrent();
   bool sent = (d > 0) ? trade.Buy(lot, g_sym, 0, 0, 0, "drawer")
                       : trade.Sell(lot, g_sym, 0, 0, 0, "drawer");
   g_lastActMs = GetTickCount(); g_lastActSec = TimeCurrent();
   uint rc = trade.ResultRetcode();
   if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL))
   {
      g_lastLevel = px;
      int l2, d2; double v2, w2, e2; bool m2;
      if(ReadBasket(l2, d2, v2, w2, e2, m2) && !m2) SetBasketStop(d2, w2);
   }
   else
      PrintFormat("IdanDrawerGold: leg 1 refused ret=%d %s", rc, trade.ResultRetcodeDescription());
   Show(0,0,0,0,"");
}

//+------------------------------------------------------------------+
void Show(int legs, int dir, double vol, double vwap, string note)
{
   string head = g_ok ? "ARMED" : "HELD";
   string line;
   if(legs > 0 && dir != 0)
   {
      double px   = ExitPrice(dir);
      double move = (px - vwap) * dir;
      line = StringFormat("IdanDrawerGold %s  |  %s basket  legs %d/%d  %.2f lots  avg %.2f  now %.2f  %+.2f/oz  %+.0f$",
                          head, (dir > 0 ? "LONG" : "SHORT"), legs, g_legsCap, vol, vwap, px, move,
                          move * vol * g_unitVal);
   }
   else
   {
      line = StringFormat("IdanDrawerGold %s  |  flat  depth %d = %.2f lots, reaches $%.2f  |  today %+.2f%s",
                          head, g_legsCap, LadderSum(g_legsCap), LadderReach(), DayPnl(),
                          (g_dayStop ? "  [day stop]" : ""));
   }
   if(note   != "") line = line + "\n" + note;
   if(g_why  != "") line = line + "\n" + g_why;
   Comment(line);
}

//+------------------------------------------------------------------+
void OnTimer()
{
   HoldLock();
   RollDay();
   // a crashed instance leaves its lock behind; once it goes stale, take it.
   if(!g_ok && g_lockWait && ClaimLock())
   { g_ok = true; g_why = ""; g_lockWait = false; Print("IdanDrawerGold: the stale lock cleared - armed"); }
   Beat();
   int legs, dir; double vol, vwap, we; bool mixed;
   bool have = ReadBasket(legs, dir, vol, vwap, we, mixed);
   // v1.17: the wallet grows, the depth follows - re-fit to the wallet once
   // an hour, and only between baskets: a ladder is never resized under an
   // open basket.  Shrinks too, honestly, if the balance fell.
   if(g_ok && !have && !g_closing && InpMinBalance <= 0 &&
      TimeCurrent() - g_lastDepthChk >= 3600)
   {
      g_lastDepthChk = TimeCurrent();
      int want = (InpMaxLegs >= 1 && InpMaxLegs <= MAX_RUNGS) ? InpMaxLegs : 1;
      int deep = DeepestAffordable(AccountInfoDouble(ACCOUNT_BALANCE));
      int use  = MathMin(want, MathMax(deep, 1));
      if(deep >= 1 && use != g_legsCap)
      {
         ApplyDepth(use);
         PrintFormat("IdanDrawerGold: depth re-fit to the wallet - now %d rungs (%.2f lots full) of the %d asked.",
                     use, LadderSum(use), want);
      }
   }
   // the timer is the only thing that fires without ticks.  If the basket
   // must come off - a Friday flat, an unfinished close - it happens here
   // too, not only when the market decides to print a price.
   if(have && QuoteOk() && !mixed)
   {
      bool flatten = false; bool shut2 = FridayShut(flatten);
      if(g_closing)
      {
         // the same backoff the tick path uses - a broker that refuses to
         // close (AutoTrading switched off, market shut) must not be sent
         // thirty rejected orders a second, forever.
         if(TimeCurrent() - g_lastFinish >= CloseBackoffSec())
         { g_lastFinish = TimeCurrent(); CloseBasket("finish/timer"); }
      }
      else
      {
         string why = WantExit(legs, dir, vwap, flatten, shut2 || g_dayStop || !InpArmed);
         if(why != "")     CloseBasket(why + "/timer");
         else              SetBasketStop(dir, vwap);
      }
      ReadBasket(legs, dir, vol, vwap, we, mixed);
   }
   Show((have && QuoteOk()) ? legs : 0, dir, vol, vwap, (have && !QuoteOk()) ? "no usable quote" : "");
}

//+------------------------------------------------------------------+
//| heartbeat so the club mirror can see this bot without guessing    |
//+------------------------------------------------------------------+
void Beat()
{
   if(TimeCurrent() - g_lastBeat < 5) return;
   g_lastBeat = TimeCurrent();
   RefreshDayDeposits();   // every 5s: a deposit shows up within seconds, never as profit
   int legs, dir; double vol, vwap, we; bool mixed;
   bool have = ReadBasket(legs, dir, vol, vwap, we, mixed);
   double px = (have && QuoteOk()) ? ExitPrice(dir) : 0;
   double mv = (have && px > 0) ? (px - vwap) * dir : 0;
   string j = StringFormat(
      "{\"bot\":\"drawer_gold\",\"v\":\"1.20\",\"t\":%s,\"armed\":%s,\"why\":\"%s\","
      "\"symbol\":\"%s\",\"legs\":%d,\"max_legs\":%d,\"max_legs_ask\":%d,\"dir\":%d,\"lots\":%.2f,"
      "\"vwap\":%.2f,\"price\":%.2f,\"move\":%.3f,\"float\":%.2f,\"day\":%.2f,"
      "\"day_target\":%.2f,\"day_loss_stop\":%.2f,\"day_deposits\":%.2f,"
      "\"day_stop\":%s,\"day_reason\":\"%s\",\"mixed\":%s,\"closing\":%s,\"never_loss\":%s,"
      "\"balance\":%.2f,\"equity\":%.2f,\"margin_free\":%.2f,\"is_demo\":%s}",
      IntegerToString((long)TimeCurrent()), (g_ok ? "true" : "false"), g_why, g_sym,
      legs, g_legsCap, g_legsAsk, dir, vol, vwap, px, mv, mv * vol * g_unitVal, DayPnl(),
      InpDailyTargetUsd, InpDailyStopUsd, g_dayDeposits,
      (g_dayStop ? "true" : "false"), g_dayWhy, (mixed ? "true" : "false"), (g_closing ? "true" : "false"),
      (InpNeverLoss ? "true" : "false"),
      AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY),
      AccountInfoDouble(ACCOUNT_MARGIN_FREE),
      (AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO ? "true" : "false"));
   if(InpMagic == 770118)   // v1.20: only the primary speaks on the fixed wire
   {
      int h0 = FileOpen("idan_drawer_gold.json", FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(h0 != INVALID_HANDLE) { FileWriteString(h0, j); FileClose(h0); }
   }
   // 1.16: three drawers on one machine cannot share one heartbeat file.
   // Each instance also writes its own, keyed by the magic - the same key
   // that already separates the day files and the baskets. The fixed name
   // stays so the mirror that watches a single drawer keeps working.
   int h = FileOpen("idan_drawer_gold_" + IntegerToString((long)InpMagic) + ".json",
                FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h != INVALID_HANDLE) { FileWriteString(h, j); FileClose(h); }
}
//+------------------------------------------------------------------+
