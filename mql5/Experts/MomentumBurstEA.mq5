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

//--- News and political risk (MT5 economic calendar; not available in the Strategy Tester)
input group "News / political risk"
input bool     InpNewsFilter         = true; // Block entries around high-impact events of the symbol's currencies
input int      InpNewsBlockBeforeMin = 30;   // Minutes before an event without new entries
input int      InpNewsBlockAfterMin  = 30;   // Minutes after an event without new entries
input int      InpNewsFlatBeforeMin  = 0;    // Close this symbol's positions this many minutes before an event (0 = off)
input datetime InpPauseUntil         = 0;    // No new entries until this server time (manual pause, e.g. elections)

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

//--- Telegram trade notifications. Add https://api.telegram.org under
//--- Tools > Options > Expert Advisors > "Allow WebRequest for listed URL".
input group "Telegram"
input string InpTelegramToken      = "";    // Bot token from @BotFather (empty = off)
input string InpTelegramChatId     = "";    // Chat ID that receives the messages

input group "Misc"
input long   InpMagic              = 20261020;

CTrade   trade;
datetime g_lastBar = 0;
string   g_gvPrefix;

//+------------------------------------------------------------------+
//| Telegram                                                         |
//+------------------------------------------------------------------+
string UrlEncode(const string text)
{
   uchar bytes[];
   int n = StringToCharArray(text, bytes, 0, WHOLE_ARRAY, CP_UTF8) - 1;  // drop terminating zero
   string out = "";
   for(int i = 0; i < n; i++)
   {
      uchar b = bytes[i];
      if((b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || b == '-' || b == '_' || b == '.' || b == '~')
         out += CharToString(b);
      else
         out += StringFormat("%%%02X", b);
   }
   return out;
}

void Notify(const string text)
{
   if(InpTelegramToken == "" || InpTelegramChatId == "" || MQLInfoInteger(MQL_TESTER))
      return;
   string url = "https://api.telegram.org/bot" + InpTelegramToken + "/sendMessage";
   string body = "chat_id=" + UrlEncode(InpTelegramChatId) + "&text=" + UrlEncode(text);
   char data[], result[];
   string headers;
   StringToCharArray(body, data, 0, StringLen(body));  // body is pure ASCII after encoding
   int code = WebRequest("POST", url, "Content-Type: application/x-www-form-urlencoded\r\n", 5000, data, result, headers);
   if(code != 200)
      PrintFormat("Telegram failed: HTTP %d, error %d (is https://api.telegram.org allowed for WebRequest?)", code, GetLastError());
}

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
      Notify(StringFormat("⛔ Max-Verlustgrenze erreicht. Alle EA-Positionen geschlossen, EA dauerhaft gestoppt. Equity %.2f", equity));
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
      Notify(StringFormat("⚠️ Tagesverlustgrenze erreicht. Alle EA-Positionen geschlossen, Pause bis morgen. Equity %.2f", equity));
      return false;
   }
   return true;
}

// True if a high-importance calendar event for the symbol's base or profit currency
// falls between afterMin minutes ago and beforeMin minutes from now.
bool HighImpactEventWithin(const int beforeMin, const int afterMin)
{
   datetime now = TimeTradeServer();
   string ccys[2];
   ccys[0] = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   ccys[1] = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   for(int c = 0; c < 2; c++)
   {
      if(c == 1 && ccys[1] == ccys[0])
         break;
      MqlCalendarValue values[];
      if(!CalendarValueHistory(values, now - afterMin * 60, now + beforeMin * 60, NULL, ccys[c]))
         continue;
      for(int i = 0; i < ArraySize(values); i++)
      {
         MqlCalendarEvent ev;
         if(CalendarEventById(values[i].event_id, ev) && ev.importance == CALENDAR_IMPORTANCE_HIGH)
            return true;
      }
   }
   return false;
}

void CloseOwnOnSymbol(const string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(SelectOwn(i) && PositionGetString(POSITION_SYMBOL) == _Symbol)
         if(!trade.PositionClose((ulong)PositionGetInteger(POSITION_TICKET)))
            PrintFormat("%s: close failed (%s): %d", _Symbol, reason, trade.ResultRetcode());
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
   if(InpPauseUntil > 0 && TimeCurrent() < InpPauseUntil)
      return;
   if(InpNewsFilter && HighImpactEventWithin(InpNewsBlockBeforeMin, InpNewsBlockAfterMin))
   {
      PrintFormat("%s: entry check skipped, high-impact event nearby", _Symbol);
      return;
   }

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

// One message per EA deal. Every instance sees every deal, so each reports only its own symbol.
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || !HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic || HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   string side = HistoryDealGetInteger(trans.deal, DEAL_TYPE) == DEAL_TYPE_BUY ? "BUY" : "SELL";
   double vol = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   double price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

   if(entry == DEAL_ENTRY_IN)
   {
      double sl = PositionSelectByTicket(HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID)) ? PositionGetDouble(POSITION_SL) : 0;
      Notify(StringFormat("🟢 %s %s %.2f Lot @ %s | SL %s", _Symbol, side, vol,
                          DoubleToString(price, digits), DoubleToString(sl, digits)));
   }
   else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
   {
      double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      long reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
      string why = reason == DEAL_REASON_SL ? "Stop-Loss" : reason == DEAL_REASON_TP ? "Take-Profit"
                 : reason == DEAL_REASON_EXPERT ? "EA" : reason == DEAL_REASON_SO ? "Stop-Out" : "manuell/sonstig";
      Notify(StringFormat("%s %s geschlossen (%s) %.2f Lot @ %s | P/L %.2f %s | Equity %.2f",
                          pnl >= 0 ? "✅" : "🔴", _Symbol, why, vol, DoubleToString(price, digits),
                          pnl, AccountInfoString(ACCOUNT_CURRENCY), AccountInfoDouble(ACCOUNT_EQUITY)));
   }
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

   static datetime lastNewsCheck = 0;
   if(InpNewsFilter && InpNewsFlatBeforeMin > 0 && TimeCurrent() - lastNewsCheck >= 60 && CountOwn(_Symbol) > 0)
   {
      lastNewsCheck = TimeCurrent();
      if(HighImpactEventWithin(InpNewsFlatBeforeMin, 0))
         CloseOwnOnSymbol("high-impact event ahead");
   }

   datetime bar = iTime(_Symbol, InpSignalTF, 0);
   if(bar == 0 || bar == g_lastBar)
      return;
   g_lastBar = bar;
   TryEnter();
}
//+------------------------------------------------------------------+
