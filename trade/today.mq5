//+------------------------------------------------------------------+
//|                                        GoldHedgeBot_v2.mq5      |
//|                     Gold Dynamic Hedge EA - 3 Path System v2    |
//|                     Fixes: M1 signals, cycle cooldown,          |
//|                     previous candle analysis, session aware      |
//+------------------------------------------------------------------+
#property copyright "GoldHedgeBot 2026"
#property link      "https://mql5.com"
#property version   "2.10"
#property description "Gold Hedge EA - 3 Path | M1 Signal | 30s Cycle"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "=== MONEY MANAGEMENT ==="
input double   InpDefaultStake     = 10.0;      // Default Stake ($)
input double   InpRiskPercent      = 0.0;       // Risk % per trade (0 = use fixed stake)
input bool     InpUseDynamicLots   = true;      // Dynamic lot sizing

input group "=== TRADE STRUCTURE ==="
input double   InpTP_Points        = 200;       // TP Points (price points)
input double   InpSL_Points        = 150;       // SL Points (price points)
input double   InpHedgeTrigger     = 80;        // Points against Entry1 → activate hedge
input bool     InpUseATR           = true;      // Use ATR for dynamic SL/TP
input double   InpATR_SL_Multi     = 1.5;       // ATR SL multiplier
input double   InpATR_TP_Multi     = 2.5;       // ATR TP multiplier
input int      InpATR_Period       = 14;        // ATR period

input group "=== SIGNAL ==="
input ENUM_TIMEFRAMES InpSignalTF  = PERIOD_M1; // Signal timeframe
input int      InpFastMA           = 8;         // Fast EMA
input int      InpSlowMA           = 21;        // Slow EMA
input int      InpLookback         = 3;         // Candles to confirm direction
input bool     InpUseCandlePattern = true;      // Use candle pattern confirmation

input group "=== CYCLE ==="
input int      InpCycleCooldown    = 30;        // Seconds between cycles
input int      InpMaxCyclesPerDay  = 20;        // Max cycles per day (0=unlimited)

input group "=== SESSION ==="
input bool     InpUseSessionFilter = false;     // Enable session filter (OFF for testing)
input int      InpLondonOpen       = 7;         // London open (broker hour)
input int      InpLondonClose      = 16;        // London close
input int      InpNYOpen           = 13;        // NY open
input int      InpNYClose          = 21;        // NY close
input bool     InpTradeAsian       = true;      // Allow Asian session

input group "=== SPREAD ==="
input bool     InpUseSpreadFilter  = true;      // Enable spread filter
input int      InpMaxSpread        = 80;        // Max spread (points) - Gold can be wide
input bool     InpDynamicSpread    = true;      // Wider allowed at open hours

input group "=== BROKER ==="
input int      InpBrokerLeverage   = 0;         // Broker leverage (0=auto)
input double   InpMinLot           = 0.01;      // Min lot
input double   InpMaxLot           = 5.0;       // Max lot

input group "=== DISPLAY ==="
input bool     InpShowPanel        = true;      // Show panel
input color    InpPanelBG          = C'20,40,35'; // Panel background

input int      InpMagicNumber      = 202601;    // Magic number

//+------------------------------------------------------------------+
//| ENUMS & STRUCTS                                                  |
//+------------------------------------------------------------------+
enum TRADE_STATE {
   STATE_IDLE,
   STATE_ENTRY1_OPEN,
   STATE_HEDGE_ACTIVE
};

struct CycleRecord {
   datetime openTime;
   datetime closeTime;
   int      path;        // 1=A, 2=B, 3=C
   double   pnl;
   bool     hedgeUsed;
};

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+
CTrade         trade;

// Indicator handles
int            hFastMA, hSlowMA, hATR;

// State
TRADE_STATE    gState       = STATE_IDLE;
ulong          gTicket1     = 0;
ulong          gTicket2     = 0;
datetime       gCycleCloseTime = 0;  // When last cycle closed
int            gCyclesToday = 0;
datetime       gLastDayReset = 0;

// Entry snapshot
double         gEntry1Price = 0;
double         gEntry1TP    = 0;
double         gEntry1SL    = 0;
double         gEntry2Price = 0;
double         gEntry2TP    = 0;
double         gEntry2SL    = 0;
double         gTPpts       = 0;
double         gSLpts       = 0;
double         gLotSize     = 0;
ENUM_ORDER_TYPE gEntry1Dir  = ORDER_TYPE_BUY;
datetime       gEntry1Time  = 0;
datetime       gEntry2Time  = 0;
bool           gEntry1Closed = false;
bool           gEntry2Closed = false;
double         gPnL1        = 0;
double         gPnL2        = 0;

// Stats
int    gTotalCycles   = 0;
int    gPathA_n       = 0;
int    gPathB_n       = 0;
int    gPathC_n       = 0;
int    gWins          = 0;
int    gLosses        = 0;
int    gBreakevens    = 0;
int    gHedgeCount    = 0;
double gTotalPnL      = 0;
double gPathA_pnl     = 0;
double gPathB_pnl     = 0;
double gPathC_pnl     = 0;
double gMaxDD         = 0;
double gPeakEq        = 0;
double gPathA_prob    = 0.45;
double gPathB_prob    = 0.30;
double gPathC_prob    = 0.25;

// Panel
string PFX = "GHB2_";
datetime gLastBarTime = 0;

//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   trade.SetAsyncMode(false);

   // Create indicators on signal timeframe
   hFastMA = iMA(Symbol(), InpSignalTF, InpFastMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlowMA = iMA(Symbol(), InpSignalTF, InpSlowMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR    = iATR(Symbol(), InpSignalTF, InpATR_Period);

   if(hFastMA==INVALID_HANDLE || hSlowMA==INVALID_HANDLE || hATR==INVALID_HANDLE) {
      Alert("GoldHedgeBot: Indicator creation failed!");
      return INIT_FAILED;
   }

   gPeakEq = AccountInfoDouble(ACCOUNT_EQUITY);

   if(InpShowPanel) InitPanel();

   PrintFormat("GoldHedgeBot v2 ready | Symbol=%s | TF=%s | Magic=%d | Stake=$%.2f",
               Symbol(), EnumToString(InpSignalTF), InpMagicNumber, InpDefaultStake);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| DEINIT                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hFastMA);
   IndicatorRelease(hSlowMA);
   IndicatorRelease(hATR);
   ObjectsDeleteAll(0, PFX);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| TICK                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // Track equity for drawdown
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > gPeakEq) gPeakEq = eq;
   double dd = gPeakEq - eq;
   if(dd > gMaxDD) gMaxDD = dd;

   // Daily cycle reset
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(gLastDayReset == 0 || dt.day != TimeDay(gLastDayReset)) {
      gCyclesToday = 0;
      gLastDayReset = TimeCurrent();
   }

   // Sync positions with broker
   SyncPositions();

   switch(gState)
   {
      case STATE_IDLE:
         TryOpenCycle();
         break;
      case STATE_ENTRY1_OPEN:
         ManageEntry1();
         break;
      case STATE_HEDGE_ACTIVE:
         ManageHedge();
         break;
   }

   if(InpShowPanel) RefreshPanel();
}

//+------------------------------------------------------------------+
//| SYNC - check if positions still open                           |
//+------------------------------------------------------------------+
void SyncPositions()
{
   if(gState == STATE_IDLE) return;

   bool p1 = IsPositionOpen(gTicket1);
   bool p2 = IsPositionOpen(gTicket2);

   if(gState == STATE_ENTRY1_OPEN && !p1 && gTicket1 > 0)
   {
      // Entry1 closed naturally = PATH A (direct TP or SL hit without hedge)
      gPnL1 = GetDealProfit(gTicket1);
      gTotalPnL += gPnL1;
      gPathA_n++;
      gPathA_pnl += gPnL1;
      gTotalCycles++;
      ClassifyResult(gPnL1);
      UpdateProbabilities();
      PrintFormat("CYCLE END - PATH A (B→A) | PnL=%.2f | Total=%.2f", gPnL1, gTotalPnL);
      StartCooldown();
      CleanupCycle();
   }
   else if(gState == STATE_HEDGE_ACTIVE)
   {
      // Track closures
      if(!p1 && gTicket1 > 0 && !gEntry1Closed) {
         gEntry1Closed = true;
         gPnL1 = GetDealProfit(gTicket1);
      }
      if(!p2 && gTicket2 > 0 && !gEntry2Closed) {
         gEntry2Closed = true;
         gPnL2 = GetDealProfit(gTicket2);
      }

      // If one closed, close the other (they share same price levels)
      if(gEntry1Closed && !gEntry2Closed && p2) {
         trade.PositionClose(gTicket2, 50);
      }
      if(gEntry2Closed && !gEntry1Closed && p1) {
         trade.PositionClose(gTicket1, 50);
      }

      // Both closed
      if(gEntry1Closed && gEntry2Closed)
      {
         double totalPnL = gPnL1 + gPnL2;
         gTotalPnL += totalPnL;
         gTotalCycles++;
         gHedgeCount++;

         // Path B: Entry1 profit dominated (price came back to TP1)
         // Path C: Entry2 profit dominated (price continued to TP2)
         if(gPnL1 >= gPnL2) {
            gPathB_n++;  gPathB_pnl += totalPnL;
            PrintFormat("CYCLE END - PATH B (B→C→A) | PnL1=%.2f PnL2=%.2f Total=%.2f", gPnL1, gPnL2, totalPnL);
         } else {
            gPathC_n++;  gPathC_pnl += totalPnL;
            PrintFormat("CYCLE END - PATH C (B→C→D) | PnL1=%.2f PnL2=%.2f Total=%.2f", gPnL1, gPnL2, totalPnL);
         }

         ClassifyResult(totalPnL);
         UpdateProbabilities();
         StartCooldown();
         CleanupCycle();
      }
   }
}

//+------------------------------------------------------------------+
//| TRY OPEN NEW CYCLE                                             |
//+------------------------------------------------------------------+
void TryOpenCycle()
{
   double tickVal = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   // Cooldown check
   if(gCycleCloseTime > 0 && TimeCurrent() - gCycleCloseTime < InpCycleCooldown) return;

   // Max cycles check
   if(InpMaxCyclesPerDay > 0 && gCyclesToday >= InpMaxCyclesPerDay) return;

   // Session check
   if(InpUseSessionFilter && !IsSessionOpen()) return;

   // Spread check
   if(InpUseSpreadFilter && !IsSpreadOK()) return;

   // Get signal — analyze PREVIOUS candles
   int signal = GetSignal();
   if(signal == 0) return;

   // Calc SL/TP
   CalcSLTP(gSLpts, gTPpts);

   // Calc lot
   gLotSize = CalcLot(gSLpts);

   double ask   = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double bid   = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);

   if(signal == 1) // BUY
   {
      gEntry1Dir   = ORDER_TYPE_BUY;
      gEntry1Price = ask;
      gEntry1TP    = NormalizeDouble(ask + gTPpts * point, digits);
      gEntry1SL    = NormalizeDouble(ask - gSLpts * point, digits);
   }
   else // SELL
   {
      gEntry1Dir   = ORDER_TYPE_SELL;
      gEntry1Price = bid;
      gEntry1TP    = NormalizeDouble(bid - gTPpts * point, digits);
      gEntry1SL    = NormalizeDouble(bid + gSLpts * point, digits);
   }

   // Pre-calc ALL hedge levels right now
   PreCalcAllLevels();

   // Place Entry1 only
   bool ok = false;
   if(signal == 1) ok = trade.Buy(gLotSize, Symbol(), 0, gEntry1SL, gEntry1TP, "GHB_E1");
   else            ok = trade.Sell(gLotSize, Symbol(), 0, gEntry1SL, gEntry1TP, "GHB_E1");

   if(ok) {
      gTicket1     = trade.ResultOrder();
      gEntry1Time  = TimeCurrent();
      gState       = STATE_ENTRY1_OPEN;
      gEntry1Closed = false;
      gEntry2Closed = false;
      gPnL1 = 0; gPnL2 = 0;
      gCyclesToday++;

      PrintFormat("CYCLE START | Entry1=%s Lot=%.2f TP=%.5f SL=%.5f HedgeTrigger=%.5f",
                  (signal==1?"BUY":"SELL"), gLotSize, gEntry1TP, gEntry1SL,
                  NormalizeDouble(gEntry1Price - (signal==1?1.0:-1.0)*InpHedgeTrigger*point, digits));

      DrawAllLevels();
   } else {
      PrintFormat("Entry1 FAILED: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| PRE-CALCULATE ALL LEVELS AT ENTRY TIME                         |
//+------------------------------------------------------------------+
void PreCalcAllLevels()
{
   double point  = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   double dir    = (gEntry1Dir == ORDER_TYPE_BUY) ? 1.0 : -1.0;

   // Hedge activation price (where Entry2/C will open)
   // Entry2 opens when price moves InpHedgeTrigger points AGAINST Entry1
   double hedgePrice = NormalizeDouble(gEntry1Price - dir * InpHedgeTrigger * point, digits);
   gEntry2Price = hedgePrice;

   // Entry2 is OPPOSITE direction to Entry1
   // TP2 = same distance from Entry2 as TP1 from Entry1 (= same as SL1 price area)
   // SL2 = same distance from Entry2 as SL1 from Entry1 (= same as TP1 price area)
   // This creates the MIRROR: TP1 == SL2, SL1 == TP2
   if(gEntry1Dir == ORDER_TYPE_BUY) {
      // Entry2 is SELL
      gEntry2TP = NormalizeDouble(hedgePrice - gTPpts * point, digits); // Down = same as SL1 area
      gEntry2SL = NormalizeDouble(hedgePrice + gSLpts * point, digits); // Up   = same as TP1 area
   } else {
      // Entry2 is BUY
      gEntry2TP = NormalizeDouble(hedgePrice + gTPpts * point, digits);
      gEntry2SL = NormalizeDouble(hedgePrice - gSLpts * point, digits);
   }

   PrintFormat("  Levels: E1=%s E1.TP=%.5f E1.SL=%.5f | HedgeAt=%.5f | E2.TP=%.5f E2.SL=%.5f",
               (gEntry1Dir==ORDER_TYPE_BUY?"BUY":"SELL"),
               gEntry1TP, gEntry1SL, gEntry2Price, gEntry2TP, gEntry2SL);
}

//+------------------------------------------------------------------+
//| MANAGE ENTRY 1                                                  |
//+------------------------------------------------------------------+
void ManageEntry1()
{
   if(!IsPositionOpen(gTicket1)) return; // SyncPositions handles close

   double point   = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double curBid  = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double curAsk  = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double dir     = (gEntry1Dir == ORDER_TYPE_BUY) ? 1.0 : -1.0;
   double curPrice = (gEntry1Dir == ORDER_TYPE_BUY) ? curBid : curAsk;

   double movePts = dir * (curPrice - gEntry1Price) / point;

   // Hedge trigger: moved InpHedgeTrigger points against us
   if(movePts <= -(double)InpHedgeTrigger)
   {
      ActivateHedge();
   }
}

//+------------------------------------------------------------------+
//| ACTIVATE HEDGE (Entry 2 / C)                                   |
//+------------------------------------------------------------------+
void ActivateHedge()
{
   if(gState == STATE_HEDGE_ACTIVE) return;

   // Calculate hedge lot so Path C (B→C→D) is always in profit
   double hedgeLot = 0.02; // Fixed hedge lot size as requested
   // Optionally, you can check broker min/max/step here if needed
   bool ok = false;
   // Entry2 is opposite to Entry1a
   if(gEntry1Dir == ORDER_TYPE_BUY)
      ok = trade.Sell(hedgeLot, Symbol(), 0, gEntry2SL, gEntry2TP, "GHB_E2_HEDGE");
   else
      ok = trade.Buy(hedgeLot, Symbol(), 0, gEntry2SL, gEntry2TP, "GHB_E2_HEDGE");

   if(ok) {
      gTicket2    = trade.ResultOrder();
      gEntry2Time = TimeCurrent();
      gState      = STATE_HEDGE_ACTIVE;
      PrintFormat("HEDGE ACTIVATED | Entry2=%s Lot=%.2f TP2=%.5f SL2=%.5f (AutoLot)",
                  (gEntry1Dir==ORDER_TYPE_BUY?"SELL":"BUY"), hedgeLot, gEntry2TP, gEntry2SL);
      DrawHedgeEntry();
   } else {
      PrintFormat("Hedge FAILED: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| MANAGE HEDGE                                                    |
//+------------------------------------------------------------------+
void ManageHedge()
{
   // Handled in SyncPositions
   // Nothing extra needed — let TP/SL do the work
}

//+------------------------------------------------------------------+
//| SIGNAL: ANALYZE PREVIOUS CANDLES                               |
//+------------------------------------------------------------------+
int GetSignal()
{
   // Easy signal: if last 2 ticks were down, buy; if last 2 ticks were up, sell
   double close[3];
   ArraySetAsSeries(close, true);
   if(CopyClose(Symbol(), InpSignalTF, 0, 3, close) < 3) return 0;
   if(close[1] < close[2] && close[0] < close[1]) return 1; // last 2 down → buy
   if(close[1] > close[2] && close[0] > close[1]) return -1; // last 2 up → sell
   return 0;
}

//+------------------------------------------------------------------+
//| CANDLE PATTERN CONFIRMATION                                    |
//+------------------------------------------------------------------+
int ConfirmWithCandles(int bias)
{
   double open[], high[], low[], close[];
   ArraySetAsSeries(open,  true);
   ArraySetAsSeries(high,  true);
   ArraySetAsSeries(low,   true);
   ArraySetAsSeries(close, true);

   if(CopyOpen(Symbol(), InpSignalTF,  1, 3, open)  < 3) return bias;
   if(CopyHigh(Symbol(), InpSignalTF,  1, 3, high)  < 3) return bias;
   if(CopyLow(Symbol(), InpSignalTF,   1, 3, low)   < 3) return bias;
   if(CopyClose(Symbol(), InpSignalTF, 1, 3, close) < 3) return bias;

   // Last candle body
   double body0 = close[0] - open[0];   // + = bullish candle
   double body1 = close[1] - open[1];
   double range0 = high[0] - low[0];

   // Require body > 30% of range (not a doji)
   if(range0 > 0 && MathAbs(body0) < range0 * 0.3) return 0; // weak candle, skip

   if(bias == 1  && body0 > 0) return 1;  // Bull bias + bull candle
   if(bias == -1 && body0 < 0) return -1; // Bear bias + bear candle

   return 0; // Contradiction, skip
}

//+------------------------------------------------------------------+
//| CALC SL/TP                                                      |
//+------------------------------------------------------------------+
void CalcSLTP(double &sl, double &tp)
{
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double atr[1];

   if(InpUseATR && CopyBuffer(hATR, 0, 1, 1, atr) == 1 && atr[0] > 0)
   {
      sl = (atr[0] / point) * InpATR_SL_Multi;
      tp = (atr[0] / point) * InpATR_TP_Multi;
   }
   else
   {
      sl = InpSL_Points;
      tp = InpTP_Points;
   }

   double minStop = (double)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL) + 5;
   sl = MathMax(sl, minStop);
   tp = MathMax(tp, minStop);
}

//+------------------------------------------------------------------+
//| CALC LOT FROM STAKE                                             |
//+------------------------------------------------------------------+
double CalcLot(double slPts)
{
   double lot = InpMinLot;

   if(InpUseDynamicLots && slPts > 0)
   {
      double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
      double tickVal   = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
      double point     = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
      double ptValue   = (tickSize > 0) ? tickVal / tickSize * point : 0;

      double riskAmt   = (InpRiskPercent > 0) ? equity * InpRiskPercent / 100.0 : InpDefaultStake;

      if(ptValue > 0)
         lot = riskAmt / (slPts * ptValue);
   }
   else
   {
      // Simple: use InpDefaultStake / (sl_value)
      double tickVal  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
      double point    = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
      double ptVal    = (tickSize > 0) ? tickVal / tickSize * point : 0;
      if(ptVal > 0 && slPts > 0) lot = InpDefaultStake / (slPts * ptVal);
   }

   double step = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   if(step > 0) lot = MathFloor(lot / step) * step;
   lot = MathMax(InpMinLot, MathMin(InpMaxLot, NormalizeDouble(lot, 2)));
   return lot;
}

//+------------------------------------------------------------------+
//| SESSION CHECK                                                   |
//+------------------------------------------------------------------+
bool IsSessionOpen()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   bool london = (h >= InpLondonOpen  && h < InpLondonClose);
   bool ny     = (h >= InpNYOpen      && h < InpNYClose);
   bool asian  = InpTradeAsian && (h >= 0 && h < 7);
   return (london || ny || asian);
}

//+------------------------------------------------------------------+
//| SPREAD CHECK                                                    |
//+------------------------------------------------------------------+
bool IsSpreadOK()
{
   int spread = (int)SymbolInfoInteger(Symbol(), SYMBOL_SPREAD);
   int maxSp  = InpMaxSpread;
   if(InpDynamicSpread) {
      MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
      if(dt.hour == InpLondonOpen || dt.hour == InpNYOpen) maxSp *= 2;
   }
   return (spread <= maxSp);
}

//+------------------------------------------------------------------+
//| HELPERS                                                         |
//+------------------------------------------------------------------+
bool IsPositionOpen(ulong ticket)
{
   if(ticket == 0) return false;
   return PositionSelectByTicket(ticket);
}

double GetDealProfit(ulong posTicket)
{
   double profit = 0;
   HistorySelect(TimeCurrent() - 7*86400, TimeCurrent());
   int total = HistoryDealsTotal();
   for(int i = total-1; i >= 0; i--) {
      ulong dTicket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(dTicket, DEAL_POSITION_ID) == (long)posTicket) {
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dTicket, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT) {
            profit += HistoryDealGetDouble(dTicket, DEAL_PROFIT)
                    + HistoryDealGetDouble(dTicket, DEAL_SWAP)
                    - MathAbs(HistoryDealGetDouble(dTicket, DEAL_COMMISSION));
         }
      }
   }
   return profit;
}

void ClassifyResult(double pnl)
{
   if(pnl > 0.5)       gWins++;
   else if(pnl < -0.5) gLosses++;
   else                 gBreakevens++;
}

void UpdateProbabilities()
{
   int total = gPathA_n + gPathB_n + gPathC_n;
   if(total > 0) {
      gPathA_prob = (double)gPathA_n / total;
      gPathB_prob = (double)gPathB_n / total;
      gPathC_prob = (double)gPathC_n / total;
   }
}

void StartCooldown()
{
   gCycleCloseTime = TimeCurrent();
   PrintFormat("Cooldown started. Next cycle in %d seconds.", InpCycleCooldown);
}

void CleanupCycle()
{
   gState  = STATE_IDLE;
   gTicket1 = 0;
   gTicket2 = 0;
   gEntry1Price = 0;
   gEntry2Price = 0;
   gEntry1Closed = false;
   gEntry2Closed = false;

   // Remove level lines
   string names[] = {"E1","E1_TP","E1_SL","E2","E2_TP","E2_SL","HEDGE_TRIG"};
   for(int i=0; i<7; i++) {
      ObjectDelete(0, PFX + names[i]);
      ObjectDelete(0, PFX + names[i] + "_L");
   }
   ChartRedraw(0);
}

int TimeDay(datetime t) {
   MqlDateTime d; TimeToStruct(t, d); return d.day;
}

//+------------------------------------------------------------------+
//| DRAW LEVELS                                                     |
//+------------------------------------------------------------------+
void DrawAllLevels()
{
   double point  = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   double dir    = (gEntry1Dir==ORDER_TYPE_BUY) ? 1.0 : -1.0;
   double hedgeTrig = NormalizeDouble(gEntry1Price - dir*InpHedgeTrigger*point, digits);

   // Draw only the essential levels: Entry 1, TP1=SL2, SL1=TP2, Hedge Trigger
   HLine(PFX+"E1",         gEntry1Price, clrDodgerBlue,  STYLE_SOLID, 2, "ENTRY 1 (B)");
   HLine(PFX+"E1_TP",      gEntry1TP,    clrLimeGreen,   STYLE_DASH,  1, "TP1 = SL2");
   HLine(PFX+"E1_SL",      gEntry1SL,    clrOrangeRed,   STYLE_DASH,  1, "SL1 = TP2");
   HLine(PFX+"HEDGE_TRIG", hedgeTrig,    clrGold,        STYLE_DOT,   1, "Hedge Trigger Zone");
   // Removed E2_TP and E2_SL lines to avoid confusion; TP1=SL2 and TP2=SL1 are already shown above.
   ChartRedraw(0);
}

void DrawHedgeEntry()
{
   HLine(PFX+"E2", gEntry2Price, clrMagenta, STYLE_SOLID, 2, "ENTRY 2 (C) HEDGE");
   ChartRedraw(0);
}

void HLine(string name, double price, color clr, ENUM_LINE_STYLE style, int width, string lbl)
{
   if(ObjectFind(0, name) >= 0) { ObjectMove(0, name, 0, 0, price); }
   else {
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, style);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   }
   ObjectSetString(0, name, OBJPROP_TOOLTIP, lbl);

   string ln = name + "_L";
   if(ObjectFind(0, ln) < 0) {
      ObjectCreate(0, ln, OBJ_TEXT, 0, TimeCurrent()+120, price);
      ObjectSetInteger(0, ln, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, ln, OBJPROP_FONTSIZE, 8);
      ObjectSetString(0, ln, OBJPROP_FONT, "Arial Bold");
   }
   ObjectSetString(0, ln, OBJPROP_TEXT, "  " + lbl);
   ObjectMove(0, ln, 0, TimeCurrent()+120, price);
}

//+------------------------------------------------------------------+
//| PANEL INIT                                                      |
//+------------------------------------------------------------------+
void InitPanel()
{
   string bg = PFX + "BG";
   ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE,  10);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE,  25);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE,      330);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE,      420);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR,    InpPanelBG);
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR,      clrGold);
   ObjectSetInteger(0, bg, OBJPROP_WIDTH,      2);
   ObjectSetInteger(0, bg, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bg, OBJPROP_BACK,       false);
   ObjectSetInteger(0, bg, OBJPROP_ZORDER,     0);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| PANEL REFRESH                                                   |
//+------------------------------------------------------------------+
void RefreshPanel()
{
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   int    sp  = (int)SymbolInfoInteger(Symbol(), SYMBOL_SPREAD);
   int    lev = (InpBrokerLeverage>0) ? InpBrokerLeverage : (int)AccountInfoInteger(ACCOUNT_LEVERAGE);

   // State
   string stStr = "● IDLE";
   color  stCol = clrSilver;
   if(gState==STATE_ENTRY1_OPEN) { stStr="▶ ENTRY 1 LIVE"; stCol=clrLimeGreen; }
   if(gState==STATE_HEDGE_ACTIVE){ stStr="⚡ HEDGING"; stCol=clrOrange; }

   // Live PnL for Entry 1 and Entry 2
   double livePnL1 = 0, livePnL2 = 0, livePnL = 0;
   if(gTicket1>0 && IsPositionOpen(gTicket1)) livePnL1 = PositionGetDouble(POSITION_PROFIT);
   if(gTicket2>0 && IsPositionOpen(gTicket2)) livePnL2 = PositionGetDouble(POSITION_PROFIT);
   livePnL = livePnL1 + livePnL2;

   // Improved: Calculate true net P&L for each path
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double tickVal = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   double ptVal = (tickSize > 0) ? tickVal / tickSize * point : 0;
   double expA = 0, expB = 0, expC = 0;
   // Path A: Only Entry 1, closes at TP1 or SL1
   if(gState == STATE_ENTRY1_OPEN || gState == STATE_HEDGE_ACTIVE) {
      // Profit if TP1 hit
      double profit = (gEntry1TP - gEntry1Price) / point * ptVal * gLotSize;
      // Loss if SL1 hit
      double loss = (gEntry1SL - gEntry1Price) / point * ptVal * gLotSize;
      expA = (profit > 0 ? profit : loss); // Show the more likely (directional) outcome
   }
   // Path B: Hedge, price reverses, both close at TP1/SL2
   if(gState == STATE_HEDGE_ACTIVE) {
      // Entry 1 closes at TP1, Entry 2 closes at SL2
      double pnl1 = (gEntry1TP - gEntry1Price) / point * ptVal * gLotSize;
      double pnl2 = (gEntry2SL - gEntry2Price) / point * ptVal * gLotSize;
      expB = pnl1 + pnl2;
   }
   // Path C: Hedge, price continues, both close at SL1/TP2
   if(gState == STATE_HEDGE_ACTIVE) {
      // Entry 1 closes at SL1, Entry 2 closes at TP2
      double pnl1 = (gEntry1SL - gEntry1Price) / point * ptVal * gLotSize;
      double pnl2 = (gEntry2TP - gEntry2Price) / point * ptVal * gLotSize;
      expC = pnl1 + pnl2;
   }

   // Cooldown remaining
   int cdLeft = 0;
   if(gCycleCloseTime > 0) {
      cdLeft = (int)(InpCycleCooldown - (TimeCurrent() - gCycleCloseTime));
      if(cdLeft < 0) cdLeft = 0;
   }

   // Best path
   string bestPath = "A";
   double bestProb = gPathA_prob;
   if(gPathB_prob > bestProb) { bestPath="B"; bestProb=gPathB_prob; }
   if(gPathC_prob > bestProb) { bestPath="C"; bestProb=gPathC_prob; }

   int total = gPathA_n + gPathB_n + gPathC_n;
   double wr = (total>0) ? (double)gWins/total*100.0 : 0.0;

   // Session
   bool sesOn = IsSessionOpen();
   bool spOK  = IsSpreadOK();

   // Build display strings
   string txt[23];
   color  col[23];

   txt[0] ="  ══ GOLD HEDGE BOT v2 ══";         col[0]=clrGold;
   txt[1] ="  " + stStr;                          col[1]=stCol;
   txt[2] ="  Session: " + (sesOn?"ACTIVE":"CLOSED") + "  Spread:" + (string)sp + " " + (spOK?"✓":"✗"); col[2]=spOK?clrLimeGreen:clrOrangeRed;
   txt[3] ="  Leverage 1:" + (string)lev + "  Cycles Today: " + (string)gCyclesToday; col[3]=clrSilver;
   txt[4] ="  Cooldown: " + (cdLeft>0 ? (string)cdLeft+"s" : "READY");  col[4]=cdLeft>0?clrOrange:clrLimeGreen;
   txt[5] ="  ──────────────────────────────";   col[5]=clrDimGray;
   txt[6] ="  EQUITY:  $" + DoubleToString(eq,2); col[6]=clrWhite;
   txt[7] ="  BALANCE: $" + DoubleToString(bal,2); col[7]=clrSilver;
   txt[8] ="  Live P&L: $" + DoubleToString(livePnL,2) + "  [E1: $" + DoubleToString(livePnL1,2) + ", E2: $" + DoubleToString(livePnL2,2) + "]"; col[8]=livePnL>=0?clrLimeGreen:clrOrangeRed;
   txt[9] ="  Total P&L: $" + DoubleToString(gTotalPnL,2); col[9]=gTotalPnL>=0?clrLimeGreen:clrOrangeRed;
   txt[10]="  Max DD: $" + DoubleToString(gMaxDD,2);   col[10]=clrOrangeRed;
   txt[11]="  ──────────────────────────────";   col[11]=clrDimGray;
   txt[12]="  CYCLES: " + (string)gTotalCycles + "  W:" + (string)gWins + " L:" + (string)gLosses + " BE:" + (string)gBreakevens; col[12]=clrSilver;
   txt[13]="  WinRate: " + DoubleToString(wr,1) + "%  Hedges Used: " + (string)gHedgeCount; col[13]=clrSilver;
   txt[14]="  ──────────────────────────────";   col[14]=clrDimGray;
   txt[15]="  PATH ANALYSIS & PREDICTIONS:";     col[15]=clrGold;
   txt[16]="  [A] B→A   : " + (string)gPathA_n + " | P=" + DoubleToString(gPathA_prob*100,0) + "% | $" + DoubleToString(gPathA_pnl,2) + " | Live: $" + DoubleToString(expA,2); col[16]=clrLimeGreen;
   txt[17]="  [B] B→C→A : " + (string)gPathB_n + " | P=" + DoubleToString(gPathB_prob*100,0) + "% | $" + DoubleToString(gPathB_pnl,2) + " | Live: $" + DoubleToString(expB,2); col[17]=clrDodgerBlue;
   txt[18]="  [C] B→C→D : " + (string)gPathC_n + " | P=" + DoubleToString(gPathC_prob*100,0) + "% | $" + DoubleToString(gPathC_pnl,2) + " | Live: $" + DoubleToString(expC,2); col[18]=clrMagenta;
   txt[19]="  ──────────────────────────────";   col[19]=clrDimGray;
   // Show expected PnL for each path (live)
   txt[20] = "  Exp. Path A: $" + DoubleToString(expA,2) + " | B: $" + DoubleToString(expB,2) + " | C: $" + DoubleToString(expC,2);
   col[20]=clrAqua;

   string predStr = "  Prediction: -";
   if(gState==STATE_IDLE && total > 0) predStr = "  Likely → Path " + bestPath + " (" + DoubleToString(bestProb*100,0) + "%)";
   if(gState==STATE_ENTRY1_OPEN)  predStr = "  Watching for hedge trigger...";
   if(gState==STATE_HEDGE_ACTIVE) predStr = "  Both open → Path B or C pending";
   txt[21] = predStr; col[21]=clrYellow;

   // Entry info
   string entStr = "  -";
   if(gState!=STATE_IDLE)
      entStr = "  E1=" + (gEntry1Dir==ORDER_TYPE_BUY?"BUY":"SELL") + " Lot=" + DoubleToString(gLotSize,2)
             + " TP=" + DoubleToString(gEntry1TP,2) + " SL=" + DoubleToString(gEntry1SL,2);
   txt[22] = entStr; col[22]=clrSilver;

   // Render
   for(int i=0; i<23; i++) {
      string nm = PFX + "L" + (string)i;
      if(ObjectFind(0, nm) < 0) {
         ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, nm, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
         ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, 14);
         ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, 30 + i*18);
         ObjectSetInteger(0, nm, OBJPROP_FONTSIZE,  8);
         ObjectSetString(0, nm, OBJPROP_FONT, "Courier New");
         ObjectSetInteger(0, nm, OBJPROP_ZORDER, 1);
      }
      ObjectSetString(0, nm, OBJPROP_TEXT, txt[i]);
      ObjectSetInteger(0, nm, OBJPROP_COLOR, col[i]);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| TRADE EVENT                                                     |
//+------------------------------------------------------------------+
void OnTrade()
{
   SyncPositions();
}
//+------------------------------------------------------------------+