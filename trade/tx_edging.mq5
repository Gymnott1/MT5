//+------------------------------------------------------------------+
//|                              HedgeStrike_EA_v12.mq5              |
//|          Smart Pre-Trade Math Engine + Hedge Recovery            |
//|                                                                   |
//|  BEFORE every entry, EA scans ±50 pips and pre-calculates:      |
//|   • E1 P&L at every 5-pip level                                  |
//|   • Required E2 lot if hedge fires at each loss level            |
//|   • Break-even + profit recovery distance after hedge            |
//|   • Net $ per pip after hedge is open                            |
//|   • Margin viability check for each scenario                     |
//|                                                                   |
//|  ENTRY is skipped if math fails (lot cap or margin breach).      |
//|                                                                   |
//|  EXECUTION RULES:                                                 |
//|   1. E1 opens only after scan approves entry.                    |
//|   2. E2 lot is pre-calculated at entry, placed on loss trigger.  |
//|   3. Basket exits at profit target / trail stop.                 |
//+------------------------------------------------------------------+

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

input group "== STAKE =="
input double InpStakeUSD           = 10.0;  // Stake USD — lot sizes auto-derive

input group "== ENTRY =="
input int    InpMagic              = 11111;
input int    InpSlippage           = 20;
input bool   InpSingleCycleOnly    = false; // false = re-enter automatically
input bool   InpRequireViable      = true;  // Skip entry if pre-trade math fails

input group "== SMART MATH ENGINE =="
input int    InpScanRadius         = 50;    // ± pip scan radius before entry
input int    InpHedgeTriggerPips   = 30;    // Pips adverse before E2 (hedge) opens
input int    InpE2RecoveryPips     = 20;    // Pips for E2 to recover the loss
input double InpMaxE2Multiplier    = 2.5;   // Safety cap: E2 lot <= E1 * this

input group "== EXIT =="
input double InpProfitTargetUSD    = 0.30;  // Full profit target per cycle (basis for SL and TP %)
input int    InpSLIntroducePct     = 10;    // Introduce break-even SL when E1 profit >= X% of target
input int    InpTPAtPct            = 50;    // Hard close E1 when solo profit >= X% of target
input double InpBasketTargetUSD    = 0.15;  // Hedged basket absolute profit target to close
input double InpHedgeProfitLockUSD = 0.15;  // Basket profit trail activates at this absolute level
input double InpHedgeTrailBackUSD  = 0.07;  // Close if basket profit pulls back by this from peak

input group "== CIRCUIT BREAKER =="
input double InpMaxLossUSD         = 1.0;   // Hard close all if loss exceeds this

input group "== SPREAD GUARD =="
input bool   InpCheckSpread        = true;
input int    InpMaxSpreadPts       = 100;

input group "== PANEL =="
input int    InpPanelX             = 18;
input int    InpPanelY             = 50;
input color  InpColorProfit        = clrLimeGreen;
input color  InpColorLoss          = clrTomato;
input color  InpColorNeutral       = clrSilver;
input color  InpColorAlert         = clrGold;
input color  InpColorHedge         = clrDodgerBlue;

input group "== SIGNAL =="
enum ENUM_FORCE_DIR {FORCE_OFF=0, FORCE_BUY=1, FORCE_SELL=2, FORCE_ALTERNATE=3};
input ENUM_FORCE_DIR InpForceDir        = FORCE_ALTERNATE; // Alternate BUY/SELL each cycle
input int    InpRetrySeconds            = 30;  // Wait after PROFIT close before next cycle
input int    InpPauseLossSeconds        = 120; // Wait after LOSS/CB close (longer cooldown)
input int    InpMaxConsecLosses         = 3;   // Pause all trading after N losses in a row
input bool   InpStopAfterMaxConsecLosses= true; // Lock new entries when max loss streak is reached
input int    InpLossLockMinutes         = 240;  // Lock duration after max consecutive losses
input int    InpMaxRecoveryPipsEntry    = 30;   // Block entry if pre-calc recovery pips exceed this

//──────────────────────────────────────────────────────────────────
// PRE-TRADE SCAN LEVEL STRUCT
//──────────────────────────────────────────────────────────────────
struct ScanLevel {
   int    pivotPips;     // pips from entry (negative = adverse)
   double price;         // absolute price at this pip
   double e1Pnl;         // E1 P&L at this price
   bool   isHedgeTrig;   // is this the hedge trigger band?
   double e2Lot;         // E2 lot needed if hedge fires here
   double netPerPip;     // basket net $/pip after hedge
   double recovPips;     // pips needed to recover loss after hedge
   double marginNeeded;  // margin $ required for E2
   bool   viable;        // true = margin is available
};

//──────────────────────────────────────────────────────────────────
// GLOBAL STATE
//──────────────────────────────────────────────────────────────────
CTrade   trade;
bool     g_lastWasBuy       = false;
datetime g_lastEntryTime    = 0;
bool     g_hasOpenedOnce    = false;
bool     g_cycleActive      = false;
bool     g_hedgeOpen        = false;
ulong    g_e1Ticket         = 0;
ulong    g_e2Ticket         = 0;
double   g_e1Entry          = 0;
double   g_lot1             = 0.01;
double   g_lot2             = 0.02;
double   g_triggerUSD       = 1.0;
double   g_soloTPUSD        = 0.15;  // InpProfitTargetUSD * InpTPAtPct / 100
bool     g_slIntroduced     = false; // true once break-even SL is placed on E1
double   g_peakSoloPnL      = 0.0;   // peak solo P&L this cycle for trailing SL
double   g_hedgeOpenPnL     = 0.0;
double   g_hedgePeakPnL     = -1e9;
ENUM_POSITION_TYPE g_e1Dir  = POSITION_TYPE_BUY;

// pre-trade scan results (max 21 levels at step=5 over ±50 pips)
ScanLevel g_scan[21];
int       g_scanSize        = 0;
bool      g_scanViable      = false;
double    g_preCalcE2Lot    = 0;
double    g_preCalcNetPP    = 0;
double    g_preCalcRecovPips= 0;

// Cycle performance tracking
int      g_cycleCount        = 0;
int      g_profitCycles      = 0;
int      g_lossCycles        = 0;
double   g_totalNetPnL       = 0;
double   g_lastCyclePnL      = 0;
int      g_consecLosses      = 0;
bool     g_lastCycleWasLoss  = false;
datetime g_pauseUntil        = 0;  // don't enter before this time
double   g_lastBasketPnL     = 0;  // last known basket P&L (updated every tick)
datetime g_lockUntil         = 0;  // hard lock for new entries after loss streak

string PFX = "HSv12_";

//──────────────────────────────────────────────────────────────────
// UTILITY
//──────────────────────────────────────────────────────────────────
ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   switch((ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_EXEMODE)) {
      case SYMBOL_TRADE_EXECUTION_REQUEST:
      case SYMBOL_TRADE_EXECUTION_INSTANT: return ORDER_FILLING_FOK;
      case SYMBOL_TRADE_EXECUTION_MARKET:  return ORDER_FILLING_IOC;
      default:                             return ORDER_FILLING_RETURN;
   }
}

double NormalizeLot(double lot)
{
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   lot=MathFloor(lot/st)*st;
   lot=MathMax(lot,mn); lot=MathMin(lot,mx);
   int dec=(int)MathRound(-MathLog10(st));
   return NormalizeDouble(lot, MathMax(dec,2));
}

// USD per pip for given lot
double PipValForLot(double lot)
{
   double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tsz =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double pt  =SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   return (tsz>0) ? (tick/tsz)*pt*lot : 0;
}

double GetPipValue() { return PipValForLot(0.01); }

bool IsHedgingAccount()
{
   return (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

bool SpreadOk()
{
   if(!InpCheckSpread) return true;
   double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   int sp=(int)MathRound((SymbolInfoDouble(_Symbol,SYMBOL_ASK)-
                          SymbolInfoDouble(_Symbol,SYMBOL_BID))/pt);
   if(sp>InpMaxSpreadPts){ Print("Spread blocked: ",sp," pts"); return false; }
   return true;
}

bool HasMargin(ENUM_ORDER_TYPE dir, double lot, double price)
{
   double req=0;
   if(!OrderCalcMargin(dir,_Symbol,lot,price,req)) return false;
   if(req>AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   { Print("MARGIN BLOCKED $",DoubleToString(req,2)); return false; }
   return true;
}

int CountMyPositions()
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(PositionSelectByTicket(PositionGetTicket(i)))
         if(PositionGetInteger(POSITION_MAGIC)==InpMagic) n++;
   return n;
}

double GetBasketPnL()
{
   double t=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(PositionSelectByTicket(PositionGetTicket(i)))
         if(PositionGetInteger(POSITION_MAGIC)==InpMagic)
            t += PositionGetDouble(POSITION_PROFIT)
               + PositionGetDouble(POSITION_SWAP)
               + PositionGetDouble(POSITION_COMMISSION);
   return t;
}

void CloseAll()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==InpMagic)
         trade.PositionClose(t);
   }
}

void MarkCycleComplete(string reason, double closedPnL)
{
   double finalPnL = closedPnL;
   bool   isLoss   = (finalPnL < -0.01); // anything worse than -1 cent counts as a loss

   // Update cycle statistics
   g_cycleCount++;
   g_lastCyclePnL   = finalPnL;
   g_totalNetPnL   += finalPnL;
   if(isLoss) { g_lossCycles++;  g_consecLosses++; g_lastCycleWasLoss=true;  }
   else       { g_profitCycles++; g_consecLosses=0; g_lastCycleWasLoss=false; }

   // Set re-entry pause based on outcome
   int pauseSec = isLoss ? InpPauseLossSeconds : InpRetrySeconds;
   // Extra pause for consecutive losses
   if(g_consecLosses >= InpMaxConsecLosses)
   {
      pauseSec = InpPauseLossSeconds * g_consecLosses; // grows with each consecutive loss
      Print("CONSEC LOSS GUARD: ",g_consecLosses," losses — pausing ",pauseSec,"s");

      if(InpStopAfterMaxConsecLosses)
      {
         int lockSec = MathMax(InpLossLockMinutes, 1) * 60;
         g_lockUntil = TimeCurrent() + lockSec;
         Print("TRADING LOCK: max consecutive losses reached (",g_consecLosses,")",
               " — locked for ",lockSec,"s");
      }
   }
   g_pauseUntil = TimeCurrent() + pauseSec;

   Print("=== DONE: ",reason,
         " | P&L: $",DoubleToString(finalPnL,2),
         " | Cycle #",g_cycleCount,
         " | W:",g_profitCycles," L:",g_lossCycles,
         " | Net: $",DoubleToString(g_totalNetPnL,2),
         " | Next entry in ",pauseSec,"s ===");

   g_cycleActive=false; g_hedgeOpen=false;
   g_e1Ticket=0; g_e2Ticket=0; g_e1Entry=0;
   g_hedgeOpenPnL=0; g_hedgePeakPnL=-1e9;
   g_preCalcE2Lot=0; g_preCalcNetPP=0; g_preCalcRecovPips=0;
   g_scanSize=0; g_scanViable=false;
   g_slIntroduced=false; g_peakSoloPnL=0;
   g_lastEntryTime=TimeCurrent();
   ObjectsDeleteAll(0, PFX+"hl");
}

//──────────────────────────────────────────────────────────────────
// LOT CALCULATORS
//──────────────────────────────────────────────────────────────────
// E1 lot: sized so InpHedgeTriggerPips of adverse = ~5% of stake
double CalcE1Lot()
{
   double pvBase = GetPipValue(); // per 0.01 lot
   if(pvBase <= 0) return NormalizeLot(0.01);
   double riskUSD = InpStakeUSD * 0.05;
   riskUSD = MathMax(riskUSD, 0.30);
   double lot = riskUSD / (pvBase * InpHedgeTriggerPips / 0.01);
   return NormalizeLot(lot);
}

// E2 lot: sized to recover lossAbs in targetPips of movement
// Formula: e2 = e1 + lossAbs * 0.01 / (targetPips * pvBase)
double CalcE2LotFor(double lossAbs, double targetPips, double e1Lot)
{
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(targetPips <= 0 || lossAbs <= 0)
      return NormalizeLot(e1Lot + lotStep);

   double pvBase = GetPipValue();
   if(pvBase <= 0) return NormalizeLot(e1Lot + lotStep);

   double extra = lossAbs * 0.01 / (targetPips * pvBase);
   double l2    = e1Lot + extra;
   l2 *= 1.05; // 5% overshoot so basket lands in profit, not just breakeven

   // Safety cap: never more than E1 * multiplier
   double maxL2 = e1Lot * MathMax(InpMaxE2Multiplier, 1.1);
   if(l2 > maxL2) l2 = maxL2;

   double result = NormalizeLot(l2);
   if(result <= e1Lot) result = NormalizeLot(e1Lot + lotStep);
   return result;
}

//──────────────────────────────────────────────────────────────────
// PRE-TRADE SCAN ENGINE
// Builds g_scan[]: outcome at every 5-pip level from -radius to +radius
// Sets g_scanViable, g_preCalcE2Lot, g_preCalcNetPP, g_preCalcRecovPips
//──────────────────────────────────────────────────────────────────
void BuildScanMap(ENUM_ORDER_TYPE dir, double entryPrice, double e1Lot)
{
   g_scanSize        = 0;
   g_scanViable      = true;
   g_preCalcE2Lot    = 0;
   g_preCalcNetPP    = 0;
   g_preCalcRecovPips= 0;

   double pt          = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pvBase      = GetPipValue();
   double pvPerLot    = pvBase / 0.01;  // USD per pip per 1.0 lot
   double freeMargin  = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double triggerUSD  = e1Lot * pvPerLot * InpHedgeTriggerPips;

   ENUM_ORDER_TYPE e2Type  = (dir==ORDER_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   double          e2Price = (e2Type==ORDER_TYPE_SELL)
                              ? SymbolInfoDouble(_Symbol,SYMBOL_BID)
                              : SymbolInfoDouble(_Symbol,SYMBOL_ASK);

   for(int pip = -InpScanRadius; pip <= InpScanRadius; pip += 5)
   {
      if(g_scanSize >= 21) break;
      ScanLevel lvl;
      lvl.pivotPips = pip;

      // "positive pip" = direction of profit for this trade
      //  BUY:  price rises  → profit (pip > 0 = up)
      //  SELL: price falls  → profit (pip > 0 = down in absolute terms)
      if(dir == ORDER_TYPE_BUY)
         lvl.price = entryPrice + pip * pt;
      else
         lvl.price = entryPrice - pip * pt;

      // E1 P&L: pip * pvPerLot * e1Lot
      lvl.e1Pnl = pip * pvBase * (e1Lot / 0.01);

      // Hedge trigger band: within ±5% around triggerUSD loss
      lvl.isHedgeTrig = (lvl.e1Pnl <= -triggerUSD * 0.90 &&
                         lvl.e1Pnl >= -triggerUSD * 1.10);

      if(lvl.e1Pnl < 0)
      {
         lvl.e2Lot    = CalcE2LotFor(MathAbs(lvl.e1Pnl), InpE2RecoveryPips, e1Lot);
         lvl.netPerPip= PipValForLot(lvl.e2Lot) - PipValForLot(e1Lot);
         lvl.recovPips= (lvl.netPerPip > 0) ? MathAbs(lvl.e1Pnl) / lvl.netPerPip : 9999;

         // Margin check
         double req = 0;
         OrderCalcMargin(e2Type, _Symbol, lvl.e2Lot, e2Price, req);
         lvl.marginNeeded = req;
         lvl.viable       = (req <= 0 || req < freeMargin * 0.95); // only block if truly no margin
      }
      else
      {
         lvl.e2Lot         = 0;
         lvl.netPerPip     = 0;
         lvl.recovPips     = 0;
         lvl.marginNeeded  = 0;
         lvl.viable        = true;
      }

      g_scan[g_scanSize++] = lvl;

      // Capture data at hedge trigger level
      if(lvl.isHedgeTrig)
      {
         if(!lvl.viable) g_scanViable = false;
         if(g_preCalcE2Lot <= e1Lot)
         {
            g_preCalcE2Lot     = lvl.e2Lot;
            g_preCalcNetPP     = lvl.netPerPip;
            g_preCalcRecovPips = lvl.recovPips;
         }
      }
   }

   // Fallback: if trigger band not found (very tight trigger), pick first adverse level
   if(g_preCalcE2Lot <= e1Lot)
   {
      for(int i = 0; i < g_scanSize; i++)
      {
         if(g_scan[i].e1Pnl < -triggerUSD * 0.5 && g_scan[i].e2Lot > e1Lot)
         {
            g_preCalcE2Lot     = g_scan[i].e2Lot;
            g_preCalcNetPP     = g_scan[i].netPerPip;
            g_preCalcRecovPips = g_scan[i].recovPips;
            if(!g_scan[i].viable) g_scanViable = false;
            break;
         }
      }
   }

   // Final safety: E2 must be above E1
   if(g_preCalcE2Lot <= e1Lot)
   {
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      g_preCalcE2Lot    = NormalizeLot(e1Lot + lotStep);
      g_preCalcNetPP    = PipValForLot(g_preCalcE2Lot) - PipValForLot(e1Lot);
      g_preCalcRecovPips= (g_preCalcNetPP > 0) ? triggerUSD / g_preCalcNetPP : 9999;
   }
}

void PrintOutcomeMap(ENUM_ORDER_TYPE dir)
{
   int    digits = (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   string ds     = (dir==ORDER_TYPE_BUY) ? "BUY" : "SELL";
   double ep     = (dir==ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                                         : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   Print("=== PRE-TRADE MAP [",ds," @ ",DoubleToString(ep,digits),
         " | Scan ±",InpScanRadius,"p | Trigger ",InpHedgeTriggerPips,"p] ===");
   Print("  Pip   E1 P&L    E2 Lot  Net/pip  Recov  Viable");
   Print("  ───   ──────    ──────  ───────  ─────  ──────");
   for(int i = g_scanSize-1; i >= 0; i--)
   {
      ScanLevel lvl = g_scan[i];
      string marker = lvl.isHedgeTrig ? "  ◀HEDGE TRIGGER" : "";
      if(!lvl.viable && lvl.e2Lot > 0) marker += " !MARGIN";
      Print(StringFormat("  %+4d   $%+6.2f  %5s   $%+6.3f  %4s  %s%s",
         lvl.pivotPips,
         lvl.e1Pnl,
         (lvl.e2Lot > 0 ? DoubleToString(lvl.e2Lot,2) : "  -  "),
         (lvl.netPerPip != 0 ? lvl.netPerPip : 0),
         (lvl.recovPips > 0 && lvl.recovPips < 9999 ? DoubleToString(lvl.recovPips,0)+"p" : "  -"),
         (lvl.viable ? "OK" : "NO"),
         marker));
   }
   Print("  Pre-calc E2: ",DoubleToString(g_preCalcE2Lot,2),
         " lot | Net/pip: $+",DoubleToString(g_preCalcNetPP,3),
         " | Recovery: ~",DoubleToString(g_preCalcRecovPips,0)," pips",
         " | Entry: ",(g_scanViable?"APPROVED":"BLOCKED"));
}

//──────────────────────────────────────────────────────────────────
// TRADE CYCLE LOGIC
//──────────────────────────────────────────────────────────────────
void CheckHedgeTrigger()
{
   if(g_hedgeOpen) return;
   double pnl = GetBasketPnL();
   if(pnl > -g_triggerUSD) return;   // not yet at trigger
   if(!SpreadOk()) return;

   double bid    = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double lossAbs= MathAbs(pnl);

   // Use pre-calculated lot (set at entry time) — otherwise compute live
   double lot2 = (g_preCalcE2Lot > g_lot1)
                  ? g_preCalcE2Lot
                  : CalcE2LotFor(lossAbs, InpE2RecoveryPips, g_lot1);

   // Safety: lot2 must be strictly larger than lot1
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lot2 <= g_lot1) lot2 = NormalizeLot(g_lot1 + lotStep);

   ENUM_ORDER_TYPE e2Type  = (g_e1Dir==POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   double          e2Price = (e2Type==ORDER_TYPE_SELL) ? bid : ask;

   if(!HasMargin(e2Type, lot2, e2Price)) return;

   double netPP      = PipValForLot(lot2) - PipValForLot(g_lot1);
   // pips from hedge-open to the basket exit target (not pips to break-even)
   double exitPips   = (netPP > 0) ? (InpBasketTargetUSD - pnl) / netPP : 9999;

   Print("=== HEDGE TRIGGER ===");
   Print("  Loss: $",DoubleToString(lossAbs,2),
         " | E2 lot: ",DoubleToString(lot2,2),
         " (pre-calc was ",DoubleToString(g_preCalcE2Lot,2),")");
   Print("  Net/pip: +$",DoubleToString(netPP,3),
         " | Pips to exit target: ~",DoubleToString(exitPips,0)," pips");

   // Calculate TP price for E2: the price at which basket reaches +InpBasketTargetUSD
   // basket improves when price moves in E2's direction
   // pips needed = (InpBasketTargetUSD - pnl) / netPP
   double e2TpPips = (netPP > 0) ? (InpBasketTargetUSD - pnl) / netPP : 0;
   double pt3      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    dig3     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double e2Tp     = (e2TpPips > 0)
                     ? ((e2Type==ORDER_TYPE_SELL)
                        ? NormalizeDouble(e2Price - e2TpPips * pt3, dig3)
                        : NormalizeDouble(e2Price + e2TpPips * pt3, dig3))
                     : 0;

   bool ok = (e2Type==ORDER_TYPE_SELL)
              ? trade.Sell(lot2,_Symbol,e2Price,0,e2Tp,"HSv12-E2-HEDGE")
              : trade.Buy (lot2,_Symbol,e2Price,0,e2Tp,"HSv12-E2-HEDGE");

   if(ok)
   {
      g_lot2         = lot2;
      g_hedgeOpen    = true;
      g_hedgeOpenPnL = pnl;
      g_hedgePeakPnL = pnl;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong t=PositionGetTicket(i);
         if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==InpMagic&&t!=g_e1Ticket)
         { g_e2Ticket=t; break; }
      }
      Alert("HSv12 | HEDGE OPEN | E2 ",DoubleToString(lot2,2)," lot"
            " | Net/pip +$",DoubleToString(netPP,3),
            " | ~",DoubleToString(exitPips,0)," pips to exit ($+",DoubleToString(InpBasketTargetUSD,2),")");
   }
   else
      Print("E2 FAILED: ",trade.ResultRetcodeDescription());
}

void CheckBasketExit()
{
   if(!g_hedgeOpen) return; // basket exit only applies in hedged phase
   double pnl = GetBasketPnL();
   // Exit when basket reaches an absolute positive profit target
   // e.g. hedge opened at -$0.30, target=$0.15 → close when basket >= +$0.15
   // Needs ~45 pips at $0.010/pip: 30 to recover E1 loss + 15 for profit
   double exitTarget = InpBasketTargetUSD;
   if(pnl >= exitTarget)
   {
      Print("BASKET EXIT | $",DoubleToString(pnl,2),
            " >= $+",DoubleToString(exitTarget,2),
            " target (hedge opened at $",DoubleToString(g_hedgeOpenPnL,2),")");
      double capPnL = pnl;   // capture BEFORE CloseAll
      CloseAll();
      MarkCycleComplete("Basket profit target", capPnL);
   }
}

void CheckHedgeProtection()
{
   if(!g_hedgeOpen) return;
   double pnl = GetBasketPnL();
   if(pnl > g_hedgePeakPnL) g_hedgePeakPnL = pnl;

   // Profit trail: once basket reaches positive InpHedgeProfitLockUSD profit, trail it
   double lockLevel = InpHedgeProfitLockUSD;
   if(g_hedgePeakPnL >= lockLevel)
   {
      if(pnl <= g_hedgePeakPnL - InpHedgeTrailBackUSD)
      {
         Print("PROFIT LOCK | Peak $",DoubleToString(g_hedgePeakPnL,2),
               " → now $",DoubleToString(pnl,2));
         double capPnL = pnl;   // capture BEFORE CloseAll
         CloseAll();
         MarkCycleComplete("Hedge profit lock", capPnL);
         return;
      }
   }

   // Post-hedge drift cap: cut if basket goes InpBasketTargetUSD*0.7 BELOW hedge-open level
   // e.g. target=$0.15, cap=$0.105 → win=15 pips, lose=~10 pips → favorable 1.5:1 ratio
   double allowedExtra = InpBasketTargetUSD * 0.70;
   if(pnl <= g_hedgeOpenPnL - allowedExtra)
   {
      Print("POST-HEDGE CAP | Opened $",DoubleToString(g_hedgeOpenPnL,2),
            " cap -$",DoubleToString(allowedExtra,2),
            " → now $",DoubleToString(pnl,2));
      double capPnL = pnl;   // capture BEFORE CloseAll
      CloseAll();
      MarkCycleComplete("Post-hedge loss cap", capPnL);
   }
}

void CheckE1ProfitManagement()
{
   if(g_hedgeOpen) return;
   double pnl    = GetBasketPnL();
   if(pnl <= 0)  return;  // only act when in profit

   double slTrig = InpProfitTargetUSD * InpSLIntroducePct / 100.0;
   double tpTrig = InpProfitTargetUSD * InpTPAtPct        / 100.0;

   if(pnl > g_peakSoloPnL) g_peakSoloPnL = pnl;

   // ── SCENARIO 1: Hard TP at X% of profit target (default 50%) ─────────────
   if(pnl >= tpTrig)
   {
      Print("E1 PROFIT TP | $",DoubleToString(pnl,2),
            " >= $",DoubleToString(tpTrig,2),
            " (",InpTPAtPct,"% of $",DoubleToString(InpProfitTargetUSD,2)," target)");
      double capPnL = pnl;
      CloseAll();
      MarkCycleComplete("E1 profit TP", capPnL);
      return;
   }

   // ── SCENARIO 1: Introduce / trail break-even SL at X% of target ──────────
   if(pnl >= slTrig && g_e1Ticket != 0 && PositionSelectByTicket(g_e1Ticket))
   {
      double pt    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int    dig   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double pvPip = PipValForLot(g_lot1);     // USD per pip for E1 lot

      // SL locks in InpSLIntroducePct% of the current peak profit
      double lockUSD  = g_peakSoloPnL * InpSLIntroducePct / 100.0;
      double lockPips = (pvPip > 0) ? lockUSD / pvPip : 0;
      double newSL    = (g_e1Dir == POSITION_TYPE_BUY)
                        ? NormalizeDouble(g_e1Entry + lockPips * pt, dig)
                        : NormalizeDouble(g_e1Entry - lockPips * pt, dig);

      double curSL  = PositionGetDouble(POSITION_SL);
      bool improve  = (!g_slIntroduced) ||
                      (g_e1Dir == POSITION_TYPE_BUY  && newSL > curSL + pt) ||
                      (g_e1Dir == POSITION_TYPE_SELL && (curSL <= 0 || newSL < curSL - pt));

      if(improve && trade.PositionModify(g_e1Ticket, newSL, 0))
      {
         Print(g_slIntroduced ? "SL TRAILED" : "SL INTRODUCED",
               " @ ",DoubleToString(newSL,dig),
               " | locks $+",DoubleToString(lockUSD,3),
               " | peak $+",DoubleToString(g_peakSoloPnL,3));
         g_slIntroduced = true;
      }
   }
}

void CheckCircuitBreaker()
{
   double pnl = GetBasketPnL();
   if(pnl <= -InpMaxLossUSD)
   {
      Print("CIRCUIT BREAKER | $",DoubleToString(pnl,2));
      Alert("HSv12 | CIRCUIT BREAKER | Loss $",DoubleToString(MathAbs(pnl),2));
      double capPnL = pnl;   // capture BEFORE CloseAll
      CloseAll();
      MarkCycleComplete("Circuit breaker", capPnL);
   }
}

//──────────────────────────────────────────────────────────────────
// PANEL DRAWING HELPERS
//──────────────────────────────────────────────────────────────────
void DL(string n,string t,int x,int y,int sz,color c,bool b=false)
{
   string nm=PFX+n;
   if(ObjectFind(0,nm)<0) ObjectCreate(0,nm,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,nm,OBJPROP_CORNER,    CORNER_LEFT_UPPER);
   ObjectSetInteger(0,nm,OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0,nm,OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,   sz);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,      c);
   ObjectSetString(0, nm,OBJPROP_FONT,       b?"Arial Bold":"Arial");
   ObjectSetString(0, nm,OBJPROP_TEXT,       t);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE, false);
}

void DR(string n,int x,int y,int w,int h,color bg,color br)
{
   string nm=PFX+n;
   if(ObjectFind(0,nm)<0) ObjectCreate(0,nm,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,nm,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,nm,OBJPROP_XSIZE,w);     ObjectSetInteger(0,nm,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,nm,OBJPROP_BGCOLOR,bg);  ObjectSetInteger(0,nm,OBJPROP_BORDER_COLOR,br);
   ObjectSetInteger(0,nm,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
}

void DH(string n,double p,color c,ENUM_LINE_STYLE s,string tip)
{
   string nm=PFX+n;
   if(ObjectFind(0,nm)<0) ObjectCreate(0,nm,OBJ_HLINE,0,0,p);
   ObjectSetDouble(0,nm,OBJPROP_PRICE,p);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,c);
   ObjectSetInteger(0,nm,OBJPROP_STYLE,s);
   ObjectSetInteger(0,nm,OBJPROP_WIDTH,1);
   ObjectSetString(0,nm,OBJPROP_TOOLTIP,tip);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
}

void DeletePanel() { ObjectsDeleteAll(0,PFX); }

//──────────────────────────────────────────────────────────────────
// PANEL — Scan map when idle; live basket when active
//──────────────────────────────────────────────────────────────────
void UpdatePanel()
{
   int px=InpPanelX, py=InpPanelY, pw=315, lh=16, pad=8;
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   // Clear stale labels when switching between idle and active mode
   static bool s_wasActive = false;
   if(s_wasActive != g_cycleActive) { ObjectsDeleteAll(0,PFX); s_wasActive=g_cycleActive; }

   //— IDLE: show pre-trade scan map —
   if(!g_cycleActive)
   {
      int rows   = 5 + g_scanSize + 3; // +2 for pause-title + stats lines
      int totalH = pad + rows*lh + pad;
      if(totalH < 100) totalH = 100;

      DR("bg",px,py,pw,totalH,C'10,10,22',
         g_scanViable ? C'30,80,30' : C'80,30,30');
      int y=py+pad;

      // Pause countdown
      if(TimeCurrent() < g_lockUntil)
      {
         int sl = (int)(g_lockUntil - TimeCurrent());
         DL("ptitle","HedgeStrike v12  |  TRADING LOCKED — next in "+string(sl)+"s",
            px+pad,y,9,InpColorLoss,true); y+=lh;
      }
      else if(TimeCurrent() < g_pauseUntil)
      {
         int sl = (int)(g_pauseUntil - TimeCurrent());
         string pauseReason = g_lastCycleWasLoss ? "LOSS cooldown" : "Profit wait";
         DL("ptitle","HedgeStrike v12  |  "+pauseReason+" — next in "+string(sl)+"s",
            px+pad,y,9,g_lastCycleWasLoss?InpColorLoss:InpColorAlert,true); y+=lh;
      }
      else
      {
         DL("ptitle","HedgeStrike v12  |  PRE-TRADE MATH ENGINE",
            px+pad,y,9,InpColorNeutral,true); y+=lh;
      }
      // Cycle stats line
      DL("stats","Cycles: "+string(g_cycleCount)
               +"  W:"+string(g_profitCycles)+" L:"+string(g_lossCycles)
               +"  Net: $"+(g_totalNetPnL>=0?"+":"")+DoubleToString(g_totalNetPnL,2)
               +"  ConsecL:"+string(g_consecLosses),
         px+pad,y,7,g_totalNetPnL>=0?InpColorProfit:InpColorLoss); y+=lh;
      DL("sub1","Scan ±"+string(InpScanRadius)+"p | Hedge@"+string(InpHedgeTriggerPips)
               +"p | Rcov"+string(InpE2RecoveryPips)+"p | Cap x"+DoubleToString(InpMaxE2Multiplier,1),
         px+pad,y,7,C'70,70,100'); y+=lh;
      DL("sub2","  Pips   E1 P&L   E2Lot  Net/pip  Recov",
         px+pad,y,7,C'100,100,130'); y+=lh;

      for(int i=g_scanSize-1;i>=0;i--)
      {
         ScanLevel lvl=g_scan[i];
         color tc = (lvl.e1Pnl > 0)     ? InpColorProfit
                  : lvl.isHedgeTrig      ? InpColorAlert
                  : !lvl.viable          ? InpColorLoss
                                         : InpColorNeutral;
         string e2s  = (lvl.e2Lot > 0)                  ? DoubleToString(lvl.e2Lot,2) : "  -- ";
         string nps  = (lvl.netPerPip != 0)              ? StringFormat("%+.3f",lvl.netPerPip) : "  -- ";
         string rcs  = (lvl.recovPips > 0 && lvl.recovPips < 9999)
                        ? DoubleToString(lvl.recovPips,0)+"p" : " -- ";
         string trig = lvl.isHedgeTrig  ? " ◀HEDGE" : "";
         string mrg  = (!lvl.viable && lvl.e2Lot>0) ? "!MRG" : "";
         string row  = StringFormat(" %+4dp  $%+6.2f  %s  $%s  %5s%s%s",
            lvl.pivotPips, lvl.e1Pnl, e2s, nps, rcs, trig, mrg);
         DL("sc"+string(i),row,px+pad,y,7,tc);
         y+=lh;
      }
      y+=2;
      string vstr = g_scanViable
                    ? "ENTRY APPROVED — math viable"
                    : "ENTRY BLOCKED — check margin / lot cap";
      DL("viable",vstr,px+pad,y,8,g_scanViable?InpColorProfit:InpColorLoss,true); y+=lh;
      DL("pcalc","Pre-calc E2: "+DoubleToString(g_preCalcE2Lot,2)
                +"  Net/pip: $+"+DoubleToString(g_preCalcNetPP,3)
                +"  ~"+DoubleToString(g_preCalcRecovPips,0)+"p to profit",
         px+pad,y,7,InpColorAlert); y+=lh;
      ChartRedraw();
      return;
   }

   //— ACTIVE CYCLE —
   double pnl   = GetBasketPnL();
   double equity= AccountInfoDouble(ACCOUNT_EQUITY);
   double freeM = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   string dirStr= (g_e1Dir==POSITION_TYPE_BUY) ? "BUY" : "SELL";
   int    npos  = CountMyPositions();
   double netPP   = g_hedgeOpen ? (PipValForLot(g_lot2)-PipValForLot(g_lot1)) : 0;
   double lossA   = MathAbs(MathMin(pnl,0));
   // Pips to reach exit = distance from current pnl to (hedge-open + target)
   double exitTgt = InpBasketTargetUSD;
   double recP    = (netPP>0 && g_hedgeOpen && pnl < exitTgt)
                    ? (exitTgt - pnl) / netPP : 0;

   int rows   = g_hedgeOpen ? 18 : 17;
   int totalH = pad + rows*lh + pad;
   color bdr  = !g_hedgeOpen
                 ? (pnl>=0 ? C'25,85,45' : C'60,35,25')
                 : C'25,50,95';
   DR("bg",px,py,pw,totalH,C'13,15,24',bdr);
   int y=py+pad;

   DL("title","HedgeStrike v12  |  "+dirStr+"  |  "+string(npos)+" pos",
      px+pad,y,9,InpColorNeutral,true); y+=lh;
   DL("stats","Cycle #"+string(g_cycleCount+1)
             +"  |  W:"+string(g_profitCycles)+" L:"+string(g_lossCycles)
             +"  Net: $"+(g_totalNetPnL>=0?"+":"")+DoubleToString(g_totalNetPnL,2),
      px+pad,y,7,g_totalNetPnL>=0?InpColorProfit:InpColorLoss); y+=lh;
   string phase = !g_hedgeOpen
                  ? "Phase 1 — E1 live | waiting for hedge trigger"
                  : "Phase 2 — HEDGED | recovering to profit";
   DL("phase",phase,px+pad,y,8,g_hedgeOpen?InpColorHedge:InpColorNeutral,g_hedgeOpen); y+=lh+2;

   DL("eq","Equity: $"+DoubleToString(equity,2)
          +"  Free: $"+DoubleToString(freeM,2),px+pad,y,8,InpColorNeutral); y+=lh;

   color pc = (pnl>=0) ? InpColorProfit : InpColorLoss;
   DL("pnl","Basket P&L:  $"+(pnl>=0?"+":"")+DoubleToString(pnl,2),
      px+pad,y,10,pc,true); y+=lh;

   if(!g_hedgeOpen)
   {
      DL("e1i","E1: "+DoubleToString(g_lot1,2)
               +" lot @ "+DoubleToString(g_e1Entry,digits),
         px+pad,y,8,InpColorNeutral); y+=lh;
      // Break-even distance and recovery scenario
      double pvPip1   = PipValForLot(g_lot1);
      double bePips   = (pvPip1 > 0 && pnl < 0) ? MathAbs(pnl) / pvPip1 : 0;
      double tpTrigUSD= InpProfitTargetUSD * InpTPAtPct / 100.0;
      double slTrigUSD= InpProfitTargetUSD * InpSLIntroducePct / 100.0;
      double tpPips   = (pvPip1 > 0) ? tpTrigUSD / pvPip1 : 0;

      // P&L colour: green=profit, gold=near trigger, red=past trigger
      color tc = (pnl > -g_triggerUSD*0.5) ? InpColorNeutral
               : (pnl > -g_triggerUSD)     ? InpColorAlert
               :                             InpColorLoss;

      if(pnl < 0)
         DL("bep",StringFormat("Break-even: %.0f pips back | Free $%.2f",
               bePips, AccountInfoDouble(ACCOUNT_MARGIN_FREE)),
            px+pad,y,8,tc); 
      else
      {
         string slStatus = g_slIntroduced
                           ? StringFormat("SL @ break-even+%.0f%% peak locked",
                                          (double)InpSLIntroducePct)
                           : StringFormat("SL fires at +$%.3f (%d%% of target)",
                                          slTrigUSD, InpSLIntroducePct);
         DL("bep",slStatus, px+pad,y,8,
            g_slIntroduced ? InpColorProfit : InpColorNeutral);
      }
      y+=lh;

      DL("trg",StringFormat("Hedge zone: -$%.2f (~%d pips)",
               g_triggerUSD, InpHedgeTriggerPips),
         px+pad,y,8,tc); y+=lh;
      DL("tp",StringFormat("TP: +$%.3f (%d%% of $%.2f target) = ~%.0f pips",
               tpTrigUSD, InpTPAtPct, InpProfitTargetUSD, tpPips),
         px+pad,y,8,(pnl>=tpTrigUSD*0.7)?InpColorProfit:InpColorNeutral); y+=lh;
      DL("cb","Circuit brk: -$"+DoubleToString(InpMaxLossUSD,2),
         px+pad,y,8,(pnl<=-InpMaxLossUSD*0.7)?InpColorLoss:InpColorNeutral); y+=lh;
      DL("pre","Recovery E2: "+DoubleToString(g_preCalcE2Lot,2)
               +" lot  |  Net/pip: +$"+DoubleToString(g_preCalcNetPP,3),
         px+pad,y,7,InpColorAlert); y+=lh;
      DL("rec",StringFormat("Recovery: ~%.0fp to basket $+%.2f after hedge",
               g_preCalcRecovPips, InpBasketTargetUSD),
         px+pad,y,7,(g_preCalcRecovPips>40)?InpColorLoss:InpColorNeutral); y+=lh;

      // Chart price lines
      if(g_e1Entry > 0)
      {
         double pt2    = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
         double trgPrc = (g_e1Dir==POSITION_TYPE_BUY)
                          ? g_e1Entry - InpHedgeTriggerPips*pt2
                          : g_e1Entry + InpHedgeTriggerPips*pt2;
         double tpPrc  = (g_e1Dir==POSITION_TYPE_BUY)
                          ? g_e1Entry + tpPips*pt2
                          : g_e1Entry - tpPips*pt2;
         DH("hle1",  g_e1Entry, InpColorNeutral, STYLE_SOLID,
            "E1 entry @ "+DoubleToString(g_e1Entry,digits));
         DH("hltrg", trgPrc, InpColorAlert, STYLE_DASH,
            "Hedge zone (-"+string(InpHedgeTriggerPips)+" pips)");
         DH("hltp",  tpPrc, InpColorProfit, STYLE_DASH,
            StringFormat("TP +$%.2f (%d%% target)", tpTrigUSD, InpTPAtPct));
      }
   }
   else
   {
      DL("e1i","E1: "+DoubleToString(g_lot1,2)
               +" @ "+DoubleToString(g_e1Entry,digits),
         px+pad,y,8,InpColorNeutral); y+=lh;
      DL("e2i","E2 (hedge): "+DoubleToString(g_lot2,2)+" lot",
         px+pad,y,8,InpColorHedge,true); y+=lh;
      DL("npp","Net/pip: +$"+DoubleToString(netPP,3)+" per pip",
         px+pad,y,8,InpColorProfit); y+=lh;
      DL("rec","To exit: ~"+DoubleToString(recP,0)+" pips",
         px+pad,y,8,(recP<10)?InpColorProfit:InpColorAlert); y+=lh;
      DL("tgt","Exit at: $+"+DoubleToString(InpBasketTargetUSD,2)
               +"  (opened $"+DoubleToString(g_hedgeOpenPnL,2)
               +" | ~"+DoubleToString(netPP>0?(MathAbs(g_hedgeOpenPnL)+InpBasketTargetUSD)/netPP:0,0)
               +"p total recovery)",
         px+pad,y,8,InpColorNeutral); y+=lh;
      string peakStr = (g_hedgePeakPnL > -1e8)
                        ? "$"+(g_hedgePeakPnL>=0?"+":"")+DoubleToString(g_hedgePeakPnL,2)
                        : "--";
      DL("peak","Peak P&L: "+peakStr
                +"  |  Lock at $+"+DoubleToString(InpHedgeProfitLockUSD,2),
         px+pad,y,8,InpColorNeutral); y+=lh;
      DL("cb","Circuit brk: -$"+DoubleToString(InpMaxLossUSD,2),
         px+pad,y,8,(pnl<=-InpMaxLossUSD*0.7)?InpColorLoss:InpColorNeutral); y+=lh;

      // Recovery progress bar
      string bar="Recovery [";
      int fill = (pnl >= 0) ? 20
                            : (int)MathMax(0,MathMin(20,
                                (int)(20*(1-lossA/MathMax(g_triggerUSD,0.01)))));
      for(int i=0;i<20;i++) bar+=(i<fill?"#":".");
      bar+="]";
      DL("prg",bar,px+pad,y,7,pnl>=0?InpColorProfit:InpColorNeutral); y+=lh;
   }
   ChartRedraw();
}

//──────────────────────────────────────────────────────────────────
// OPEN CYCLE — pre-trade math gate then entry
//──────────────────────────────────────────────────────────────────
void OpenCycle(ENUM_ORDER_TYPE dir)
{
   if(!SpreadOk()) return;

   if(TimeCurrent() < g_lockUntil)
   {
      int rem = (int)(g_lockUntil - TimeCurrent());
      Print("ENTRY BLOCKED: trading lock active for ",rem,"s");
      return;
   }

   double ask  = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid  = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double entry= (dir==ORDER_TYPE_BUY) ? ask : bid;

   g_lot1 = CalcE1Lot();

   // ── PRE-TRADE MATH SCAN ──────────────────────────────────
   BuildScanMap(dir, entry, g_lot1);
   PrintOutcomeMap(dir);

   if(InpRequireViable && !g_scanViable)
   {
      Print("ENTRY SKIPPED: pre-trade math not viable",
            " | Free: $",DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE),2));
      UpdatePanel();
      return;
   }

   if(InpMaxRecoveryPipsEntry > 0 && g_preCalcRecovPips > InpMaxRecoveryPipsEntry)
   {
      Print("ENTRY SKIPPED: recovery too far (",
            DoubleToString(g_preCalcRecovPips,0),"p > ",InpMaxRecoveryPipsEntry,
            "p)",
            " | Pre-calc E2: ",DoubleToString(g_preCalcE2Lot,2),
            " | Net/pip: $+",DoubleToString(g_preCalcNetPP,3));
      UpdatePanel();
      return;
   }
   // ─────────────────────────────────────────────────────────

   if(!HasMargin(dir, g_lot1, entry)) return;

   bool ok = (dir==ORDER_TYPE_BUY)
              ? trade.Buy (g_lot1,_Symbol,entry,0,0,"HSv12-E1-BUY")
              : trade.Sell(g_lot1,_Symbol,entry,0,0,"HSv12-E1-SELL");
   if(!ok){ Print("E1 FAILED: ",trade.ResultRetcodeDescription()); return; }

   // Store E1 ticket
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==InpMagic)
      { g_e1Ticket=t; break; }
   }

   g_cycleActive   = true;
   g_hedgeOpen     = false;
   g_hasOpenedOnce = true;
   g_lastWasBuy    = (dir==ORDER_TYPE_BUY);
   g_e1Dir         = (dir==ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   g_e1Entry       = entry;
   g_triggerUSD    = g_lot1 * GetPipValue() / 0.01 * InpHedgeTriggerPips;
   g_soloTPUSD     = InpProfitTargetUSD * InpTPAtPct / 100.0;
   g_slIntroduced  = false;
   g_peakSoloPnL   = 0;
   g_lot2          = 0;
   g_lastEntryTime = TimeCurrent();

   Print("E1 OPEN | ",(dir==ORDER_TYPE_BUY?"BUY":"SELL"),
         " ",DoubleToString(g_lot1,2),
         " @ ",DoubleToString(entry,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS)),
         " | Hedge @-$",DoubleToString(g_triggerUSD,2),
         " | Pre-calc E2: ",DoubleToString(g_preCalcE2Lot,2),
         " | Est recov: ",DoubleToString(g_preCalcRecovPips,0),"p");
}

//──────────────────────────────────────────────────────────────────
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(GetFillingMode());

   if(!IsHedgingAccount())
   {
      Print("INIT FAILED: Account must be HEDGING mode (not netting/exchange).");
      return INIT_FAILED;
   }

   g_lot1       = CalcE1Lot();
   g_triggerUSD = g_lot1 * GetPipValue() / 0.01 * InpHedgeTriggerPips;
   g_soloTPUSD  = InpProfitTargetUSD * InpTPAtPct / 100.0;

   Print("=== HedgeStrike v12 — Smart Math Engine ===");
   Print("  Stake $",DoubleToString(InpStakeUSD,2),
         " | E1 lot ",DoubleToString(g_lot1,2),
         " | Trigger ",InpHedgeTriggerPips,"p ($",DoubleToString(g_triggerUSD,2),
         ") | CB -$",DoubleToString(InpMaxLossUSD,2));

   // Rebuild state if EA restarts with open positions
   int nPos=0, nBuy=0, nSell=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      nPos++;
      ENUM_POSITION_TYPE pt2=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(pt2==POSITION_TYPE_BUY) {
         nBuy++;
         if(g_e1Ticket==0){ g_e1Ticket=t; g_e1Entry=PositionGetDouble(POSITION_PRICE_OPEN);
                             g_e1Dir=POSITION_TYPE_BUY; g_lot1=PositionGetDouble(POSITION_VOLUME); }
      }
      if(pt2==POSITION_TYPE_SELL) {
         nSell++;
         if(nBuy==0&&g_e1Ticket==0){ g_e1Ticket=t; g_e1Entry=PositionGetDouble(POSITION_PRICE_OPEN);
                                      g_e1Dir=POSITION_TYPE_SELL; g_lot1=PositionGetDouble(POSITION_VOLUME); }
      }
   }

   if(nPos > 0)
   {
      g_cycleActive = true;
      g_hedgeOpen   = (nPos >= 2);
      g_triggerUSD  = g_lot1 * GetPipValue() / 0.01 * InpHedgeTriggerPips;
      g_soloTPUSD   = InpProfitTargetUSD * InpTPAtPct / 100.0;
      if(g_hedgeOpen)
      {
         for(int i=PositionsTotal()-1;i>=0;i--)
         {
            ulong t=PositionGetTicket(i);
            if(!PositionSelectByTicket(t)||PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
            if(t!=g_e1Ticket){ g_e2Ticket=t; g_lot2=PositionGetDouble(POSITION_VOLUME); break; }
         }
         g_preCalcNetPP = PipValForLot(g_lot2) - PipValForLot(g_lot1);
         Print("RECOVERY: hedge open. E1=",DoubleToString(g_lot1,2),
               " E2=",DoubleToString(g_lot2,2),
               " Net/pip=$",DoubleToString(g_preCalcNetPP,3));
      }
      else
         Print("RECOVERY: E1 only. P&L=$",DoubleToString(GetBasketPnL(),2),
               " trigger=-$",DoubleToString(g_triggerUSD,2));
   }
   else
   {
      // Pre-run scan for idle panel display
      double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      BuildScanMap(ORDER_TYPE_BUY, ask, g_lot1);
   }

   UpdatePanel();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason){ DeletePanel(); }

void OnTick()
{
   int positions = CountMyPositions();

   if(positions == 0)
   {
      if(g_cycleActive) MarkCycleComplete("All positions closed", g_lastBasketPnL);
      if(InpSingleCycleOnly && g_hasOpenedOnce){ UpdatePanel(); return; }

      if(TimeCurrent() < g_lockUntil)
      {
         static datetime s_lastLockPanelUpdate = 0;
         if(TimeCurrent() - s_lastLockPanelUpdate >= 5)
         {
            s_lastLockPanelUpdate = TimeCurrent();
            bool willBuyL = (InpForceDir==FORCE_BUY) ||
                            (InpForceDir==FORCE_ALTERNATE && !g_lastWasBuy);
            ENUM_ORDER_TYPE sdL = willBuyL ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
            double spL = (sdL==ORDER_TYPE_BUY)
                         ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                         : SymbolInfoDouble(_Symbol,SYMBOL_BID);
            BuildScanMap(sdL, spL, CalcE1Lot());
            UpdatePanel();
         }
         return;
      }

      // Respect dynamic pause (profit = short wait, loss = long cooldown)
      if(TimeCurrent() < g_pauseUntil)
      {
         // Only update panel every 5 seconds during pause to avoid floods
         static datetime s_lastPanelUpdate = 0;
         if(TimeCurrent() - s_lastPanelUpdate >= 5)
         {
            s_lastPanelUpdate = TimeCurrent();
            // Run scan so panel shows APPROVED/BLOCKED correctly during cooldown
            bool willBuy2 = (InpForceDir==FORCE_BUY) ||
                            (InpForceDir==FORCE_ALTERNATE && !g_lastWasBuy);
            ENUM_ORDER_TYPE sd2 = willBuy2 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
            double sp2 = (sd2==ORDER_TYPE_BUY)
                          ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                          : SymbolInfoDouble(_Symbol,SYMBOL_BID);
            BuildScanMap(sd2, sp2, CalcE1Lot());
            UpdatePanel();
         }
         return;
      }

      bool doBuy=false, doSell=false;
      if     (InpForceDir==FORCE_BUY)       doBuy=true;
      else if(InpForceDir==FORCE_SELL)      doSell=true;
      else if(InpForceDir==FORCE_ALTERNATE) { if(g_lastWasBuy) doSell=true; else doBuy=true; }
      // Custom signal hook:
      // if(InpForceDir==FORCE_OFF){ doBuy=(buf[0]==1.0); doSell=(buf[0]==-1.0); }

      // Refresh scan map for panel display even before opening
      if(!g_cycleActive)
      {
         ENUM_ORDER_TYPE scanDir = (doSell) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         double scanPrice = (scanDir==ORDER_TYPE_BUY)
                             ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                             : SymbolInfoDouble(_Symbol,SYMBOL_BID);
         BuildScanMap(scanDir, scanPrice, CalcE1Lot());
      }

      if(doBuy)  OpenCycle(ORDER_TYPE_BUY);
      if(doSell) OpenCycle(ORDER_TYPE_SELL);
      UpdatePanel();
      return;
   }

   // State recovery if EA reloaded with open positions
   if(!g_cycleActive || g_e1Ticket==0)
   {
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong t=PositionGetTicket(i);
         if(!PositionSelectByTicket(t)||PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
         if(g_e1Ticket==0)
         {
            g_e1Ticket   = t;
            g_e1Entry    = PositionGetDouble(POSITION_PRICE_OPEN);
            g_e1Dir      = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            g_lot1       = PositionGetDouble(POSITION_VOLUME);
            g_cycleActive= true;
            g_triggerUSD = g_lot1 * GetPipValue() / 0.01 * InpHedgeTriggerPips;
            g_soloTPUSD  = InpProfitTargetUSD * InpTPAtPct / 100.0;
         }
      }
      if(positions >= 2) g_hedgeOpen = true;
   }

   g_cycleActive = true;
   g_lastBasketPnL = GetBasketPnL(); // keep snapshot for external-close detection
   CheckHedgeTrigger();       // open E2 when loss hits trigger
   CheckBasketExit();         // close hedged basket at profit target
   CheckHedgeProtection();    // trail stop + post-hedge drift cap
   CheckCircuitBreaker();          // hard stop
   CheckE1ProfitManagement();      // SL introduction + TP at 50% of target
   UpdatePanel();
}

void OnChartEvent(const int id,const long &lp,const double &dp,const string &sp)
{ if(id==CHARTEVENT_CHART_CHANGE) UpdatePanel(); }
//+------------------------------------------------------------------+
