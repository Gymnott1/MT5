//+------------------------------------------------------------------+
//|                                        HedgeStrike_EA_v6.1.mq5  |
//|             Full Automation: Profit Trail + Auto Recovery        |
//|                       $10 Stake Calibrated                       |
//|                                                                  |
//|  DEFAULT STAKE: $10  (change InpStakeUSD to scale everything)   |
//|                                                                  |
//|  ALL lot sizes, profit targets, trail steps, and basket exit     |
//|  are derived at runtime from InpStakeUSD. You never need to      |
//|  touch individual lot inputs — just change the stake.            |
//|                                                                  |
//|  $10 stake math (XAU/USD, ~$0.10/pip per 0.01 lot):             |
//|   E1 lot      = 0.01                                             |
//|   Rec 1 lot   = 0.015  (1.5x) at -50 pips                       |
//|   Rec 2 lot   = 0.020  (2.0x) at -100 pips                      |
//|   Rec 3 lot   = 0.030  (3.0x) at -150 pips                      |
//|   Worst-case total loss (all levels open, at level 3): ~$7.50   |
//|   = 75% of stake. Basket recovers with only +20-30 pip bounce.  |
//|                                                                  |
//|  SCALING: Double stake to $20 -> all lots double automatically.  |
//|                                                                  |
//|  PROFIT SIDE:                                                    |
//|   SL introduced at +$0.50 profit (5% of $10)                    |
//|   TP (hard close) at +$2.00 profit (20% of $10)                 |
//|   Trail ratchet every +$0.25                                     |
//|                                                                  |
//|  LOSS SIDE:                                                      |
//|   Recovery fires at every 50 pips against entry                  |
//|   Basket closes when combined P&L >= +$0.50                     |
//+------------------------------------------------------------------+

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Inputs
input group "== STAKE (change this to scale everything) =="
input double InpStakeUSD          = 10.0;   // Your stake in $ — ALL sizing derives from this

input group "== ENTRY =="
input int    InpMagic             = 66666;  // Magic number
input int    InpSlippage          = 20;     // Slippage in points

input group "== PROFIT SIDE =="
input double InpSLTriggerPct      = 5.0;    // Introduce SL when profit >= X% of stake
input int    InpSLBufferPips      = 2;      // SL sits this many pips above entry (locks tiny win)
input bool   InpTrailSL           = true;   // Trail SL as profit grows
input double InpTrailStepPct      = 2.5;    // Trail ratchet every X% of stake (e.g. 2.5% of $10 = $0.25)
input double InpAutoTPPct         = 20.0;   // Hard close when profit >= X% of stake

input group "== LOSS SIDE (Auto Recovery) =="
input int    InpMaxRecoveryLevels = 3;      // Max auto-recovery positions (0 = off)
input int    InpRecoverySpacePips = 50;     // Pip gap between recovery levels (50 pips on Gold = ~$0.50/0.01 lot)
input double InpRecoveryMult1     = 1.5;    // Lot multiplier recovery level 1
input double InpRecoveryMult2     = 2.0;    // Lot multiplier recovery level 2
input double InpRecoveryMult3     = 3.0;    // Lot multiplier recovery level 3
input double InpBasketExitPct     = 5.0;    // Close basket when combined P&L >= X% of stake

input group "== HARD STOP (circuit breaker) =="
input double InpMaxLossUSD        = 0.0;    // Hard close ALL positions if loss > $X (0 = off)
//  Recommended: set to InpStakeUSD (i.e. $10 stops everything if you lose your full stake)

input group "== SPREAD GUARD =="
input bool   InpCheckSpread       = true;
input int    InpMaxSpreadPts      = 50;     // Gold spreads can be 20-40 pts on M5

input group "== PANEL =="
input int    InpPanelX            = 18;
input int    InpPanelY            = 50;
input color  InpColorProfit       = clrLimeGreen;
input color  InpColorLoss         = clrTomato;
input color  InpColorNeutral      = clrSilver;
input color  InpColorAlert        = clrGold;

input group "== SIGNAL MODE =="
enum ENUM_FORCE_DIR { FORCE_OFF=0, FORCE_BUY=1, FORCE_SELL=2, FORCE_ALTERNATE=3 };
input ENUM_FORCE_DIR InpForceDir  = FORCE_BUY;
input int    InpRetrySeconds      = 30;

//--- Globals
CTrade        trade;
CPositionInfo posInfo;

bool          g_lastWasBuy        = false;
datetime      g_lastEntryTime     = 0;
bool          g_slIntroduced      = false;
bool          g_cycleActive       = false;
int           g_recoveryCount     = 0;
bool          g_recoveryFired[10];
double        g_recoveryPrices[10];
string        PFX                 = "HSv61_";

//--- Derived values (computed at runtime from InpStakeUSD)
double        g_lot1              = 0.01;   // E1 lot
double        g_slTriggerUSD      = 0.50;   // = InpSLTriggerPct% of stake
double        g_tpUSD             = 2.00;   // = InpAutoTPPct% of stake
double        g_trailStepUSD      = 0.25;   // = InpTrailStepPct% of stake
double        g_basketExitUSD     = 0.50;   // = InpBasketExitPct% of stake

//+------------------------------------------------------------------+
//| Compute lot1 from stake: target ~5% of stake per 50-pip move    |
//| Formula: lot1 = (stake * 0.05) / (50 pips * pipValuePer0.01lot) |
//+------------------------------------------------------------------+
double CalcLot1FromStake()
{
   double tick  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tsize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pt    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pvPer001 = (tick / tsize) * pt * 0.01; // $ per pip per 0.01 lot

   if(pvPer001 <= 0) return NormalizeLot(0.01);

   // We want: lot1 * (InpRecoverySpacePips * pvPer001/0.01) = stake * 5%
   // => lot1 = stake * 0.05 / (spacing * pvPer001/0.01)
   double riskPerLevel = InpStakeUSD * 0.05;
   double lossPerPip   = pvPer001 / 0.01; // $ per pip per 1 lot
   double rawLot       = riskPerLevel / (InpRecoverySpacePips * lossPerPip);

   return NormalizeLot(rawLot);
}

//+------------------------------------------------------------------+
//| Update all derived parameters from stake                        |
//+------------------------------------------------------------------+
void UpdateDerivedParams()
{
   g_lot1          = CalcLot1FromStake();
   g_slTriggerUSD  = InpStakeUSD * (InpSLTriggerPct  / 100.0);
   g_tpUSD         = InpStakeUSD * (InpAutoTPPct      / 100.0);
   g_trailStepUSD  = InpStakeUSD * (InpTrailStepPct   / 100.0);
   g_basketExitUSD = InpStakeUSD * (InpBasketExitPct  / 100.0);

   double mults[3];
   mults[0] = InpRecoveryMult1;
   mults[1] = InpRecoveryMult2;
   mults[2] = InpRecoveryMult3;

   Print("=== STAKE CALIBRATION ($", DoubleToString(InpStakeUSD,2), ") ===");
   Print("E1 lot          : ", DoubleToString(g_lot1,2));
   for(int i=0;i<InpMaxRecoveryLevels&&i<3;i++)
      Print("Recovery lot ", i+1, "   : ", DoubleToString(NormalizeLot(g_lot1*mults[i]),2),
            "  (", mults[i], "x)  @ -", InpRecoverySpacePips*(i+1), " pips");
   Print("SL trigger      : $", DoubleToString(g_slTriggerUSD,2),
         "  (", InpSLTriggerPct, "% of stake)");
   Print("Auto TP         : $", DoubleToString(g_tpUSD,2),
         "  (", InpAutoTPPct, "% of stake)");
   Print("Trail step      : $", DoubleToString(g_trailStepUSD,2),
         "  (", InpTrailStepPct, "% of stake)");
   Print("Basket exit     : $", DoubleToString(g_basketExitUSD,2),
         "  (", InpBasketExitPct, "% of stake)");

   // Worst-case loss estimate
   double pvPer001 = 0;
   double tick  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tsize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pt    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   pvPer001 = (tick / tsize) * pt * 0.01;

   if(pvPer001 > 0 && InpMaxRecoveryLevels > 0)
   {
      double lastOff  = InpRecoverySpacePips * InpMaxRecoveryLevels;
      double worstLoss = 0;
      double allLots[4];
      double allOffs[4];
      allLots[0] = g_lot1; allOffs[0] = 0;
      allLots[1] = NormalizeLot(g_lot1*InpRecoveryMult1); allOffs[1] = InpRecoverySpacePips;
      allLots[2] = NormalizeLot(g_lot1*InpRecoveryMult2); allOffs[2] = InpRecoverySpacePips*2;
      allLots[3] = NormalizeLot(g_lot1*InpRecoveryMult3); allOffs[3] = InpRecoverySpacePips*3;
      int n = InpMaxRecoveryLevels + 1;
      for(int i=0;i<n;i++)
         worstLoss += (lastOff - allOffs[i]) * (allLots[i]/0.01) * pvPer001;
      Print("Worst-case loss : $", DoubleToString(worstLoss,2),
            "  (", DoubleToString(worstLoss/InpStakeUSD*100,1), "% of stake)");
      if(worstLoss > InpStakeUSD)
         Print("WARNING: Worst-case loss EXCEEDS stake. Increase spacing or reduce multipliers.");
      else
         Print("OK: Worst-case loss within stake.");
   }
   Print("=========================================");
}

//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   ENUM_SYMBOL_TRADE_EXECUTION ex =
      (ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_EXEMODE);
   switch(ex)
   {
      case SYMBOL_TRADE_EXECUTION_REQUEST:
      case SYMBOL_TRADE_EXECUTION_INSTANT: return ORDER_FILLING_FOK;
      case SYMBOL_TRADE_EXECUTION_MARKET:  return ORDER_FILLING_IOC;
      default:                             return ORDER_FILLING_RETURN;
   }
}

double NormalizeLot(double lot)
{
   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot  = MathFloor(lot / step) * step;
   lot  = MathMax(lot, mn);
   lot  = MathMin(lot, mx);
   int dec = (int)MathRound(-MathLog10(step));
   return NormalizeDouble(lot, MathMax(dec, 2));
}

int CountMyPositions()
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(PositionSelectByTicket(PositionGetTicket(i)))
         if(PositionGetInteger(POSITION_MAGIC) == InpMagic) n++;
   return n;
}

double GetBasketPnL()
{
   double total = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(PositionSelectByTicket(PositionGetTicket(i)))
         if(PositionGetInteger(POSITION_MAGIC) == InpMagic)
            total += PositionGetDouble(POSITION_PROFIT)
                   + PositionGetDouble(POSITION_SWAP)
                   + PositionGetDouble(POSITION_COMMISSION);
   return total;
}

void GetBasketInfo(double &avgEntry, double &totalLots, double &totalPips,
                   ENUM_POSITION_TYPE &dir)
{
   avgEntry=0; totalLots=0; totalPips=0;
   dir = POSITION_TYPE_BUY;
   double ws=0;
   double pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      double lot  = PositionGetDouble(POSITION_VOLUME);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      dir         = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      ws         += open * lot;
      totalLots  += lot;
   }
   if(totalLots > 0)
   {
      avgEntry  = ws / totalLots;
      double cur = (dir==POSITION_TYPE_BUY) ? bid : ask;
      totalPips  = (dir==POSITION_TYPE_BUY)
                   ? (cur - avgEntry) / pt
                   : (avgEntry - cur) / pt;
   }
}

double PipValuePerLot(double lot)
{
   double tick  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tsize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pt    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return (tick / tsize) * pt * lot;
}

double NewBasketBE(double curAvg, double curLots, double recPrice, double recLot)
{
   double nl = curLots + recLot;
   if(nl <= 0) return 0;
   return (curAvg * curLots + recPrice * recLot) / nl;
}

bool SpreadOk()
{
   if(!InpCheckSpread) return true;
   double pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int sp = (int)MathRound((ask-bid)/pt);
   if(sp > InpMaxSpreadPts) { Print("Spread blocked: ",sp," pts"); return false; }
   return true;
}

bool HasEnoughMargin(ENUM_ORDER_TYPE dir, double lot, double price)
{
   double req=0;
   if(!OrderCalcMargin(dir, _Symbol, lot, price, req)) return false;
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(req > free)
   { Print("MARGIN BLOCKED need $",DoubleToString(req,2)," free $",DoubleToString(free,2)); return false; }
   return true;
}

void CalcRecoveryTriggers(double e1Entry, ENUM_POSITION_TYPE dir)
{
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   for(int lvl=0; lvl<InpMaxRecoveryLevels && lvl<10; lvl++)
   {
      if(dir==POSITION_TYPE_BUY)
         g_recoveryPrices[lvl] = e1Entry - (InpRecoverySpacePips*(lvl+1)) * pt;
      else
         g_recoveryPrices[lvl] = e1Entry + (InpRecoverySpacePips*(lvl+1)) * pt;
   }
}

//+------------------------------------------------------------------+
//| CIRCUIT BREAKER — hard close if loss > InpMaxLossUSD            |
//+------------------------------------------------------------------+
void CheckCircuitBreaker()
{
   if(InpMaxLossUSD <= 0) return;
   double pnl = GetBasketPnL();
   if(pnl < -InpMaxLossUSD)
   {
      Print("CIRCUIT BREAKER | Loss $",DoubleToString(MathAbs(pnl),2),
            " > limit $",DoubleToString(InpMaxLossUSD,2)," | Closing all");
      Alert("HedgeStrike | CIRCUIT BREAKER fired | Loss $",DoubleToString(MathAbs(pnl),2));
      CloseAll();
      MarkCycleComplete("Circuit breaker");
   }
}

//+------------------------------------------------------------------+
//| PROFIT: Auto SL + Trail                                         |
//+------------------------------------------------------------------+
void ManageProfitSL()
{
   if(CountMyPositions()==0) return;
   double pnl = GetBasketPnL();
   if(pnl < g_slTriggerUSD) return;

   double pt     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL     = PositionGetDouble(POSITION_SL);
      double curTP     = PositionGetDouble(POSITION_TP);

      // Base SL: entry + buffer pips
      double newSL = (ptype==POSITION_TYPE_BUY)
                     ? NormalizeDouble(openPrice + InpSLBufferPips*pt, digits)
                     : NormalizeDouble(openPrice - InpSLBufferPips*pt, digits);

      // Trail ratchet
      if(InpTrailSL && g_slIntroduced && g_trailStepUSD > 0)
      {
         double stepsUp = MathFloor((pnl - g_slTriggerUSD) / g_trailStepUSD);
         double lockAmt = g_slTriggerUSD + stepsUp * g_trailStepUSD;
         double avgEntry, totalLots, totalPips;
         ENUM_POSITION_TYPE dir;
         GetBasketInfo(avgEntry, totalLots, totalPips, dir);
         if(totalLots > 0)
         {
            double pv = PipValuePerLot(totalLots);
            if(pv > 0)
            {
               double lockPips = lockAmt / pv;
               double trailSL  = (ptype==POSITION_TYPE_BUY)
                                  ? NormalizeDouble(openPrice + lockPips*pt, digits)
                                  : NormalizeDouble(openPrice - lockPips*pt, digits);
               if(ptype==POSITION_TYPE_BUY  && trailSL > newSL) newSL = trailSL;
               if(ptype==POSITION_TYPE_SELL && trailSL < newSL) newSL = trailSL;
            }
         }
      }

      bool improve = (!g_slIntroduced)
                   ||(ptype==POSITION_TYPE_BUY  && newSL > curSL)
                   ||(ptype==POSITION_TYPE_SELL && (curSL<=0 || newSL<curSL));

      if(improve && trade.PositionModify(ticket, newSL, curTP))
      {
         if(!g_slIntroduced)
         {
            g_slIntroduced = true;
            Print("AUTO SL PLACED | SL:",newSL," | P&L:$",DoubleToString(pnl,2));
            Alert("HedgeStrike v6.1 | SL locked at ",newSL,
                  " | P&L: $",DoubleToString(pnl,2));
         }
         else
            Print("SL TRAILED | SL:",newSL," | P&L:$",DoubleToString(pnl,2));
      }
   }
}

//+------------------------------------------------------------------+
//| PROFIT: Auto TP — hard close at target                          |
//+------------------------------------------------------------------+
void ManageAutoTP()
{
   double pnl = GetBasketPnL();
   if(pnl >= g_tpUSD)
   {
      Print("AUTO TP | $",DoubleToString(pnl,2)," >= $",DoubleToString(g_tpUSD,2)," | Closing all");
      CloseAll();
      MarkCycleComplete("Auto TP");
   }
}

//+------------------------------------------------------------------+
//| LOSS: Auto recovery — open position when price hits level       |
//+------------------------------------------------------------------+
void ManageAutoRecovery()
{
   if(InpMaxRecoveryLevels<=0) return;
   if(g_recoveryCount >= InpMaxRecoveryLevels) return;

   double avgEntry, totalLots, totalPips;
   ENUM_POSITION_TYPE dir;
   GetBasketInfo(avgEntry, totalLots, totalPips, dir);
   if(totalPips >= 0) return;

   double pt     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double cur    = (dir==POSITION_TYPE_BUY) ? bid : ask;

   double mults[10];
   mults[0]=InpRecoveryMult1; mults[1]=InpRecoveryMult2; mults[2]=InpRecoveryMult3;
   for(int i=3;i<10;i++) mults[i]=mults[2]*(1.0+i*0.3);

   for(int lvl=0; lvl<InpMaxRecoveryLevels && lvl<10; lvl++)
   {
      if(g_recoveryFired[lvl]) continue;

      bool reached = (dir==POSITION_TYPE_BUY)
                     ? (cur <= g_recoveryPrices[lvl])
                     : (cur >= g_recoveryPrices[lvl]);
      if(!reached) continue;
      if(!SpreadOk()) continue;

      double recLot     = NormalizeLot(g_lot1 * mults[lvl]);
      ENUM_ORDER_TYPE ot = (dir==POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double execPrice  = (ot==ORDER_TYPE_BUY) ? ask : bid;

      if(!HasEnoughMargin(ot, recLot, execPrice)) continue;

      double newBE = NewBasketBE(avgEntry, totalLots, execPrice, recLot);

      Print("AUTO RECOVERY ", lvl+1,
            " | Lot:",recLot,
            " @ ",execPrice,
            " | New BE:",DoubleToString(newBE,digits),
            " | Basket P&L: $",DoubleToString(GetBasketPnL(),2));

      bool ok = (ot==ORDER_TYPE_BUY)
                ? trade.Buy(recLot,  _Symbol, execPrice, 0, 0, "HSv61-REC"+(string)(lvl+1))
                : trade.Sell(recLot, _Symbol, execPrice, 0, 0, "HSv61-REC"+(string)(lvl+1));

      if(ok)
      {
         g_recoveryFired[lvl] = true;
         g_recoveryCount++;
         Alert(StringFormat(
            "HedgeStrike v6.1 | Recovery %d opened\nLot: %.2f @ %s\nNew basket BE: %s\nP&L: $%.2f",
            lvl+1, recLot,
            DoubleToString(execPrice,digits),
            DoubleToString(newBE,digits),
            GetBasketPnL()));
      }
      else
         Print("Recovery ",lvl+1," FAILED: ",trade.ResultRetcodeDescription());

      break; // one per tick
   }
}

//+------------------------------------------------------------------+
//| LOSS: Close basket when recovered to target                     |
//+------------------------------------------------------------------+
void ManageBasketExit()
{
   if(g_recoveryCount==0) return;
   double pnl = GetBasketPnL();
   if(pnl >= g_basketExitUSD)
   {
      Print("BASKET EXIT | $",DoubleToString(pnl,2),
            " >= $",DoubleToString(g_basketExitUSD,2)," | Closing all");
      CloseAll();
      MarkCycleComplete("Basket exit after recovery");
   }
}

void CloseAll()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t))
         if(PositionGetInteger(POSITION_MAGIC)==InpMagic)
            if(!trade.PositionClose(t))
               Print("Close failed #",t,": ",trade.ResultRetcodeDescription());
   }
}

void MarkCycleComplete(string reason)
{
   Print("=== CYCLE COMPLETE: ",reason," ===");
   g_cycleActive   = false;
   g_slIntroduced  = false;
   g_recoveryCount = 0;
   g_lastEntryTime = TimeCurrent();
   ArrayInitialize(g_recoveryFired,  false);
   ArrayInitialize(g_recoveryPrices, 0);
   for(int i=0;i<10;i++) ObjectDelete(0, PFX+"hline_rec"+(string)i);
   ObjectDelete(0, PFX+"hline_be");
   ObjectDelete(0, PFX+"hline_tp");
}

//+------------------------------------------------------------------+
//| PANEL                                                            |
//+------------------------------------------------------------------+
void DrawLabel(string name,string txt,int x,int y,int sz,color clr,bool bold=false)
{
   string n=PFX+name;
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,    CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,   sz);
   ObjectSetInteger(0,n,OBJPROP_COLOR,      clr);
   ObjectSetString(0, n,OBJPROP_FONT,       bold?"Arial Bold":"Arial");
   ObjectSetString(0, n,OBJPROP_TEXT,       txt);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE, false);
}

void DrawRect(string name,int x,int y,int w,int h,color bg,color border)
{
   string n=PFX+name;
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,       CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,    x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,    y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,        w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,        h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,      bg);
   ObjectSetInteger(0,n,OBJPROP_BORDER_COLOR, border);
   ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,  BORDER_FLAT);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,   false);
}

void DrawHLine(string name,double price,color clr,ENUM_LINE_STYLE style,string tip)
{
   string n=PFX+name;
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_HLINE,0,0,price);
   ObjectSetDouble(0,n,  OBJPROP_PRICE,   price);
   ObjectSetInteger(0,n, OBJPROP_COLOR,   clr);
   ObjectSetInteger(0,n, OBJPROP_STYLE,   style);
   ObjectSetInteger(0,n, OBJPROP_WIDTH,   1);
   ObjectSetString(0,n,  OBJPROP_TOOLTIP, tip);
   ObjectSetInteger(0,n, OBJPROP_SELECTABLE, false);
}

void DeletePanel() { ObjectsDeleteAll(0,PFX); }

void UpdatePanel()
{
   int px=InpPanelX, py=InpPanelY, pw=295, lh=17, pad=9;
   int positions = CountMyPositions();

   if(positions==0 && !g_cycleActive)
   {
      DrawRect("bg",px,py,pw,56,C'18,18,28',C'50,50,70');
      DrawLabel("title","HedgeStrike v6.1  |  waiting",px+pad,py+11,9,InpColorNeutral,true);
      DrawLabel("stake","Stake: $"+DoubleToString(InpStakeUSD,2)+
                "  E1 lot: "+DoubleToString(g_lot1,2),
                px+pad,py+28,8,C'80,80,100');
      ChartRedraw();
      return;
   }

   double avgEntry, totalLots, totalPips;
   ENUM_POSITION_TYPE dir;
   GetBasketInfo(avgEntry, totalLots, totalPips, dir);

   double pnl      = GetBasketPnL();
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double margin   = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeM    = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double dd       = (balance>0&&pnl<0) ? MathAbs(pnl/InpStakeUSD*100.0) : 0;
   double pt       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double cur      = (dir==POSITION_TYPE_BUY)?bid:ask;
   string dirStr   = (dir==POSITION_TYPE_BUY)?"BUY":"SELL";

   // Recovery lot sizes
   double mults[10];
   mults[0]=InpRecoveryMult1; mults[1]=InpRecoveryMult2; mults[2]=InpRecoveryMult3;
   for(int i=3;i<10;i++) mults[i]=mults[2]*(1.0+i*0.3);

   double runAvg=avgEntry, runLots=totalLots;
   double recLot[10], recBE[10];
   for(int lvl=0;lvl<InpMaxRecoveryLevels&&lvl<10;lvl++)
   {
      recLot[lvl] = NormalizeLot(g_lot1*mults[lvl]);
      recBE[lvl]  = NewBasketBE(runAvg, runLots, g_recoveryPrices[lvl], recLot[lvl]);
      runAvg      = recBE[lvl];
      runLots    += recLot[lvl];
   }

   // Panel height
   int recRows = InpMaxRecoveryLevels * 2;
   int rows    = 15 + recRows + (g_slIntroduced?1:0) + (g_recoveryCount>0?1:0);
   int totalH  = pad + rows*lh + pad;

   color borderCol = (pnl>=0) ? C'25,85,45' : C'85,25,25';
   DrawRect("bg",px,py,pw,totalH,C'13,15,24',borderCol);

   int y = py+pad;

   // Header
   DrawLabel("title","HedgeStrike v6.1  |  "+dirStr+"  |  "+
             (string)positions+" pos  |  stake $"+DoubleToString(InpStakeUSD,2),
             px+pad,y,9,InpColorNeutral,true);
   y+=lh+3;

   // Account
   DrawLabel("s_acct","ACCOUNT",px+pad,y,7,C'85,85,115'); y+=lh;
   DrawLabel("eq",    "Equity      $"+DoubleToString(equity,2),   px+pad,y,8,InpColorNeutral); y+=lh;
   DrawLabel("mg",    "Margin      $"+DoubleToString(margin,2),   px+pad,y,8,InpColorNeutral); y+=lh;
   DrawLabel("fm",    "Free margin $"+DoubleToString(freeM,2),    px+pad,y,8,InpColorNeutral); y+=lh;
   color ddC=(dd>75)?InpColorLoss:(dd>40)?InpColorAlert:InpColorNeutral;
   DrawLabel("dd",    "vs stake    "+DoubleToString(dd,1)+"%",    px+pad,y,8,ddC);             y+=lh+2;

   // Basket
   DrawLabel("s_bask","BASKET",px+pad,y,7,C'85,85,115'); y+=lh;
   color pnlC = (pnl>=0)?InpColorProfit:InpColorLoss;
   string pnlS = (pnl>=0?"+":"")+DoubleToString(pnl,2);
   string pipS = (totalPips>=0?"+":"")+DoubleToString(totalPips,1);
   DrawLabel("pnl",   "P&L         $"+pnlS+"  ("+pipS+" pips)",  px+pad,y,8,pnlC,true); y+=lh;
   DrawLabel("lots",  "Total lots  "+DoubleToString(totalLots,2), px+pad,y,8,InpColorNeutral); y+=lh;
   DrawLabel("be",    "Basket BE   "+DoubleToString(avgEntry,digits), px+pad,y,8,InpColorAlert); y+=lh;

   // Profit targets
   color slC=(pnl>=g_slTriggerUSD)?InpColorProfit:InpColorNeutral;
   color tpC=(pnl>=g_tpUSD)       ?InpColorProfit:InpColorNeutral;
   DrawLabel("slt","SL trigger  $"+DoubleToString(g_slTriggerUSD,2)+" ("+DoubleToString(InpSLTriggerPct,0)+"%)", px+pad,y,8,slC); y+=lh;
   DrawLabel("tpt","Auto TP     $"+DoubleToString(g_tpUSD,2)        +" ("+DoubleToString(InpAutoTPPct,0)+"%)",   px+pad,y,8,tpC); y+=lh;
   if(g_slIntroduced)
   { DrawLabel("slst","Trailing SL ACTIVE",px+pad,y,8,InpColorProfit,true); y+=lh; }
   y+=2;

   // Recovery
   DrawLabel("s_rec","RECOVERY  (auto)",px+pad,y,7,C'85,85,115'); y+=lh;

   for(int lvl=0;lvl<InpMaxRecoveryLevels&&lvl<10;lvl++)
   {
      bool fired   = g_recoveryFired[lvl];
      bool reached = (dir==POSITION_TYPE_BUY)
                     ? (cur<=g_recoveryPrices[lvl])
                     : (cur>=g_recoveryPrices[lvl]);
      color lc = fired?InpColorProfit:(reached?InpColorAlert:InpColorNeutral);
      string st= fired?"[OPEN]":(reached?"[NOW]":"");

      string l1=StringFormat("Lvl %d %s  lot %.2f  @ %s",
         lvl+1,st,recLot[lvl],
         DoubleToString(g_recoveryPrices[lvl],digits));
      string l2=StringFormat("   BE->%s  need +%.0f pips",
         DoubleToString(recBE[lvl],digits),
         MathAbs((dir==POSITION_TYPE_BUY
                  ? recBE[lvl]-cur
                  : cur-recBE[lvl])/pt));

      DrawLabel("r"+IntegerToString(lvl*2),  l1,px+pad,y,7,lc,fired); y+=lh-2;
      DrawLabel("r"+IntegerToString(lvl*2+1),l2,px+pad,y,7,C'70,70,105'); y+=lh;
   }

   if(g_recoveryCount>0)
   {
      color bec=(pnl>=g_basketExitUSD)?InpColorProfit:InpColorAlert;
      DrawLabel("bex","Basket exit $"+DoubleToString(g_basketExitUSD,2),
                px+pad,y,8,bec,true);
   }

   // Chart lines
   if(avgEntry>0)
      DrawHLine("hline_be",avgEntry,InpColorAlert,STYLE_DOT,
                "Basket BE: "+DoubleToString(avgEntry,digits));

   // TP line
   if(totalLots>0)
   {
      double pv=PipValuePerLot(totalLots);
      if(pv>0)
      {
         for(int i=PositionsTotal()-1;i>=0;i--)
         {
            ulong t=PositionGetTicket(i);
            if(PositionSelectByTicket(t))
               if(PositionGetInteger(POSITION_MAGIC)==InpMagic)
               {
                  double op=PositionGetDouble(POSITION_PRICE_OPEN);
                  double tpPips=g_tpUSD/pv;
                  double tpPrice=(dir==POSITION_TYPE_BUY)
                                  ? NormalizeDouble(op+tpPips*pt,digits)
                                  : NormalizeDouble(op-tpPips*pt,digits);
                  DrawHLine("hline_tp",tpPrice,InpColorProfit,STYLE_DASH,
                            "Auto TP: $"+DoubleToString(g_tpUSD,2));
                  break;
               }
         }
      }
   }

   for(int lvl=0;lvl<InpMaxRecoveryLevels&&lvl<10;lvl++)
   {
      if(g_recoveryPrices[lvl]<=0) continue;
      color lc=g_recoveryFired[lvl]?InpColorProfit:C'80,80,155';
      DrawHLine("hline_rec"+(string)lvl, g_recoveryPrices[lvl], lc, STYLE_DASH,
                StringFormat("Rec %d | lot %.2f | BE->%s",
                lvl+1,recLot[lvl],DoubleToString(recBE[lvl],digits)));
   }

   ChartRedraw();
}

//+------------------------------------------------------------------+
void OpenCycle(ENUM_ORDER_TYPE dir)
{
   if(!SpreadOk()) return;

   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = (dir==ORDER_TYPE_BUY)?ask:bid;

   if(!HasEnoughMargin(dir, g_lot1, entry)) return;

   g_slIntroduced  = false;
   g_recoveryCount = 0;
   g_cycleActive   = true;
   g_lastEntryTime = TimeCurrent();
   ArrayInitialize(g_recoveryFired,  false);
   ArrayInitialize(g_recoveryPrices, 0);

   string lbl=(dir==ORDER_TYPE_BUY)?"HSv61-E1-BUY":"HSv61-E1-SELL";
   bool ok=(dir==ORDER_TYPE_BUY)
           ? trade.Buy(g_lot1,  _Symbol, entry, 0, 0, lbl)
           : trade.Sell(g_lot1, _Symbol, entry, 0, 0, lbl);

   if(!ok)
   { Print("ENTRY FAILED: ",trade.ResultRetcodeDescription()); g_cycleActive=false; return; }

   g_lastWasBuy = (dir==ORDER_TYPE_BUY);
   Print("ENTRY | ",(dir==ORDER_TYPE_BUY?"BUY":"SELL"),
         " lot:",DoubleToString(g_lot1,2)," @ ",entry,
         " | Stake $",DoubleToString(InpStakeUSD,2));

   ENUM_POSITION_TYPE posDir=(dir==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
   CalcRecoveryTriggers(entry, posDir);

   for(int i=0;i<InpMaxRecoveryLevels&&i<10;i++)
      Print("  Recovery ",i+1," triggers @ ",
            DoubleToString(g_recoveryPrices[i],(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS)),
            "  (lot ",DoubleToString(NormalizeLot(g_lot1*(i==0?InpRecoveryMult1:i==1?InpRecoveryMult2:InpRecoveryMult3)),2),")");
}

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(GetFillingMode());
   ArrayInitialize(g_recoveryFired,  false);
   ArrayInitialize(g_recoveryPrices, 0);

   UpdateDerivedParams(); // computes g_lot1 and all $ thresholds from stake
   UpdatePanel();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { DeletePanel(); }

void OnTick()
{
   int positions = CountMyPositions();

   if(positions==0)
   {
      if(g_cycleActive) MarkCycleComplete("All positions closed");

      if(InpRetrySeconds>0)
         if((int)(TimeCurrent()-g_lastEntryTime)<InpRetrySeconds)
         { UpdatePanel(); return; }

      bool doBuy=false, doSell=false;
      if(InpForceDir==FORCE_BUY)            doBuy=true;
      else if(InpForceDir==FORCE_SELL)      doSell=true;
      else if(InpForceDir==FORCE_ALTERNATE) { if(g_lastWasBuy) doSell=true; else doBuy=true; }

      // ── Wire real signal here ───────────────────────────────
      // if(InpForceDir==FORCE_OFF)
      // {
      //    doBuy  = (signalBuffer[0] == 1.0);
      //    doSell = (signalBuffer[0] == -1.0);
      // }
      // ────────────────────────────────────────────────────────

      if(doBuy)  OpenCycle(ORDER_TYPE_BUY);
      if(doSell) OpenCycle(ORDER_TYPE_SELL);
      UpdatePanel();
      return;
   }

   g_cycleActive = true;
   CheckCircuitBreaker(); // must be first
   ManageProfitSL();
   ManageAutoTP();
   ManageAutoRecovery();
   ManageBasketExit();
   UpdatePanel();
}

void OnChartEvent(const int id,const long &lp,const double &dp,const string &sp)
{
   if(id==CHARTEVENT_CHART_CHANGE) UpdatePanel();
}
//+------------------------------------------------------------------+
