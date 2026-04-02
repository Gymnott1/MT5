//+------------------------------------------------------------------+
//|                                             HedgeStrike_EA.mq5   |
//|                    Strategy: Entry + Hedge Strike System          |
//|                      Production-Hardened v4.0                     |
//|                                                                    |
//|  CORE IDEA:                                                        |
//|  Open E1 (your signal direction) + place opposite STOP order      |
//|  ("Strike") halfway between E1 entry and E1 SL.                   |
//|  Strike lot = 2.1x E1 lot so the math always favours us.          |
//|                                                                    |
//|  MATH PROOF (SL=400 Gap=200 Lot1=0.1 Lot2=0.21):                 |
//|  Scenario A: TP hit, Strike pending  -> WIN (full TP profit)      |
//|  Scenario B: Strike fires, then SL   -> BREAK-EVEN (+$0.42/pip)   |
//|              (SL-Gap)*Lot2 > SL*Lot1 since 200*0.21 > 400*0.1    |
//|  Scenario C: Strike fires, reverses  -> EA trails; basket +ve at  |
//|              ~Gap*Lot2/(Lot2-Lot1) pts past E1 entry (~382 pts)   |
//|              i.e. just before TP1 -> SMALL WIN                    |
//|                                                                    |
//|  NEW IN v4.0:                                                      |
//|  1. BUG FIX — handle positions==0 && pendingExists (broker TP     |
//|     auto-closes E1 while Strike pending — was an infinite hang)   |
//|  2. Emergency SL on E2 — protects against runaway loss if EA      |
//|     disconnects while both legs are open                          |
//|  3. Commission included in GetBasketProfit()                      |
//|  4. Almost-Hit Guard (80% of TP -> SL to BE, delete Strike)       |
//|  5. Trailing Break-Even in Phase 2                                 |
//+------------------------------------------------------------------+

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- Inputs
input group "== TRADE SIZING =="
input double InpLot1           = 0.10;  // Entry 1 Lot Size
input double InpLotMultiplier  = 2.1;   // Strike Lot Multiplier (min 2.0)

input group "== STAKE CONTROL =="
input bool   InpStakeCapOn     = true;  // Limit cycle margin by stake budget
input double InpStakeUSD       = 10.0;  // Stake budget in account currency
input double InpStakeUsePct    = 100.0; // % of stake allowed for margin usage
input bool   InpAutoFitLotToStake = true; // Auto-reduce Lot1 to fit stake budget

input group "== PRICE LEVELS =="
input int    InpTPPoints       = 400;   // Take Profit  (points from Entry 1)
input int    InpSLPoints       = 400;   // Stop Loss    (points from Entry 1)
input int    InpGapPoints      = 200;   // Gap to Strike (must be < SL)
input int    InpE2EmergSLPts   = 0;     // E2 emergency SL in points (0 = off)

input group "== SPREAD PROTECTION =="
input bool   InpCheckSpread    = true;  // Block entry if spread is too wide
input int    InpMaxSpreadPts   = 30;    // Max allowed spread in points

input group "== EXIT THRESHOLDS =="
input double InpPhase1MinWin   = 0.0;  // Min $ profit for Phase 1 exit
input double InpPhase2MinWin   = 0.10; // Min $ profit for Phase 2 exit

input group "== ALMOST-HIT GUARD (new v3.0) =="
input bool   InpAlmostHitOn    = true; // Enable Almost-Hit Guard
input int    InpAlmostHitPct   = 80;   // % of TP to trigger guard (e.g. 80)

input group "== TRAILING BREAK-EVEN (new v3.0) =="
input bool   InpTrailBEOn      = true;  // Enable Trailing Break-Even in Phase 2
input double InpTrailBEStep    = 0.50;  // Trail ratchet step in $

input group "== EA SETTINGS =="
input int    InpMagic          = 12345; // Magic Number
input int    InpCooldownBars   = 3;     // Bars to wait before new cycle
input int    InpSlippage       = 20;    // Max slippage in points

input group "== SIGNAL MODE =="
enum ENUM_FORCE_DIR
{
   FORCE_OFF  = 0, // Off — use real signal
   FORCE_BUY  = 1, // Force BUY every cycle
   FORCE_SELL = 2, // Force SELL every cycle
   FORCE_ALTERNATE = 3 // Alternate BUY/SELL each cycle
};
input ENUM_FORCE_DIR InpForceDir    = FORCE_BUY; // Force direction (for testing)
input int            InpRetrySeconds = 30;        // Seconds between new cycles

//--- Globals
CTrade        trade;
CPositionInfo posInfo;
COrderInfo    ordInfo;

datetime        g_lastCycleBar   = 0;
bool            g_cycleComplete  = false;
ENUM_ORDER_TYPE g_phase1Dir      = ORDER_TYPE_BUY;
datetime        g_lastEntryTime  = 0;   // tracks when last cycle was opened
bool            g_lastWasBuy     = false; // for FORCE_ALTERNATE mode

// Almost-Hit Guard state
bool            g_almostHitDone  = false;

// Trailing Break-Even state
double          g_trailBEPeak    = -DBL_MAX; // highest net profit seen in Phase 2

//+------------------------------------------------------------------+
//| Auto-detect broker filling mode via execution model              |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   ENUM_SYMBOL_TRADE_EXECUTION exeMode =
      (ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_EXEMODE);

   switch(exeMode)
   {
      case SYMBOL_TRADE_EXECUTION_REQUEST:
      case SYMBOL_TRADE_EXECUTION_INSTANT:
         return ORDER_FILLING_FOK;
      case SYMBOL_TRADE_EXECUTION_MARKET:
         return ORDER_FILLING_IOC;
      case SYMBOL_TRADE_EXECUTION_EXCHANGE:
      default:
         return ORDER_FILLING_RETURN;
   }
}

//+------------------------------------------------------------------+
//| Normalize lot to broker volume step                              |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);

   int decimals = (int)MathRound(-MathLog10(lotStep));
   return NormalizeDouble(lot, MathMax(decimals, 2));
}

//+------------------------------------------------------------------+
//| Spread guard                                                     |
//+------------------------------------------------------------------+
bool SpreadIsOk()
{
   if(!InpCheckSpread) return true;

   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    spread = (int)MathRound((ask - bid) / point);

   if(spread > InpMaxSpreadPts)
   {
      Print("ENTRY BLOCKED — spread ", spread, " pts > max ", InpMaxSpreadPts, " pts");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Calculates required margin for one full cycle (E1 + Strike)     |
//+------------------------------------------------------------------+
bool CalcCycleRequiredMargin(ENUM_ORDER_TYPE dir, double lot1, double lot2,
                             double ask, double bid, double &required)
{
   ENUM_ORDER_TYPE e1Type = dir;
   ENUM_ORDER_TYPE e2Type = (dir == ORDER_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

   double e1Price = (e1Type == ORDER_TYPE_BUY) ? ask : bid;
   double e2Price = (e2Type == ORDER_TYPE_BUY) ? ask : bid;

   double m1 = 0, m2 = 0;
   if(!OrderCalcMargin(e1Type, _Symbol, lot1, e1Price, m1)) return false;
   if(!OrderCalcMargin(e2Type, _Symbol, lot2, e2Price, m2)) return false;

   required = m1 + m2;
   return true;
}

//+------------------------------------------------------------------+
//| Finds the highest Lot1 that fits stake budget                    |
//| Returns 0 if even min lot does not fit                           |
//+------------------------------------------------------------------+
double FitLot1ToStake(ENUM_ORDER_TYPE dir, double requestedLot,
                      double ask, double bid)
{
   requestedLot = NormalizeLot(requestedLot);
   if(!InpStakeCapOn || !InpAutoFitLotToStake) return requestedLot;

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double budget  = InpStakeUSD * (InpStakeUsePct / 100.0);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double cap = MathMin(budget, freeMargin);

   if(cap <= 0) return 0.0;

   int decimals = (int)MathRound(-MathLog10(lotStep));
   decimals = MathMax(decimals, 2);

   double lot = requestedLot;
   for(int i = 0; i < 10000 && lot >= minLot - (lotStep * 0.5); i++)
   {
      lot = NormalizeLot(lot);
      double lot2 = NormalizeLot(lot * InpLotMultiplier);
      double required = 0;

      if(CalcCycleRequiredMargin(dir, lot, lot2, ask, bid, required))
      {
         if(required <= cap)
            return lot;
      }

      lot = NormalizeDouble(lot - lotStep, decimals);
   }

   return 0.0;
}

//+------------------------------------------------------------------+
//| Stake budget guard                                               |
//| Blocks a cycle if E1 + Strike margin exceeds configured stake    |
//+------------------------------------------------------------------+
bool StakeBudgetOk(ENUM_ORDER_TYPE dir, double lot1, double lot2,
                   double ask, double bid)
{
   if(!InpStakeCapOn) return true;

   double budget = InpStakeUSD * (InpStakeUsePct / 100.0);
   if(budget <= 0)
   {
      Print("STAKE BLOCKED — budget <= 0. Check InpStakeUSD/InpStakeUsePct.");
      return false;
   }

   double required = 0;
   if(!CalcCycleRequiredMargin(dir, lot1, lot2, ask, bid, required))
   {
      Print("STAKE BLOCKED — OrderCalcMargin failed.");
      return false;
   }

   if(required > budget)
   {
      Print("STAKE BLOCKED — required margin $", DoubleToString(required, 2),
            " > stake budget $", DoubleToString(budget, 2),
            " | Reduce InpLot1 or increase stake.");
      return false;
   }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(required > freeMargin)
   {
      Print("MARGIN BLOCKED — required $", DoubleToString(required, 2),
            " > free margin $", DoubleToString(freeMargin, 2));
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| v3.0 FIX 1: True net profit including commission                 |
//| Commission on ECN brokers is negative and charged at open+close  |
//+------------------------------------------------------------------+
double GetBasketProfit()
{
   double total = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
         if(PositionGetInteger(POSITION_MAGIC) == InpMagic)
            total += PositionGetDouble(POSITION_PROFIT)
                   + PositionGetDouble(POSITION_SWAP)
                   + PositionGetDouble(POSITION_COMMISSION); // ECN true cost
   }
   return total;
}

//+------------------------------------------------------------------+
//| v3.0 FIX 2: Almost-Hit Guard                                     |
//| If price reaches InpAlmostHitPct% of TP, move SL to break-even  |
//| and delete the Strike pending — locks win, avoids Strike battle  |
//+------------------------------------------------------------------+
void CheckAlmostHit()
{
   if(!InpAlmostHitOn || g_almostHitDone) return;

   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * point;
   double threshold = InpTPPoints * InpAlmostHitPct / 100.0; // e.g. 80% of 400 = 320 pts

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curPrice   = PositionGetDouble(POSITION_PRICE_CURRENT);
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double progressPts = 0;
      double newSL       = 0;

      if(ptype == POSITION_TYPE_BUY)
      {
         progressPts = (curPrice - openPrice) / point;
         // Break-even SL = entry + spread (tiny guaranteed win)
         newSL = NormalizeDouble(openPrice + spread, digits);
      }
      else
      {
         progressPts = (openPrice - curPrice) / point;
         newSL = NormalizeDouble(openPrice - spread, digits);
      }

      if(progressPts >= threshold)
      {
         Print("ALMOST-HIT GUARD | Progress: ", progressPts, " pts >= ",
               threshold, " pts threshold");
         Print("Moving SL to break-even: ", newSL, " | Deleting Strike");

         // Move SL to break-even on Entry 1
         double curTP = PositionGetDouble(POSITION_TP);
         trade.PositionModify(ticket, newSL, curTP);

         // Delete the Strike pending order — no longer needed
         for(int j = OrdersTotal()-1; j >= 0; j--)
         {
            ulong ordTicket = OrderGetTicket(j);
            if(OrderSelect(ordTicket))
               if(OrderGetInteger(ORDER_MAGIC) == InpMagic)
                  trade.OrderDelete(ordTicket);
         }

         g_almostHitDone = true;
         break;
      }
   }
}

//+------------------------------------------------------------------+
//| v3.0 FIX 3: Trailing Break-Even for Phase 2 (Scenario C)        |
//| Ratchets the exit floor up as basket profit improves             |
//| e.g. basket peaks at $2.00 → floor rises to $1.50 (with $0.50   |
//| step) — price reversal exits at $1.50 not $0.10                  |
//+------------------------------------------------------------------+
double GetTrailingExitFloor()
{
   if(!InpTrailBEOn) return InpPhase2MinWin;

   // Update peak
   double currentProfit = GetBasketProfit();
   if(currentProfit > g_trailBEPeak)
      g_trailBEPeak = currentProfit;

   // Floor = peak minus one step, but never below InpPhase2MinWin
   double floor = g_trailBEPeak - InpTrailBEStep;
   return MathMax(floor, InpPhase2MinWin);
}

//+------------------------------------------------------------------+
//| Self-test: validates ALL conditions required for a trade         |
//| Call this from OnInit or manually — check Experts log            |
//+------------------------------------------------------------------+
void RunSelfTest()
{
   Print("====== SELF-TEST START ======");
   bool allOk = true;

   // 1. Is AutoTrading enabled?
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Print("FAIL [1] AutoTrading is DISABLED in terminal.");
      Print("       Fix: Click the AutoTrading button (top toolbar) to enable it.");
      allOk = false;
   } else Print("PASS [1] AutoTrading enabled.");

   // 2. Is EA trading allowed on this chart?
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Print("FAIL [2] EA trading NOT allowed on this chart.");
      Print("       Fix: EA properties -> Common tab -> tick 'Allow Algo Trading'.");
      allOk = false;
   } else Print("PASS [2] EA trading allowed on chart.");

   // 3. Is the account connected and trade-enabled?
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      Print("FAIL [3] Terminal NOT connected to broker.");
      Print("       Fix: Check internet connection / re-login.");
      allOk = false;
   } else Print("PASS [3] Terminal connected.");

   // 4. Lot size valid?
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(InpLot1 < minLot || InpLot1 > maxLot)
   {
      Print("FAIL [4] InpLot1=", InpLot1, " is outside broker range [",
            minLot, " - ", maxLot, "]");
      Print("       Fix: Set InpLot1 to at least ", minLot);
      allOk = false;
   } else Print("PASS [4] Lot1=", InpLot1, " valid (min=", minLot, " step=", lotStep, ")");

   // 5. Signal configured?
   if(InpForceDir == FORCE_OFF)
   {
      Print("WARN [5] InpForceDir=OFF. EA will only trade if real signal wired in OnTick().");
      Print("       Fix: Set InpForceDir to FORCE_BUY/SELL for testing.");
   } else Print("PASS [5] Force direction: ", EnumToString(InpForceDir));

   // 6. Spread check — would entry be blocked right now?
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    spread = (int)MathRound((ask - bid) / point);
   if(InpCheckSpread && spread > InpMaxSpreadPts)
   {
      Print("WARN [6] Current spread=", spread, " pts > InpMaxSpreadPts=",
            InpMaxSpreadPts, ". Entry blocked right now.");
      Print("       Fix: Increase InpMaxSpreadPts OR wait for tighter spread.");
   } else Print("PASS [6] Spread=", spread, " pts (max=", InpMaxSpreadPts, ")");

   // 7. Gap vs SL logic check
   if(InpGapPoints >= InpSLPoints)
   {
      Print("FAIL [7] Gap(", InpGapPoints, ") >= SL(", InpSLPoints,
            "). Math breaks down.");
      Print("       Fix: Gap must be strictly less than SL.");
      allOk = false;
   } else Print("PASS [7] Gap=", InpGapPoints, " < SL=", InpSLPoints);

   // 7b. Stake budget sanity check
   if(InpStakeCapOn)
   {
      if(InpStakeUSD <= 0 || InpStakeUsePct <= 0)
      {
         Print("FAIL [7b] Stake control invalid. InpStakeUSD and InpStakeUsePct must be > 0.");
         allOk = false;
      }
      else
      {
         double budget = InpStakeUSD * (InpStakeUsePct / 100.0);
         Print("PASS [7b] Stake budget active: $", DoubleToString(budget, 2));
      }
   }
   else Print("INFO [7b] Stake budget control: OFF");

   // 8. Account margin — can we afford the trade?
   double marginRequired = 0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, InpLot1, ask, marginRequired))
      Print("WARN [8] Cannot calculate margin for this symbol.");
   else
   {
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      double lot2margin = 0;
      double lot2 = NormalizeLot(InpLot1 * InpLotMultiplier);
      OrderCalcMargin(ORDER_TYPE_SELL, _Symbol, lot2, bid, lot2margin);
      double totalMargin = marginRequired + lot2margin;
      if(freeMargin < totalMargin)
      {
         Print("FAIL [8] Free margin $", DoubleToString(freeMargin, 2),
               " < required $", DoubleToString(totalMargin, 2));
         Print("       Fix: Reduce InpLot1 or deposit more funds.");
         allOk = false;
      }
      else
         Print("PASS [8] Margin OK. Free=$", DoubleToString(freeMargin, 2),
               " Required=$", DoubleToString(totalMargin, 2));
   }

   // 9. Is there already an open position or pending from this EA?
   int  openPos  = CountMyPositions();
   bool pending  = PendingStrikeExists();
   Print("INFO [9] Open positions (magic ", InpMagic, "): ", openPos,
         " | Pending: ", pending);
   if(openPos > 0 || pending)
      Print("       EA won't open new trade until current cycle finishes.");

   // 10. Cooldown check
   if(g_cycleComplete)
   {
      datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
      int barsPassed = Bars(_Symbol, PERIOD_CURRENT, g_lastCycleBar, currentBar);
      Print("INFO [10] Cooldown: ", barsPassed, "/", InpCooldownBars,
            " bars passed since last cycle.");
      if(barsPassed < InpCooldownBars)
         Print("       EA is in cooldown. Will trade after ",
               InpCooldownBars - barsPassed, " more bar(s).");
   } else Print("PASS [10] No cooldown active.");

   Print(allOk ? "====== ALL CHECKS PASSED — EA READY ======" 
               : "====== ISSUES FOUND — SEE ABOVE ======");
}

//+------------------------------------------------------------------+
int OnInit()
{
   ENUM_ORDER_TYPE_FILLING fillMode = GetFillingMode();
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(fillMode);

   Print("=== HedgeStrike EA v4.0 ===");
   Print("Filling mode : ", EnumToString(fillMode));
   Print("Lot step     : ", SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP));
   Print("Min lot      : ", SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
   Print("Almost-Hit   : ", InpAlmostHitOn ? "ON" : "OFF",
         " @ ", InpAlmostHitPct, "% of TP (", InpTPPoints*InpAlmostHitPct/100, " pts)");
   Print("Trail BE     : ", InpTrailBEOn ? "ON" : "OFF",
         " | Step $", InpTrailBEStep);
   Print("E2 EmergSL   : ", InpE2EmergSLPts > 0
         ? (string)InpE2EmergSLPts + " pts from Strike" : "OFF");
      Print("Stake Cap    : ", InpStakeCapOn ? "ON" : "OFF",
         " | Stake $", DoubleToString(InpStakeUSD, 2),
         " | Use ", DoubleToString(InpStakeUsePct, 1), "%");
      Print("Stake AutoFit: ", InpAutoFitLotToStake ? "ON" : "OFF");

   if(InpGapPoints >= InpSLPoints)
   {
      Alert("ERROR: Gap (", InpGapPoints, ") must be LESS than SL (", InpSLPoints, ")");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpLotMultiplier < 2.0)
      Print("WARNING: Multiplier < 2.0. Break-even not guaranteed. Recommend >= 2.0");

   double normLot2 = NormalizeLot(InpLot1 * InpLotMultiplier);
   Print("Lot1: ", InpLot1, " | Lot2 (normalized): ", normLot2);

   PrintMath();
   RunSelfTest();   // <-- diagnoses ALL reasons a trade won't fire
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick()
{
   int    positions    = CountMyPositions();
   bool   pendingExists = PendingStrikeExists();
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   //--- GHOST GUARD: E1 was closed by broker TP/manual while Strike pending
   //    (positions==0 && pendingExists was an unhandled dead-zone in v3.0)
   //    Action: delete the dangling Strike and mark cycle complete.
   if(positions == 0 && pendingExists)
   {
      Print("Ghost Guard | E1 closed externally (broker TP or manual) — deleting dangling Strike.");
      CloseAll(); // only pending orders remain at this point
      MarkCycleComplete();
      return;
   }

   //--- PHASE 0: Entry signal
   if(positions == 0 && !pendingExists)
   {
      // Reset per-cycle state
      g_almostHitDone = false;
      g_trailBEPeak   = -DBL_MAX;

      // Wait InpRetrySeconds after last cycle closed before re-entering
      if(InpRetrySeconds > 0)
      {
         datetime now = TimeCurrent();
         int elapsed = (int)(now - g_lastEntryTime);
         if(elapsed < InpRetrySeconds)
         {
            // Log countdown every 5 seconds so user can see it waiting
            static datetime lastLog = 0;
            if((int)(now - lastLog) >= 5)
            {
               Print("Waiting to re-enter... ", InpRetrySeconds - elapsed, "s remaining");
               lastLog = now;
            }
            return;
         }
      }
      g_cycleComplete = false;

      bool doBuy  = false;
      bool doSell = false;

      // Force mode (testing / demo)
      if(InpForceDir == FORCE_BUY)          doBuy  = true;
      else if(InpForceDir == FORCE_SELL)    doSell = true;
      else if(InpForceDir == FORCE_ALTERNATE)
      {
         if(g_lastWasBuy) doSell = true;
         else             doBuy  = true;
      }

      // ── Plug your real signal here ──────────────────────────
      // if(InpForceDir == FORCE_OFF)
      // {
      //    doBuy  = (myBuffer[0] == 1.0);
      //    doSell = (myBuffer[0] == -1.0);
      // }
      // ────────────────────────────────────────────────────────

      if(doBuy || doSell)
      {
         if(!SpreadIsOk()) return;
         if(doBuy)  { g_lastWasBuy = true;  OpenCycle(ORDER_TYPE_BUY,  ask, bid, point, digits); }
         if(doSell) { g_lastWasBuy = false; OpenCycle(ORDER_TYPE_SELL, ask, bid, point, digits); }
      }
      return;
   }

   //--- PHASE 1: Entry 1 open, Strike still pending
   if(positions == 1 && pendingExists)
   {
      CheckAlmostHit(); // v3.0 FIX 2
      double netProfit    = GetBasketProfit(); // v3.0 FIX 1
      double phase1Lot = InpLot1;
      for(int i = PositionsTotal()-1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         phase1Lot = PositionGetDouble(POSITION_VOLUME);
         break;
      }

      double tp1ProfitEst = InpTPPoints * phase1Lot
                          * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE)
                          / SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE)
                          * point;

      if(netProfit >= tp1ProfitEst + InpPhase1MinWin)
      {
         Print("Phase 1 TP | Net $", DoubleToString(netProfit, 2));
         CloseAll();
         MarkCycleComplete();
      }
      return;
   }

   //--- PHASE 2: Both positions open — hedge active (Scenario C territory)
   if(positions >= 2)
   {
      double netProfit  = GetBasketProfit(); // v3.0 FIX 1
      double exitFloor  = GetTrailingExitFloor(); // v3.0 FIX 3

      if(netProfit >= exitFloor)
      {
         Print("Phase 2 Exit | Net $", DoubleToString(netProfit, 2),
               " >= Floor $", DoubleToString(exitFloor, 2));
         CloseAll();
         MarkCycleComplete();
         return;
      }
   }

   //--- Edge case: broker closed one leg via SL/TP, clean up the other
   if(positions == 1 && !pendingExists)
   {
      double netProfit = GetBasketProfit();
      if(netProfit >= InpPhase1MinWin)
      {
         Print("Cleanup | Net $", DoubleToString(netProfit, 2));
         CloseAll();
         MarkCycleComplete();
      }
   }
}

//+------------------------------------------------------------------+
void OpenCycle(ENUM_ORDER_TYPE dir, double ask, double bid,
               double point, int digits)
{
   g_phase1Dir     = dir;
   g_lastEntryTime = TimeCurrent(); // stamp time so retry gate resets
   double lot1 = NormalizeLot(InpLot1);

   // Auto-fit lot to stake budget if enabled
   double fittedLot1 = FitLot1ToStake(dir, lot1, ask, bid);
   if(fittedLot1 <= 0)
   {
      Print("STAKE BLOCKED — even minimum lot cannot fit the current budget/free-margin.");
      return;
   }

   if(fittedLot1 < lot1)
      Print("Stake Fit | Lot1 adjusted ", DoubleToString(lot1, 2),
            " -> ", DoubleToString(fittedLot1, 2),
            " to respect budget $", DoubleToString(InpStakeUSD * (InpStakeUsePct / 100.0), 2));

   lot1 = fittedLot1;
   double lot2 = NormalizeLot(lot1 * InpLotMultiplier);

   if(!StakeBudgetOk(dir, lot1, lot2, ask, bid))
      return;

   double tp1, sl1, strikePrice;

   // Optional emergency SL on E2: protects against runaway loss if EA
   // is disconnected while Phase 2 is active (Scenario C going wrong way).
   // Placed InpE2EmergSLPts from E2 entry in the losing direction.
   // Set InpE2EmergSLPts = 0 to disable (EA manages exit via basket profit).
   double e2sl     = 0;
   double e2tp     = 0; // E2 TP is always 0 — basket logic handles the exit

   if(dir == ORDER_TYPE_BUY)
   {
      double entry = ask;
      tp1         = NormalizeDouble(entry + InpTPPoints  * point, digits);
      sl1         = NormalizeDouble(entry - InpSLPoints  * point, digits);
      strikePrice = NormalizeDouble(entry - InpGapPoints * point, digits);

      // E2 is a SellStop: emergency SL is ABOVE strikePrice (BUY direction = further loss)
      if(InpE2EmergSLPts > 0)
         e2sl = NormalizeDouble(strikePrice + InpE2EmergSLPts * point, digits);

      Print("BUY cycle | E:", entry, " TP:", tp1, " SL:", sl1,
         " Strike@:", strikePrice, " Lot1:", lot1, " Lot2:", lot2,
            InpE2EmergSLPts > 0 ? StringFormat(" E2-SL:%.5f", e2sl) : " E2-SL:OFF");

      if(!trade.Buy(lot1, _Symbol, entry, sl1, tp1, "E1-BUY"))
      {
         Print("E1 BUY failed: ", trade.ResultRetcodeDescription(),
               " [", trade.ResultRetcode(), "]");
         return;
      }
      if(!trade.SellStop(lot2, strikePrice, _Symbol, e2sl, e2tp,
                         ORDER_TIME_GTC, 0, "Strike-SELL"))
         Print("Strike SELL failed: ", trade.ResultRetcodeDescription(),
               " [", trade.ResultRetcode(), "]");
   }
   else
   {
      double entry = bid;
      tp1         = NormalizeDouble(entry - InpTPPoints  * point, digits);
      sl1         = NormalizeDouble(entry + InpSLPoints  * point, digits);
      strikePrice = NormalizeDouble(entry + InpGapPoints * point, digits);

      // E2 is a BuyStop: emergency SL is BELOW strikePrice (SELL direction = further loss)
      if(InpE2EmergSLPts > 0)
         e2sl = NormalizeDouble(strikePrice - InpE2EmergSLPts * point, digits);

      Print("SELL cycle | E:", entry, " TP:", tp1, " SL:", sl1,
         " Strike@:", strikePrice, " Lot1:", lot1, " Lot2:", lot2,
            InpE2EmergSLPts > 0 ? StringFormat(" E2-SL:%.5f", e2sl) : " E2-SL:OFF");

      if(!trade.Sell(lot1, _Symbol, entry, sl1, tp1, "E1-SELL"))
      {
         Print("E1 SELL failed: ", trade.ResultRetcodeDescription(),
               " [", trade.ResultRetcode(), "]");
         return;
      }
      if(!trade.BuyStop(lot2, strikePrice, _Symbol, e2sl, e2tp,
                        ORDER_TIME_GTC, 0, "Strike-BUY"))
         Print("Strike BUY failed: ", trade.ResultRetcodeDescription(),
               " [", trade.ResultRetcode(), "]");
   }
}

//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(PositionSelectByTicket(PositionGetTicket(i)))
         if(PositionGetInteger(POSITION_MAGIC) == InpMagic) count++;
   return count;
}

//+------------------------------------------------------------------+
bool PendingStrikeExists()
{
   for(int i = OrdersTotal()-1; i >= 0; i--)
      if(OrderSelect(OrderGetTicket(i)))
         if(OrderGetInteger(ORDER_MAGIC) == InpMagic) return true;
   return false;
}

//+------------------------------------------------------------------+
void CloseAll()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
         if(PositionGetInteger(POSITION_MAGIC) == InpMagic)
            if(!trade.PositionClose(ticket))
               Print("Close failed #", ticket, ": ", trade.ResultRetcodeDescription());
   }
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
         if(OrderGetInteger(ORDER_MAGIC) == InpMagic)
            if(!trade.OrderDelete(ticket))
               Print("Delete pending #", ticket, ": ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void MarkCycleComplete()
{
   g_cycleComplete = true;
   g_lastCycleBar  = iTime(_Symbol, PERIOD_CURRENT, 0);
   g_lastEntryTime = TimeCurrent(); // 30-sec wait starts NOW (when cycle closes)
   g_almostHitDone = false;
   g_trailBEPeak   = -DBL_MAX;
   Print("Cycle closed. Next entry in ", InpRetrySeconds, " seconds.");
}

//+------------------------------------------------------------------+
void PrintMath()
{
   double lot2  = NormalizeLot(InpLot1 * InpLotMultiplier);
   double tick  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tsize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pt    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pv    = tick / tsize * pt;
   long   spPts = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   Print("--- MATH PROOF (after commission) ---");
   Print("Lot1:", InpLot1, "  Lot2:", lot2, "  x", InpLotMultiplier);
   Print("Spread: ", spPts, "pts | Effective gap: ", InpGapPoints-(int)spPts, "pts");
   Print("Scenario A  (TP, no strike):     NET $",
         DoubleToString(InpTPPoints * InpLot1 * pv, 2));
   Print("Scenario B  (strike + SL):       E1=$",
         DoubleToString(-InpSLPoints * InpLot1 * pv, 2),
         " E2=$", DoubleToString((InpSLPoints-InpGapPoints)*lot2*pv, 2),
         " NET=$", DoubleToString((-InpSLPoints*InpLot1+(InpSLPoints-InpGapPoints)*lot2)*pv,2));
   Print("Scenario C  (strike+reversal):   EA trails exit — peak-$",
         InpTrailBEStep, " floor, min $", InpPhase2MinWin);
   Print("Almost-Hit  (", InpAlmostHitPct, "% = ",
         InpTPPoints*InpAlmostHitPct/100, " pts): SL->BE, Strike deleted");
   Print("-------------------------------------");
}
//+------------------------------------------------------------------+
