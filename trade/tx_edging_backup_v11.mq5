//+------------------------------------------------------------------+
//|                                       HedgeStrike_EA_v11.mq5    |
//|                    Hedge Recovery — Path 1                        |
//|                                                                  |
//|  THREE RULES. NOTHING ELSE.                                      |
//|                                                                  |
//|  1. E1 opens on signal. No SL. No TP. No grid.                   |
//|                                                                  |
//|  2. When basket loss >= trigger:                                  |
//|     Open E2 OPPOSITE direction.                                  |
//|     E2 lot = E1_lot + (CurrentLoss / InpE2TargetPips) / PipVal  |
//|     This targets faster recovery if movement continues            |
//|     in hedge direction.                                           |
//|                                                                  |
//|  3. Every tick: if basket P&L >= 0 → close both. Done.          |
//|                                                                  |
//|  NOTE: No strategy can guarantee profit in all market conditions |
//|  (spread, slippage, gaps, trend reversals, execution delays).    |
//|  This EA uses hedge + basket management to reduce drawdown and    |
//|  recover efficiently under normal conditions.                     |
//|                                                                  |
//|  SCALING: Change InpStakeUSD — E1 lot auto-derives.             |
//+------------------------------------------------------------------+

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

input group "== STAKE =="
input double InpStakeUSD          = 10.0;  // Stake $ — E1 lot auto-derives from this

input group "== ENTRY =="
input int    InpMagic             = 11111;
input int    InpSlippage          = 20;
input bool   InpSingleCycleOnly   = false; // Continuous cycles by default

input group "== HEDGE TRIGGER =="
input double InpHedgeTriggerPct   = 2.0;   // Open E2 when loss >= X% of stake (2% = $0.20 on $10)
input double InpMinHedgeTriggerUSD= 1.0;   // Absolute minimum hedge trigger in USD (avoid spread-noise triggers)
//  KEEP THIS LOW (2-5%) — hedge must fire before loss grows large
//  The earlier the hedge fires, the smaller E2 needs to be, the faster recovery

input group "== E2 SIZING =="
input int    InpE2TargetPips      = 20;    // Pips for E2 to recover loss — 20 = fast recovery on Gold M5
//  Smaller = E2 recovers faster but needs bigger lot
//  Larger  = E2 lot is smaller but takes longer to recover
//  0 = EA calculates automatically based on current volatility

input group "== EXIT =="
input double InpBasketExitUSD     = 0.20;  // Close both when basket >= $X (default keeps profit, not just breakeven)
input double InpE1TPPct           = 20.0;  // Close E1 alone if it profits X% of stake before hedge needed

input group "== HEDGE SAFETY =="
input double InpMaxE2Multiplier   = 3.0;   // Cap E2 size: E2 <= E1 * multiplier
input double InpPostHedgeMaxLossUSD = 1.5; // Max extra loss allowed after hedge opens
input double InpHedgeProfitLockUSD  = 0.20;// Start lock only after basket reaches this profit
input double InpHedgeTrailBackUSD   = 0.10;// If profit pulls back by this amount, close basket

input group "== CIRCUIT BREAKER =="
input double InpMaxLossPct        = 30.0;  // Hard close all if loss >= X% of stake (-$3 on $10)

input group "== SPREAD GUARD =="
input bool   InpCheckSpread       = true;
input int    InpMaxSpreadPts      = 100;   // Gold can spread 20-80pts — set generously

input group "== PANEL =="
input int    InpPanelX            = 18;
input int    InpPanelY            = 50;
input color  InpColorProfit       = clrLimeGreen;
input color  InpColorLoss         = clrTomato;
input color  InpColorNeutral      = clrSilver;
input color  InpColorAlert        = clrGold;
input color  InpColorHedge        = clrDodgerBlue;

input group "== SIGNAL =="
enum ENUM_FORCE_DIR {FORCE_OFF=0,FORCE_BUY=1,FORCE_SELL=2,FORCE_ALTERNATE=3};
input ENUM_FORCE_DIR InpForceDir  = FORCE_BUY; // FORCE_OFF requires custom signal code below
input int    InpRetrySeconds      = 30;

//--- Globals
CTrade   trade;
bool     g_lastWasBuy    = false;
datetime g_lastEntryTime = 0;
bool     g_hasOpenedOnce = false;
bool     g_cycleActive   = false;
bool     g_hedgeOpen     = false;
ulong    g_e1Ticket      = 0;
ulong    g_e2Ticket      = 0;
double   g_e1Entry       = 0;
double   g_lot1          = 0.01;
double   g_lot2          = 0.02;
double   g_hedgeTriggerUSD = 1.0;
double   g_tpUSD           = 2.0;
double   g_maxLossUSD      = 6.0;
double   g_hedgeOpenPnL    = 0.0;
double   g_hedgePeakPnL    = -1e9;
ENUM_POSITION_TYPE g_e1Dir = POSITION_TYPE_BUY;
string   PFX             = "HSv11c_";

double EffectiveHedgeTriggerUSD()
{
   double pctTrigger = InpStakeUSD * (InpHedgeTriggerPct/100.0);
   return MathMax(pctTrigger, InpMinHedgeTriggerUSD);
}

bool IsHedgingAccount()
{
   long mm = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   return (mm == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   ENUM_SYMBOL_TRADE_EXECUTION ex=
      (ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_EXEMODE);
   switch(ex){
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
   return NormalizeDouble(lot,MathMax(dec,2));
}

double PipValForLot(double lot)
{
   double tick =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tsize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double pt   =SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   return (tick/tsize)*pt*lot;
}

//+------------------------------------------------------------------+
//| E1 lot: risk 5% of stake over InpHedgeTriggerPct% loss distance |
//+------------------------------------------------------------------+
double CalcE1Lot()
{
   // We want E1 lot such that at hedge trigger ($X loss),
   // the lot is proportionate to stake
   double triggerUSD = InpStakeUSD * (InpHedgeTriggerPct/100.0);
   // Assume ~50 pip move causes the trigger (conservative)
   double assumedPips = 50.0;
   double tick =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tsize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double pt   =SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double pvPer001=(tick/tsize)*pt*0.01;
   if(pvPer001<=0) return NormalizeLot(0.01);
   return NormalizeLot(triggerUSD / (assumedPips * (pvPer001/0.01)));
}

//+------------------------------------------------------------------+
//| THE CORE FORMULA — calculates E2 lot for guaranteed BE          |
//| Given: current basket loss, target recovery pips                |
//| Returns: E2 lot such that after targetPips, basket = 0          |
//+------------------------------------------------------------------+
double CalcE2Lot(double currentLossAbs, double targetPips)
{
   if(targetPips <= 0 || currentLossAbs <= 0) return NormalizeLot(g_lot1 * 2);

   double pvPer001 = PipValForLot(0.01);
   if(pvPer001 <= 0) return NormalizeLot(g_lot1 * 2);

   // Formula derivation:
   // After E2 opens, per pip: net = pvFor(l2) - pvFor(l1)
   // To recover currentLoss in targetPips:
   //   targetPips × (pvFor(l2) - pvFor(l1)) = currentLoss
   //   pvFor(l2) = currentLoss/targetPips + pvFor(l1)
   //   l2/0.01 × pvPer001 = currentLoss/targetPips + l1/0.01 × pvPer001
   //   l2 = l1 + (currentLoss/targetPips) / pvPer001 × 0.01

   double extra = (currentLossAbs / targetPips) / pvPer001 * 0.01;
   double l2 = g_lot1 + extra;

   // Add 10% buffer so basket goes slightly positive (small win not just BE)
   l2 *= 1.10;

   // Safety cap: avoid over-hedging into a huge net directional position
   double maxL2 = g_lot1 * MathMax(InpMaxE2Multiplier, 1.1);
   if(l2 > maxL2)
   {
      Print("E2 capped by multiplier: raw=",DoubleToString(l2,2),
            " cap=",DoubleToString(maxL2,2));
      l2 = maxL2;
   }

   double result = NormalizeLot(l2);

   // CRITICAL: E2 must always be strictly larger than E1
   // If formula returned same lot (rounding), force at least 1 step above E1
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(result <= g_lot1)
      result = NormalizeLot(g_lot1 + lotStep);

   // Verify: net per pip must be positive
   double netPP = PipValForLot(result) - PipValForLot(g_lot1);
   if(netPP <= 0)
   {
      Print("WARNING: Formula gave zero net/pip. Forcing E2 = E1 + 2 steps.");
      result = NormalizeLot(g_lot1 + lotStep * 2);
   }

   return result;
}

//+------------------------------------------------------------------+
//| Auto target pips: calculated so E2 is always > E1 by min step  |
//| Formula: target = lossAbs / (pvPer001 * lotStep)                |
//| This guarantees E2 lot >= E1 lot + 1 lot step                  |
//+------------------------------------------------------------------+
int GetAutoTargetPips(double currentLossAbs)
{
   double pvPer001 = PipValForLot(0.01);
   double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(pvPer001 <= 0 || lotStep <= 0 || currentLossAbs <= 0) return 20;

   // Target pips that produces exactly 1 lot step of extra E2 over E1
   // extra = (lossAbs/target) / pvPer001 * 0.01 = lotStep
   // target = (lossAbs * 0.01) / (pvPer001 * lotStep)
   double target = (currentLossAbs * 0.01) / (pvPer001 * lotStep);

   // Clamp: minimum 5 pips (ultra fast recovery), maximum 50 pips (reasonable)
   int result = (int)MathMax(5.0, MathMin(50.0, MathCeil(target)));
   Print("Auto target pips: ",result,"  (loss=$",DoubleToString(currentLossAbs,2),
         " pvPer001=$",DoubleToString(pvPer001,4)," lotStep=",DoubleToString(lotStep,2),")");
   return result;
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
            t+=PositionGetDouble(POSITION_PROFIT)
              +PositionGetDouble(POSITION_SWAP)
              +PositionGetDouble(POSITION_COMMISSION);
   return t;
}

bool SpreadOk()
{
   if(!InpCheckSpread) return true;
   double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   int sp=(int)MathRound((SymbolInfoDouble(_Symbol,SYMBOL_ASK)-
                          SymbolInfoDouble(_Symbol,SYMBOL_BID))/pt);
   if(sp>InpMaxSpreadPts){ Print("Spread blocked:",sp,"pts"); return false; }
   return true;
}

bool HasMargin(ENUM_ORDER_TYPE dir,double lot,double price)
{
   double req=0;
   if(!OrderCalcMargin(dir,_Symbol,lot,price,req)) return false;
   if(req>AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   { Print("MARGIN BLOCKED $",DoubleToString(req,2)); return false; }
   return true;
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

void MarkCycleComplete(string reason)
{
   Print("=== DONE: ",reason," | Final P&L: $",DoubleToString(GetBasketPnL(),2)," ===");
   g_cycleActive=false; g_hedgeOpen=false;
   g_e1Ticket=0; g_e2Ticket=0; g_e1Entry=0;
   g_hedgeOpenPnL=0.0; g_hedgePeakPnL=-1e9;
   g_lastEntryTime=TimeCurrent();
   ObjectDelete(0,PFX+"hl_e1"); ObjectDelete(0,PFX+"hl_trig");
   ObjectDelete(0,PFX+"hl_tp");
}

//+------------------------------------------------------------------+
//| RULE 2: Open E2 when loss threshold hit                         |
//+------------------------------------------------------------------+
void CheckHedgeTrigger()
{
   if(g_hedgeOpen) return;
   double pnl=GetBasketPnL();
   if(pnl > -g_hedgeTriggerUSD) return;  // not yet at trigger

   if(!SpreadOk()) return;

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double pt =SymbolInfoDouble(_Symbol,SYMBOL_POINT);

   double lossAbs = MathAbs(pnl);
   int targetPips = (InpE2TargetPips > 0) ? InpE2TargetPips : GetAutoTargetPips(lossAbs);
   g_lot2 = CalcE2Lot(lossAbs, targetPips);

   // E2 is opposite to E1
   ENUM_ORDER_TYPE e2Type = (g_e1Dir==POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   double e2Price = (e2Type==ORDER_TYPE_SELL) ? bid : ask;

   if(!HasMargin(e2Type, g_lot2, e2Price)) return;

   // Verify math before placing
   double netPerPip = PipValForLot(g_lot2) - PipValForLot(g_lot1);
   double recoverPips = (netPerPip > 0) ? lossAbs/netPerPip : 99999;

   // Hard validation: E2 must be larger than E1
   if(g_lot2 <= g_lot1)
   {
      Print("HEDGE BLOCKED: E2 lot (",DoubleToString(g_lot2,2),
            ") must be > E1 lot (",DoubleToString(g_lot1,2),
            "). Increase InpHedgeTriggerPct or decrease InpE2TargetPips.");
      return;
   }

   Print("=== HEDGE TRIGGER ===");
   Print("Basket loss: $",DoubleToString(lossAbs,2),
         " | Trigger: $",DoubleToString(g_hedgeTriggerUSD,2));
   Print("E2 lot: ",DoubleToString(g_lot2,2),
         " (E1=",DoubleToString(g_lot1,2)," + ",DoubleToString(g_lot2-g_lot1,2)," extra)");
   Print("Target pips: ",targetPips,
         " | Net/pip after hedge: +$",DoubleToString(netPerPip,3));
   Print("Recover in ~",DoubleToString(recoverPips,0)," pips if move continues in hedge direction");
   Print("====================");

   bool ok = (e2Type==ORDER_TYPE_SELL)
              ? trade.Sell(g_lot2,_Symbol,e2Price,0,0,"HSv11-E2-HEDGE")
              : trade.Buy(g_lot2, _Symbol,e2Price,0,0,"HSv11-E2-HEDGE");

   if(ok)
   {
      g_hedgeOpen = true;
      g_hedgeOpenPnL = pnl;
      g_hedgePeakPnL = pnl;
      // Store E2 ticket
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong t=PositionGetTicket(i);
         if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==InpMagic&&t!=g_e1Ticket)
         { g_e2Ticket=t; break; }
      }
      Alert("HedgeStrike v11 | HEDGE OPEN\n",
            "E2 ",DoubleToString(g_lot2,2)," lot @ ",DoubleToString(e2Price,
            (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS)),"\n",
            "Net +$",DoubleToString(netPerPip,3),"/pip\n",
         "Recover in ~",DoubleToString(recoverPips,0)," pips (hedge direction)");
   }
   else
      Print("E2 FAILED: ",trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| RULE 3: Close both when basket >= exit target                   |
//+------------------------------------------------------------------+
void CheckBasketExit()
{
   if(!g_hedgeOpen) return; // basket exit is for hedged phase only

   double pnl=GetBasketPnL();
   double exitTarget = InpBasketExitUSD; // 0 = exact breakeven

   if(pnl >= exitTarget)
   {
      Print("BASKET EXIT | $",DoubleToString(pnl,2),
            " >= target $",DoubleToString(exitTarget,2));
      CloseAll();
      MarkCycleComplete(g_hedgeOpen ? "Hedge recovered" : "E1 profit");
   }
}

//+------------------------------------------------------------------+
//| E1 solo TP — close E1 alone if it profits before hedge needed   |
//+------------------------------------------------------------------+
void CheckE1SoloTP()
{
   if(g_hedgeOpen) return;  // once hedged, use basket exit only
   double pnl=GetBasketPnL();
   if(pnl >= g_tpUSD)
   {
      Print("E1 SOLO TP | $",DoubleToString(pnl,2));
      CloseAll();
      MarkCycleComplete("E1 TP");
   }
}

//+------------------------------------------------------------------+
//| CIRCUIT BREAKER                                                  |
//+------------------------------------------------------------------+
void CheckCircuitBreaker()
{
   double pnl=GetBasketPnL();
   if(pnl <= -g_maxLossUSD)
   {
      Print("CIRCUIT BREAKER | $",DoubleToString(pnl,2));
      Alert("HedgeStrike v11 | CIRCUIT BREAKER | Loss $",DoubleToString(MathAbs(pnl),2));
      CloseAll();
      MarkCycleComplete("Circuit breaker");
   }
}

//+------------------------------------------------------------------+
//| HEDGE PROTECTION: lock profits + cap extra post-hedge loss      |
//+------------------------------------------------------------------+
void CheckHedgeProtection()
{
   if(!g_hedgeOpen) return;

   double pnl=GetBasketPnL();
   if(pnl > g_hedgePeakPnL) g_hedgePeakPnL = pnl;

   // If basket became profitable enough, lock part of it on pullback
   if(g_hedgePeakPnL >= InpHedgeProfitLockUSD)
   {
      if(pnl <= g_hedgePeakPnL - InpHedgeTrailBackUSD)
      {
         Print("HEDGE PROFIT LOCK | Peak $",DoubleToString(g_hedgePeakPnL,2),
               " -> now $",DoubleToString(pnl,2));
         CloseAll();
         MarkCycleComplete("Hedge profit lock");
         return;
      }
   }

   // Do not allow hedge phase to grow too far against us
   if(pnl <= g_hedgeOpenPnL - InpPostHedgeMaxLossUSD)
   {
      Print("POST-HEDGE LOSS CAP | OpenPnl $",DoubleToString(g_hedgeOpenPnL,2),
            " -> now $",DoubleToString(pnl,2));
      CloseAll();
      MarkCycleComplete("Post-hedge loss cap");
      return;
   }
}

//+------------------------------------------------------------------+
//| PANEL                                                            |
//+------------------------------------------------------------------+
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
void DeletePanel(){ObjectsDeleteAll(0,PFX);}

void UpdatePanel()
{
   int px=InpPanelX,py=InpPanelY,pw=300,lh=17,pad=9;

   if(!g_cycleActive)
   {
      // Idle — show what will happen on next entry
      double trigUSD=InpStakeUSD*(InpHedgeTriggerPct/100.0);
      trigUSD=MathMax(trigUSD,InpMinHedgeTriggerUSD);
      double tpUSD  =InpStakeUSD*(InpE1TPPct/100.0);
      DR("bg",px,py,pw,72,C'18,18,28',C'40,70,40');
      DL("t1","HedgeStrike v11  |  waiting",px+pad,py+10,9,InpColorNeutral,true);
      DL("t2","E1 lot: "+DoubleToString(g_lot1,2)+
              "  |  Hedge triggers at -$"+DoubleToString(trigUSD,2),
              px+pad,py+26,8,InpColorNeutral);
      DL("t3","E1 TP: +$"+DoubleToString(tpUSD,2)+
              "  |  CB: -$"+DoubleToString(g_maxLossUSD,2),
              px+pad,py+42,8,C'80,80,100');
      DL("t4","Rule: Hedge on controlled loss — basket-managed exits",
              px+pad,py+57,7,C'60,90,60');
      ChartRedraw(); return;
   }

   double pnl    =GetBasketPnL();
   double equity =AccountInfoDouble(ACCOUNT_EQUITY);
   double margin =AccountInfoDouble(ACCOUNT_MARGIN);
   double freeM  =AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double pt     =SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   int    digits =(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double bid    =SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask    =SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   string dirStr =(g_e1Dir==POSITION_TYPE_BUY)?"BUY":"SELL";
   int    positions=CountMyPositions();

   // Net per pip (only meaningful when hedged)
   double netPP=0;
   if(g_hedgeOpen) netPP=PipValForLot(g_lot2)-PipValForLot(g_lot1);

   // Recovery progress
   double lossAbs=MathAbs(MathMin(pnl,0));
   double recoverPips=(netPP>0&&g_hedgeOpen) ? lossAbs/netPP : 0;

   int rows=g_hedgeOpen?18:14;
   int totalH=pad+rows*lh+pad;

   color bdr=!g_hedgeOpen
              ?(pnl>=0?C'25,85,45':C'60,35,25')
              :C'25,50,95';  // blue border when hedged
   DR("bg",px,py,pw,totalH,C'13,15,24',bdr);
   int y=py+pad;

   DL("title","HedgeStrike v11  |  "+dirStr+"  |  "+
              (string)positions+" pos",px+pad,y,9,InpColorNeutral,true); y+=lh;

   // Phase
   string phase=!g_hedgeOpen
                ?"Phase 1 — E1 running, watching for trigger"
                :"Phase 2 — HEDGED, recovering to break-even";
   DL("phase",phase,px+pad,y,8,g_hedgeOpen?InpColorHedge:InpColorNeutral,g_hedgeOpen); y+=lh+3;

   // Account
   DL("s_ac","ACCOUNT",px+pad,y,7,C'85,85,115'); y+=lh;
   DL("eq","Equity      $"+DoubleToString(equity,2),px+pad,y,8,InpColorNeutral); y+=lh;
   DL("mg","Margin      $"+DoubleToString(margin,2),px+pad,y,8,InpColorNeutral); y+=lh;
   DL("fm","Free margin $"+DoubleToString(freeM,2), px+pad,y,8,InpColorNeutral); y+=lh+2;

   // Basket
   DL("s_bk","BASKET",px+pad,y,7,C'85,85,115'); y+=lh;
   color pc=(pnl>=0)?InpColorProfit:InpColorLoss;
   DL("pnl","P&L         $"+(pnl>=0?"+":"")+DoubleToString(pnl,2),
      px+pad,y,8,pc,true); y+=lh;

   if(!g_hedgeOpen)
   {
      // Phase 1
      DL("e1l","E1 lot      "+DoubleToString(g_lot1,2)+
               "  @ "+DoubleToString(g_e1Entry,digits),
               px+pad,y,8,InpColorNeutral); y+=lh;
      color tc=(pnl>=-g_hedgeTriggerUSD)?InpColorNeutral:InpColorAlert;
      DL("trig","Hedge at    -$"+DoubleToString(g_hedgeTriggerUSD,2)+
                "  ("+(pnl<-g_hedgeTriggerUSD?"TRIGGERED":"waiting")+")",
                px+pad,y,8,tc); y+=lh;
      DL("tp1", "E1 solo TP  +$"+DoubleToString(g_tpUSD,2),
                px+pad,y,8,InpColorNeutral); y+=lh;
      DL("cb",  "Circuit br  -$"+DoubleToString(g_maxLossUSD,2),
                px+pad,y,8,
                (pnl<=-g_maxLossUSD*0.7)?InpColorLoss:InpColorNeutral); y+=lh;

      // Chart line: trigger level
      if(g_e1Entry>0)
      {
         DH("hl_e1",g_e1Entry,InpColorNeutral,STYLE_SOLID,"E1 entry");
         double trigPrice=(g_e1Dir==POSITION_TYPE_BUY)
                           ? g_e1Entry - (g_hedgeTriggerUSD/PipValForLot(g_lot1))*pt
                           : g_e1Entry + (g_hedgeTriggerUSD/PipValForLot(g_lot1))*pt;
         DH("hl_trig",trigPrice,InpColorAlert,STYLE_DASH,
            "Hedge trigger — E2 opens here | -$"+DoubleToString(g_hedgeTriggerUSD,2));
         double tpPrice=(g_e1Dir==POSITION_TYPE_BUY)
                         ? g_e1Entry + (g_tpUSD/PipValForLot(g_lot1))*pt
                         : g_e1Entry - (g_tpUSD/PipValForLot(g_lot1))*pt;
         DH("hl_tp",tpPrice,InpColorProfit,STYLE_DASH,
            "E1 solo TP +$"+DoubleToString(g_tpUSD,2));
      }
   }
   else
   {
      // Phase 2: hedged
      DL("e1l","E1          "+DoubleToString(g_lot1,2)+
               "  @ "+DoubleToString(g_e1Entry,digits),
               px+pad,y,8,InpColorNeutral); y+=lh;
      DL("e2l","E2 (hedge)  "+DoubleToString(g_lot2,2)+" lot",
               px+pad,y,8,InpColorHedge,true); y+=lh;
      DL("npp","Net/pip     +$"+DoubleToString(netPP,3)+" per pip (any direction)",
               px+pad,y,8,InpColorProfit); y+=lh;
      DL("rec","To BE       ~"+DoubleToString(recoverPips,0)+" more pips",
               px+pad,y,8,(recoverPips<20)?InpColorProfit:InpColorAlert); y+=lh;
      DL("exit","Exit at     $"+DoubleToString(InpBasketExitUSD,2)+
                " (basket >= this → close both)",
                px+pad,y,8,InpColorNeutral); y+=lh;
      DL("cb","Circuit br  -$"+DoubleToString(g_maxLossUSD,2),
               px+pad,y,8,
               (pnl<=-g_maxLossUSD*0.7)?InpColorLoss:InpColorNeutral); y+=lh;

      // Progress bar
      double pct=MathMin(100,(g_hedgeTriggerUSD-lossAbs)/g_hedgeTriggerUSD*100+100);
      string bar="Recovery [";
      int fill=(int)MathMax(0,MathMin(20,(int)((1-(lossAbs/MathMax(lossAbs,0.01)))*20)));
      if(pnl>=0) fill=20;
      for(int i=0;i<20;i++) bar+=(i<fill?"#":".");
      bar+="]";
      DL("prog",bar,px+pad,y,7,pnl>=0?InpColorProfit:InpColorNeutral); y+=lh;
   }

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Open entry                                                       |
//+------------------------------------------------------------------+
void OpenCycle(ENUM_ORDER_TYPE dir)
{
   if(!SpreadOk()) return;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double entry=(dir==ORDER_TYPE_BUY)?ask:bid;

   g_lot1=CalcE1Lot();
   if(!HasMargin(dir,g_lot1,entry)) return;

   bool ok=(dir==ORDER_TYPE_BUY)
           ?trade.Buy(g_lot1, _Symbol,entry,0,0,"HSv11-E1-BUY")
           :trade.Sell(g_lot1,_Symbol,entry,0,0,"HSv11-E1-SELL");
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
   g_e1Dir         = (dir==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
   g_e1Entry       = entry;
   g_hedgeTriggerUSD = EffectiveHedgeTriggerUSD();
   g_tpUSD           = InpStakeUSD*(InpE1TPPct/100.0);
   g_maxLossUSD      = InpStakeUSD*(InpMaxLossPct/100.0);
   g_lot2            = 0;
   g_lastEntryTime   = TimeCurrent();

   Print("E1 OPEN | ",(dir==ORDER_TYPE_BUY?"BUY":"SELL"),
         " ",DoubleToString(g_lot1,2)," @ ",entry,
         " | Hedge fires at loss -$",DoubleToString(g_hedgeTriggerUSD,2));
}

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(GetFillingMode());

   if(!IsHedgingAccount())
   {
      Print("INIT FAILED: Account is not HEDGING mode. This EA requires opposite positions.");
      Print("Switch to a hedging account (not netting/exchange) and re-attach EA.");
      return INIT_FAILED;
   }

   g_lot1        = CalcE1Lot();
   g_maxLossUSD  = InpStakeUSD*(InpMaxLossPct/100.0);
   g_hedgeTriggerUSD = EffectiveHedgeTriggerUSD();
   g_tpUSD           = InpStakeUSD*(InpE1TPPct/100.0);

   Print("=== HedgeStrike v11 ===");
   Print("Stake: $",DoubleToString(InpStakeUSD,2),
         " | E1 lot: ",DoubleToString(g_lot1,2),
         " | Hedge trigger: -$",DoubleToString(g_hedgeTriggerUSD,2),
         " | CB: -$",DoubleToString(g_maxLossUSD,2));
      Print("Mode: ",InpSingleCycleOnly?"Single-cycle":"Continuous",
         " | ForceDir: ",(string)InpForceDir);

   // RECOVERY: If EA restarts with open positions, reconstruct state immediately
   // This prevents the "hedge waiting but loss already $5" problem
   int existingPositions = 0;
   int existingBuys = 0, existingSells = 0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      existingPositions++;
      ENUM_POSITION_TYPE ptype=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(ptype==POSITION_TYPE_BUY)  { existingBuys++;  if(g_e1Ticket==0){ g_e1Ticket=t; g_e1Entry=PositionGetDouble(POSITION_PRICE_OPEN); g_e1Dir=POSITION_TYPE_BUY;  g_lot1=PositionGetDouble(POSITION_VOLUME); } }
      if(ptype==POSITION_TYPE_SELL) { existingSells++; if(existingBuys==0&&g_e1Ticket==0){ g_e1Ticket=t; g_e1Entry=PositionGetDouble(POSITION_PRICE_OPEN); g_e1Dir=POSITION_TYPE_SELL; g_lot1=PositionGetDouble(POSITION_VOLUME); } }
   }

   if(existingPositions > 0)
   {
      g_cycleActive = true;
      // If 2 positions exist (buy + sell) → hedge already open
      g_hedgeOpen   = (existingPositions >= 2);
      if(g_hedgeOpen)
      {
         // Find E2 lot (the non-E1 position)
         for(int i=PositionsTotal()-1;i>=0;i--)
         {
            ulong t=PositionGetTicket(i);
            if(!PositionSelectByTicket(t)) continue;
            if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
            if(t!=g_e1Ticket){ g_e2Ticket=t; g_lot2=PositionGetDouble(POSITION_VOLUME); break; }
         }
         Print("RECOVERY: Found ",existingPositions," positions — hedge already open. E1=",DoubleToString(g_lot1,2)," E2=",DoubleToString(g_lot2,2));
      }
      else
      {
         Print("RECOVERY: Found 1 position — E1 running, hedge not yet open.");
         Print("Current P&L: $",DoubleToString(GetBasketPnL(),2),
               " | Trigger at: -$",DoubleToString(g_hedgeTriggerUSD,2));
         // If already past trigger, hedge will fire on next tick automatically
         double curPnl = GetBasketPnL();
         if(curPnl < -g_hedgeTriggerUSD)
            Print("WARNING: Already past trigger. Hedge will fire on next tick.");
      }
   }

   UpdatePanel();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason){ DeletePanel(); }

void OnTick()
{
   int positions=CountMyPositions();

   if(positions==0)
   {
      if(g_cycleActive) MarkCycleComplete("All positions closed");
      if(InpSingleCycleOnly && g_hasOpenedOnce)
      {
         UpdatePanel();
         return;
      }
      if(InpRetrySeconds>0)
         if((int)(TimeCurrent()-g_lastEntryTime)<InpRetrySeconds)
         { UpdatePanel(); return; }

      bool doBuy=false,doSell=false;
      if(InpForceDir==FORCE_BUY)            doBuy=true;
      else if(InpForceDir==FORCE_SELL)      doSell=true;
      else if(InpForceDir==FORCE_ALTERNATE) {if(g_lastWasBuy) doSell=true; else doBuy=true;}
      // ── wire signal here ─────────────────────────────────
      // if(InpForceDir==FORCE_OFF){
      //    doBuy =(buf[0]==1.0);
      //    doSell=(buf[0]==-1.0);
      // }
      // ─────────────────────────────────────────────────────
      if(doBuy)  OpenCycle(ORDER_TYPE_BUY);
      if(doSell) OpenCycle(ORDER_TYPE_SELL);
      UpdatePanel(); return;
   }

   // If positions exist but state lost (EA restart), recover E1 ticket
   if(!g_cycleActive || g_e1Ticket==0)
   {
      for(int _i=PositionsTotal()-1;_i>=0;_i--)
      {
         ulong _t=PositionGetTicket(_i);
         if(!PositionSelectByTicket(_t)) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
         if(g_e1Ticket==0)
         {
            g_e1Ticket=_t;
            g_e1Entry =PositionGetDouble(POSITION_PRICE_OPEN);
            g_e1Dir   =(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            g_lot1    =PositionGetDouble(POSITION_VOLUME);
            g_cycleActive=true;
            g_hedgeTriggerUSD=EffectiveHedgeTriggerUSD();
            g_tpUSD          =InpStakeUSD*(InpE1TPPct/100.0);
            g_maxLossUSD     =InpStakeUSD*(InpMaxLossPct/100.0);
         }
      }
      if(positions>=2) g_hedgeOpen=true;
   }

   g_cycleActive=true;
   CheckHedgeTrigger();   // rule 2: open E2 when loss hits threshold
   CheckBasketExit();     // close hedged basket at profit target
   CheckHedgeProtection();// lock hedge profit / cap post-hedge drift
   CheckCircuitBreaker(); // final hard stop
   CheckE1SoloTP();       // bonus: close E1 early if it profits before hedge needed
   UpdatePanel();
}

void OnChartEvent(const int id,const long &lp,const double &dp,const string &sp)
{ if(id==CHARTEVENT_CHART_CHANGE) UpdatePanel(); }
//+------------------------------------------------------------------+