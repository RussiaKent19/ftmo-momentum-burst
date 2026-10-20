//+------------------------------------------------------------------+
//| MomentumBurstEA.mq5                                              |
//| FTMO risk guard with a replaceable entry signal.                 |
//|                                                                  |
//| The guard is the point of this EA. The bundled momentum-burst    |
//| signal is an example only: research/ showed no edge after costs  |
//| (see README). Replace GetSignal() with your own rules.           |
//+------------------------------------------------------------------+
#property copyright "ftmo-momentum-burst"
#property version   "1.00"

#include <Trade/Trade.mqh>

//--- Risk guard
input group "Risk guard"
input double InpRiskPercent        = 0.5;   // Risk per trade, % of balance
input double InpInitialBalance     = 0.0;   // Challenge start balance (0 = balance at first start)
input double InpDailyLossLimitPct  = 4.0;   // Daily loss limit, % of initial balance (FTMO: 5)
input double InpMaxLossLimitPct    = 8.0;   // Max loss limit, % of initial balance (FTMO: 10)
input int    InpMaxOpenPositions   = 3;     // Max open positions of this EA (all symbols)
input bool   InpCloseBeforeWeekend = true;  // Close positions on Friday and pause until Monday
input int    InpFridayCloseHour    = 21;    // Friday close hour (server time)
input bool   InpAllowRealAccount   = false; // Allow trading on real-money accounts

//--- Example signal: momentum burst (see research/backtest.py)
input group "Signal: momentum burst"
input ENUM_TIMEFRAMES InpSignalTF  = PERIOD_D1;
input int    InpAtrLen             = 20;    // ATR length (mean bar range of prior bars)
input double InpTriggerAtr         = 1.0;   // Close-to-close move >= this many ATRs
input double InpCloseLocMin        = 0.7;   // Close in top (1-x) of bar for longs
input double InpMaxStopAtr         = 2.0;   // Skip if stop is further than this many ATRs
input int    InpHoldBars           = 5;     // Time exit after this many bars
input bool   InpAllowShort         = true;
input bool   InpSkipAfter3Runup    = true;  // Skip after 3 consecutive closes in signal direction

input group "Misc"
input long   InpMagic              = 20261020;

CTrade   trade;
datetime g_lastBar = 0;
string   g_gvPrefix;

//+------------------------------------------------------------------+
//| Persistent state shared by all instances on this account         |
//+------------------------------------------------------------------+
double GvGet(const string name, const double fallback)
{
   string key = g_gvPrefix + name;
   return GlobalVariableCheck(key) ? GlobalVariableGet(key) : fallback;
}

void GvSet(const string name, const double value)
{
   GlobalVariableSet(g_gvPrefix + name, value);
}

double InitialBalance()
{
   return InpInitialBalance > 0 ? InpInitialBalance : GvGet("init", AccountInfoDouble(ACCOUNT_BALANCE));
}

long DayKey()
{
   return (long)(TimeCurrent() / 86400);
}

// Equity floor for today: day-start reference minus the daily limit.
// The reference is max(balance, equity) at the first tick of the server day,
// which is at least as strict as FTMO's day-start balance.
double DailyFloor()
{
   long day = DayKey();
   if((long)GvGet("day", -1) != day)
   {
      GvSet("day", (double)day);
      GvSet("dayref", MathMax(AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY)));
      GvSet("dayblocked", 0);
   }
   return GvGet("dayref", AccountInfoDouble(ACCOUNT_BALANCE)) - InitialBalance() * InpDailyLossLimitPct / 100.0;
}

double MaxFloor()
{
   return InitialBalance() * (1.0 - InpMaxLossLimitPct / 100.0);
}

//+------------------------------------------------------------------+
//| Position helpers (only positions with our magic number)          |
//+------------------------------------------------------------------+
bool SelectOwn(const int index)
{
   ulong ticket = PositionGetTicket(index);
   return ticket != 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic;
}

int CountOwn(const string symbol = "")
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(SelectOwn(i) && (symbol == "" || PositionGetString(POSITION_SYMBOL) == symbol))
         n++;
   return n;
}

// Money lost (positive number) if every own position is stopped out from the current price.
// Returns -1 if a position has no stop loss, because then the risk is unbounded.
double OpenRiskToStops()
{
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!SelectOwn(i))
         continue;
      double sl = PositionGetDouble(POSITION_SL);
      if(sl <= 0)
         return -1;
      ENUM_ORDER_TYPE type = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double pnl;
      if(!OrderCalcProfit(type, PositionGetString(POSITION_SYMBOL), PositionGetDouble(POSITION_VOLUME),
                          PositionGetDouble(POSITION_PRICE_CURRENT), sl, pnl))
         return -1;
      total += MathMax(0.0, -pnl);
   }
   return total;
}

void CloseAllOwn(const string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket != 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         if(!trade.PositionClose(ticket))
            PrintFormat("Close %I64u failed (%s): %d", ticket, reason, trade.ResultRetcode());
   }
   PrintFormat("Closed all EA positions: %s", reason);
}

//+------------------------------------------------------------------+
//| Guard: returns false when trading must stop now                  |
//+------------------------------------------------------------------+
bool GuardOk()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(GvGet("maxblocked", 0) > 0)
      return false;
   if(equity <= MaxFloor())
   {
      CloseAllOwn("max loss limit reached");
      GvSet("maxblocked", 1);
      Alert("MomentumBurstEA: max loss limit reached. EA stopped permanently. Delete GlobalVariable ",
            g_gvPrefix, "maxblocked to re-enable.");
      return false;
   }

   double dayFloor = DailyFloor();
   if(GvGet("dayblocked", 0) > 0)
      return false;
   if(equity <= dayFloor)
   {
      CloseAllOwn("daily loss limit reached");
      GvSet("dayblocked", 1);
      return false;
   }
   return true;
}

bool IsWeekendWindow()
{
   if(!InpCloseBeforeWeekend)
      return false;
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   return (t.day_of_week == 5 && t.hour >= InpFridayCloseHour) || t.day_of_week == 6 || t.day_of_week == 0;
}

//+------------------------------------------------------------------+
//| Example signal. Replace this function with your own rules.       |
//| Returns +1 long, -1 short, 0 none; sets stop for the entry.      |
//| Evaluated once per new bar of InpSignalTF on the closed bar.     |
//+------------------------------------------------------------------+
int GetSignal(double &stop)
{
   int need = InpAtrLen + 2;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpSignalTF, 1, need, r) < need)
      return 0;
   // r[0] is the bar that just closed, r[1] the one before, ...

   double atr = 0;
   for(int k = 1; k <= InpAtrLen; k++)
      atr += r[k].high - r[k].low;
   atr /= InpAtrLen;

   double range = r[0].high - r[0].low;
   if(atr <= 0 || range <= 0)
      return 0;
   double move = r[0].close - r[1].close;
   bool expansion = range > MathMax(r[1].high - r[1].low, MathMax(r[2].high - r[2].low, r[3].high - r[3].low));
   double loc = (r[0].close - r[0].low) / range;

   bool up3 = r[1].close > r[2].close && r[2].close > r[3].close && r[3].close > r[4].close;
   bool down3 = r[1].close < r[2].close && r[2].close < r[3].close && r[3].close < r[4].close;

   if(move >= InpTriggerAtr * atr && expansion && loc >= InpCloseLocMin && !(InpSkipAfter3Runup && up3))
   {
      stop = r[0].low;
      double risk = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - stop;
      return (risk > 0 && risk <= InpMaxStopAtr * atr) ? 1 : 0;
   }
   if(InpAllowShort && -move >= InpTriggerAtr * atr && expansion && loc <= 1 - InpCloseLocMin && !(InpSkipAfter3Runup && down3))
   {
      stop = r[0].high;
      double risk = stop - SymbolInfoDouble(_Symbol, SYMBOL_BID);
      return (risk > 0 && risk <= InpMaxStopAtr * atr) ? -1 : 0;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Volume for a given money risk; 0 if below the minimum lot        |
//+------------------------------------------------------------------+
double VolumeForRisk(const ENUM_ORDER_TYPE type, const double entry, const double stop, const double riskMoney)
{
   double lossPerLot;
   if(!OrderCalcProfit(type, _Symbol, 1.0, entry, stop, lossPerLot) || lossPerLot >= 0)
      return 0;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vol = MathFloor(riskMoney / -lossPerLot / step) * step;  // floor, never round up
   if(vol < vmin)
      return 0;
   return NormalizeDouble(MathMin(vol, vmax), 8);
}

void TryEnter()
{
   if(CountOwn(_Symbol) > 0 || CountOwn() >= InpMaxOpenPositions || IsWeekendWindow())
      return;

   double stop = 0;
   int side = GetSignal(stop);
   if(side == 0)
      return;

   ENUM_ORDER_TYPE type = side > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double entry = side > 0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   stop = NormalizeDouble(stop, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(MathAbs(entry - stop) <= minDist)
      return;

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double vol = VolumeForRisk(type, entry, stop, riskMoney);
   if(vol <= 0)
   {
      PrintFormat("%s: signal skipped, minimum lot exceeds risk budget", _Symbol);
      return;
   }

   // Pre-trade gate: even if every stop (open + new) is hit, stay above both floors.
   double openRisk = OpenRiskToStops();
   double newRisk;
   if(openRisk < 0 || !OrderCalcProfit(type, _Symbol, vol, entry, stop, newRisk))
      return;
   double worstEquity = AccountInfoDouble(ACCOUNT_EQUITY) - openRisk + newRisk;  // newRisk is negative
   if(worstEquity <= DailyFloor() || worstEquity <= MaxFloor())
   {
      PrintFormat("%s: signal skipped, worst case %.2f would breach a loss floor", _Symbol, worstEquity);
      return;
   }

   bool ok = side > 0 ? trade.Buy(vol, _Symbol, 0, stop, 0, "MB")
                      : trade.Sell(vol, _Symbol, 0, stop, 0, "MB");
   if(!ok)
      PrintFormat("%s: order failed %d %s", _Symbol, trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

void ManageExits()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!SelectOwn(i) || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      int barsHeld = iBarShift(_Symbol, InpSignalTF, opened);  // 0 while still in the entry bar
      if(barsHeld >= InpHoldBars)
         trade.PositionClose((ulong)PositionGetInteger(POSITION_TICKET));
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL && !InpAllowRealAccount)
   {
      Alert("MomentumBurstEA: real account detected and InpAllowRealAccount=false. Not trading.");
      return INIT_FAILED;
   }
   if(InpRiskPercent <= 0 || InpRiskPercent > 2.0)
   {
      Alert("MomentumBurstEA: InpRiskPercent must be in (0, 2].");
      return INIT_PARAMETERS_INCORRECT;
   }
   g_gvPrefix = StringFormat("MB_%I64d_%I64d_", AccountInfoInteger(ACCOUNT_LOGIN), InpMagic);
   if(InpInitialBalance <= 0 && !GlobalVariableCheck(g_gvPrefix + "init"))
      GvSet("init", AccountInfoDouble(ACCOUNT_BALANCE));
   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   g_lastBar = iTime(_Symbol, InpSignalTF, 0);  // first entry check on the next bar, never mid-bar
   PrintFormat("MomentumBurstEA on %s: initial balance %.2f, daily floor %.2f, max floor %.2f",
               _Symbol, InitialBalance(), DailyFloor(), MaxFloor());
   return INIT_SUCCEEDED;
}

void OnTick()
{
   if(!GuardOk())
      return;

   if(IsWeekendWindow())
   {
      if(CountOwn() > 0)
         CloseAllOwn("weekend");
      return;
   }

   ManageExits();

   datetime bar = iTime(_Symbol, InpSignalTF, 0);
   if(bar == 0 || bar == g_lastBar)
      return;
   g_lastBar = bar;
   TryEnter();
}
//+------------------------------------------------------------------+
