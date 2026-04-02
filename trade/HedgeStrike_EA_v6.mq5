//+------------------------------------------------------------------+
//|                                          HedgeStrike_EA_v6.mq5  |
//|               Full Automation: Profit Trail + Auto Recovery      |
//|                         Production v6.0                          |
//|                                                                  |
//|  PROFIT SIDE (fully automatic):                                  |
//|   - SL introduced at +10% of target profit                       |
//|   - SL trails upward as profit grows (never moves back)          |
//|   - Hard close at 50% of target profit (TP)                      |
//|                                                                  |
//|  LOSS SIDE (fully automatic):                                    |
//|   - When price hits a recovery zone, EA opens a new position     |
//|   - Lot sizes scale so the basket BE moves toward current price  |
//|   - Each recovery position also gets a hard basket-exit target   |
//|   - Max recovery levels is configurable (default 3)              |
//|   - After max levels, EA waits — no more averaging               |
//|                                                                  |
//|  PANEL: Live P&L, pips, basket BE, recovery levels,             |
//|         margin, equity, drawdown — all live every tick           |
//+------------------------------------------------------------------+

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Inputs
input group "== ENTRY =="
input double InpLot1              = 0.10;   // E1 lot size
input int    InpMagic             = 66666;  // Magic number
input int    InpSlippage          = 20;     // Slippage in points

input group "== PROFIT SIDE (Auto SL + Auto TP) =="
input double InpTargetProfit      = 50.0;   // Target profit in $ (baseline for % calcs)
input double InpSLTriggerPct      = 10.0;   // Introduce SL when profit >= X% of target
input int    InpSLBufferPips      = 3;      // SL pips above entry (BE + tiny buffer)
input bool   InpTrailSL           = true;   // Trail SL as profit grows
input double InpTrailStep         = 5.0;    // Trail ratchet step in $
input double InpAutoTPPct         = 50.0;   // Hard close when profit >= X% of target

input group "== LOSS SIDE (Auto Recovery) =="
input int    InpMaxRecoveryLevels = 3;      // Max recovery positions to open (0 = off)
input int    InpRecoverySpacePips = 15;     // Pip gap between each recovery level
input double InpRecoveryMult1     = 1.5;    // Lot multiplier for recovery level 1
input double InpRecoveryMult2     = 2.5;    // Lot multiplier for recovery level 2
input double InpRecoveryMult3     = 4.0;    // Lot multiplier for recovery level 3
input double InpBasketExitProfit  = 2.0;    // Close whole basket when combined P&L >= $X
input bool   InpCheckMarginBefore = true;   // Block recovery if margin insufficient

input group "== SPREAD GUARD =="
input bool   InpCheckSpread       = true;
input int    InpMaxSpreadPts      = 30;

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
int           g_recoveryCount     = 0;       // how many recovery positions opened this cycle
bool          g_recoveryFired[10];           // which levels have been auto-opened
double        g_recoveryPrices[10];          // price at which each level triggers
string        PFX                 = "HSv6_";

//+------------------------------------------------------------------+
//| Filling mode                                                     |
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
   lot = MathFloor(lot / step) * step;
   lot = MathMax(lot, mn);
   lot = MathMin(lot, mx);
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

//+------------------------------------------------------------------+
//| Full basket P&L including swap + commission                     |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Basket info: weighted avg entry, total lots, pips, direction    |
//+------------------------------------------------------------------+
void GetBasketInfo(double &avgEntry, double &totalLots, double &totalPips,
                   ENUM_POSITION_TYPE &dir)
{
   avgEntry  = 0; totalLots = 0; totalPips = 0;
   dir       = POSITION_TYPE_BUY;
   double ws = 0;
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid= SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask= SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      double lot  = PositionGetDouble(POSITION_VOLUME);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      dir         = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      ws          += open * lot;
      totalLots   += lot;
   }
   if(totalLots > 0)
   {
      avgEntry  = ws / totalLots;
      double cur = (dir == POSITION_TYPE_BUY) ? bid : ask;
      totalPips  = (dir == POSITION_TYPE_BUY)
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

//+------------------------------------------------------------------+
//| New basket BE after adding a recovery position                  |
//+------------------------------------------------------------------+
double NewBasketBE(double curAvg, double curLots, double recPrice, double recLot)
{
   double newLots = curLots + recLot;
   if(newLots <= 0) return 0;
   return (curAvg * curLots + recPrice * recLot) / newLots;
}

bool SpreadOk()
{
   if(!InpCheckSpread) return true;
   double pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int sp     = (int)MathRound((ask - bid) / pt);
   if(sp > InpMaxSpreadPts) { Print("Spread blocked: ", sp, " pts"); return false; }
   return true;
}

bool HasEnoughMargin(ENUM_ORDER_TYPE dir, double lot, double price)
{
   if(!InpCheckMarginBefore) return true;
   double req = 0;
   if(!OrderCalcMargin(dir, _Symbol, lot, price, req)) return false;
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(req > free)
   {
      Print("MARGIN BLOCKED — need $", DoubleToString(req,2),
            " free $", DoubleToString(free,2));
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Pre-calculate all recovery trigger prices for this cycle        |
//+------------------------------------------------------------------+
void CalcRecoveryTriggers(double e1Entry, ENUM_POSITION_TYPE dir)
{
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   for(int lvl = 0; lvl < InpMaxRecoveryLevels && lvl < 10; lvl++)
   {
      if(dir == POSITION_TYPE_BUY)
         g_recoveryPrices[lvl] = e1Entry - (InpRecoverySpacePips * (lvl + 1)) * pt;
      else
         g_recoveryPrices[lvl] = e1Entry + (InpRecoverySpacePips * (lvl + 1)) * pt;
   }
}

//+------------------------------------------------------------------+
//| PROFIT SIDE: Auto SL introduction + trailing                    |
//+------------------------------------------------------------------+
void ManageProfitSL()
{
   if(CountMyPositions() == 0) return;
   double pnl     = GetBasketPnL();
   double trigger = InpTargetProfit * (InpSLTriggerPct / 100.0);
   if(pnl < trigger) return;

   double pt     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL     = PositionGetDouble(POSITION_SL);
      double curTP     = PositionGetDouble(POSITION_TP);

      // Base SL: entry + buffer
      double newSL = (ptype == POSITION_TYPE_BUY)
                     ? NormalizeDouble(openPrice + InpSLBufferPips * pt, digits)
                     : NormalizeDouble(openPrice - InpSLBufferPips * pt, digits);

      // Trail ratchet
      if(InpTrailSL && g_slIntroduced)
      {
         double steps = MathFloor((pnl - trigger) / InpTrailStep);
         double lockProfit = trigger + steps * InpTrailStep;
         double avgEntry, totalLots, totalPips;
         ENUM_POSITION_TYPE dir;
         GetBasketInfo(avgEntry, totalLots, totalPips, dir);
         if(totalLots > 0)
         {
            double pv = PipValuePerLot(totalLots);
            if(pv > 0)
            {
               double lockPips = lockProfit / pv;
               double trailSL  = (ptype == POSITION_TYPE_BUY)
                                  ? NormalizeDouble(openPrice + lockPips * pt, digits)
                                  : NormalizeDouble(openPrice - lockPips * pt, digits);
               if(ptype == POSITION_TYPE_BUY  && trailSL > newSL) newSL = trailSL;
               if(ptype == POSITION_TYPE_SELL && trailSL < newSL) newSL = trailSL;
            }
         }
      }

      bool improve = (!g_slIntroduced)
                   || (ptype == POSITION_TYPE_BUY  && newSL > curSL)
                   || (ptype == POSITION_TYPE_SELL && (curSL <= 0 || newSL < curSL));

      if(improve && trade.PositionModify(ticket, newSL, curTP))
      {
         if(!g_slIntroduced)
         {
            g_slIntroduced = true;
            Print("AUTO SL PLACED | SL:", newSL, " P&L:$", DoubleToString(pnl,2));
         }
         else
            Print("AUTO SL TRAILED | SL:", newSL, " P&L:$", DoubleToString(pnl,2));
      }
   }
}

//+------------------------------------------------------------------+
//| PROFIT SIDE: Auto TP — hard close at 50% of target             |
//+------------------------------------------------------------------+
void ManageAutoTP()
{
   double pnl   = GetBasketPnL();
   double tpThr = InpTargetProfit * (InpAutoTPPct / 100.0);
   if(pnl >= tpThr)
   {
      Print("AUTO TP | Basket P&L $", DoubleToString(pnl,2),
            " >= TP threshold $", DoubleToString(tpThr,2), " | Closing all");
      CloseAll();
      MarkCycleComplete("Auto TP hit");
   }
}

//+------------------------------------------------------------------+
//| LOSS SIDE: Auto recovery — open position at each level          |
//+------------------------------------------------------------------+
void ManageAutoRecovery()
{
   if(InpMaxRecoveryLevels <= 0) return;
   if(g_recoveryCount >= InpMaxRecoveryLevels) return;

   double avgEntry, totalLots, totalPips;
   ENUM_POSITION_TYPE dir;
   GetBasketInfo(avgEntry, totalLots, totalPips, dir);
   if(totalPips >= 0) return;  // not in loss

   double pt     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double cur    = (dir == POSITION_TYPE_BUY) ? bid : ask;

   double mults[10];
   mults[0] = InpRecoveryMult1;
   mults[1] = InpRecoveryMult2;
   mults[2] = InpRecoveryMult3;
   for(int i = 3; i < 10; i++) mults[i] = mults[2] * (1.0 + i * 0.5);

   for(int lvl = 0; lvl < InpMaxRecoveryLevels && lvl < 10; lvl++)
   {
      if(g_recoveryFired[lvl]) continue;

      double trigPrice = g_recoveryPrices[lvl];
      bool   reached   = (dir == POSITION_TYPE_BUY)
                         ? (cur <= trigPrice)
                         : (cur >= trigPrice);
      if(!reached) continue;
      if(!SpreadOk()) continue;

      double recLot = NormalizeLot(InpLot1 * mults[lvl]);
      ENUM_ORDER_TYPE orderType = (dir == POSITION_TYPE_BUY)
                                  ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double execPrice = (orderType == ORDER_TYPE_BUY) ? ask : bid;

      if(!HasEnoughMargin(orderType, recLot, execPrice)) continue;

      // Calculate new basket BE after this recovery
      double newBE = NewBasketBE(avgEntry, totalLots, execPrice, recLot);

      Print("AUTO RECOVERY LEVEL ", lvl+1,
            " | Price:", execPrice,
            " | Lot:", recLot,
            " | New basket BE:", DoubleToString(newBE, digits),
            " | Basket P&L before: $", DoubleToString(GetBasketPnL(),2));

      bool ok = (orderType == ORDER_TYPE_BUY)
                ? trade.Buy(recLot, _Symbol, execPrice, 0, 0,
                            "HSv6-REC" + (string)(lvl+1))
                : trade.Sell(recLot, _Symbol, execPrice, 0, 0,
                             "HSv6-REC" + (string)(lvl+1));

      if(ok)
      {
         g_recoveryFired[lvl] = true;
         g_recoveryCount++;
         Alert(StringFormat(
            "HedgeStrike v6 | AUTO RECOVERY %d OPENED\n"
            "Lot: %.2f | Entry: %s\n"
            "New basket BE: %s\n"
            "Basket P&L: $%.2f",
            lvl+1, recLot,
            DoubleToString(execPrice, digits),
            DoubleToString(newBE, digits),
            GetBasketPnL()
         ));
      }
      else
         Print("Recovery ", lvl+1, " FAILED: ", trade.ResultRetcodeDescription());

      break; // one recovery per tick — let price settle
   }
}

//+------------------------------------------------------------------+
//| LOSS SIDE: Basket exit after recovery — close when profitable  |
//+------------------------------------------------------------------+
void ManageBasketExit()
{
   if(g_recoveryCount == 0) return;  // no recovery positions yet
   double pnl = GetBasketPnL();
   if(pnl >= InpBasketExitProfit)
   {
      Print("BASKET EXIT | P&L $", DoubleToString(pnl,2),
            " >= target $", DoubleToString(InpBasketExitProfit,2),
            " | Closing all ", CountMyPositions(), " positions");
      CloseAll();
      MarkCycleComplete("Basket exit after recovery");
   }
}

//+------------------------------------------------------------------+
//| Close all positions by magic                                    |
//+------------------------------------------------------------------+
void CloseAll()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t))
         if(PositionGetInteger(POSITION_MAGIC) == InpMagic)
            if(!trade.PositionClose(t))
               Print("Close failed #", t, ": ", trade.ResultRetcodeDescription());
   }
}

void MarkCycleComplete(string reason)
{
   Print("=== CYCLE COMPLETE: ", reason, " ===");
   g_cycleActive    = false;
   g_slIntroduced   = false;
   g_recoveryCount  = 0;
   g_lastEntryTime  = TimeCurrent();
   ArrayInitialize(g_recoveryFired,  false);
   ArrayInitialize(g_recoveryPrices, 0);
   // Clean up chart lines
   for(int i = 0; i < 10; i++) ObjectDelete(0, PFX + "hline_rec" + (string)i);
   ObjectDelete(0, PFX + "hline_be");
   ObjectDelete(0, PFX + "hline_tp");
   ObjectDelete(0, PFX + "hline_sl");
}

//+------------------------------------------------------------------+
//| PANEL                                                            |
//+------------------------------------------------------------------+
void DrawLabel(string name, string txt, int x, int y,
               int sz, color clr, bool bold=false)
{
   string n = PFX + name;
   if(ObjectFind(0,n) < 0) ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,      CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,   x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,   y);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,     sz);
   ObjectSetInteger(0,n,OBJPROP_COLOR,        clr);
   ObjectSetString(0, n,OBJPROP_FONT,         bold ? "Arial Bold" : "Arial");
   ObjectSetString(0, n,OBJPROP_TEXT,         txt);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,   false);
}

void DrawRect(string name, int x, int y, int w, int h, color bg, color border)
{
   string n = PFX + name;
   if(ObjectFind(0,n) < 0) ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
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

void DrawHLine(string name, double price, color clr, ENUM_LINE_STYLE style, string tip)
{
   string n = PFX + name;
   if(ObjectFind(0,n) < 0) ObjectCreate(0,n,OBJ_HLINE,0,0,price);
   ObjectSetDouble(0,n,  OBJPROP_PRICE,   price);
   ObjectSetInteger(0,n, OBJPROP_COLOR,   clr);
   ObjectSetInteger(0,n, OBJPROP_STYLE,   style);
   ObjectSetInteger(0,n, OBJPROP_WIDTH,   1);
   ObjectSetString(0,n,  OBJPROP_TOOLTIP, tip);
   ObjectSetInteger(0,n, OBJPROP_SELECTABLE, false);
}

void DeletePanel() { ObjectsDeleteAll(0, PFX); }

void UpdatePanel()
{
   int px = InpPanelX, py = InpPanelY;
   int pw = 300, lh = 17, pad = 9;
   int positions = CountMyPositions();

   if(positions == 0 && !g_cycleActive)
   {
      DrawRect("bg", px, py, pw, 36, C'18,18,28', C'50,50,70');
      DrawLabel("title", "HedgeStrike v6  |  waiting for signal", px+pad, py+11, 8, InpColorNeutral, true);
      ChartRedraw();
      return;
   }

   double avgEntry, totalLots, totalPips;
   ENUM_POSITION_TYPE dir;
   GetBasketInfo(avgEntry, totalLots, totalPips, dir);

   double pnl       = GetBasketPnL();
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double margin    = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeM     = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double dd        = (balance > 0 && pnl < 0) ? MathAbs(pnl/balance*100.0) : 0;
   double pt        = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double cur       = (dir == POSITION_TYPE_BUY) ? bid : ask;
   string dirStr    = (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL";

   // Thresholds
   double slThr  = InpTargetProfit * (InpSLTriggerPct / 100.0);
   double tpThr  = InpTargetProfit * (InpAutoTPPct    / 100.0);

   // Recovery level data
   double mults[10];
   mults[0]=InpRecoveryMult1; mults[1]=InpRecoveryMult2; mults[2]=InpRecoveryMult3;
   for(int i=3;i<10;i++) mults[i]=mults[2]*(1.0+i*0.5);

   double runAvg  = avgEntry;
   double runLots = totalLots;
   double recBE[10], recLot[10];
   for(int lvl=0; lvl<InpMaxRecoveryLevels && lvl<10; lvl++)
   {
      recLot[lvl] = NormalizeLot(InpLot1 * mults[lvl]);
      recBE[lvl]  = NewBasketBE(runAvg, runLots, g_recoveryPrices[lvl], recLot[lvl]);
      runAvg      = recBE[lvl];
      runLots    += recLot[lvl];
   }

   // Dynamic panel height
   int recRows = InpMaxRecoveryLevels * 2;
   int rows    = 14 + recRows + (g_slIntroduced ? 1 : 0);
   int totalH  = pad + rows * lh + pad;

   color borderCol = (pnl >= 0) ? C'25,85,45' : C'85,25,25';
   DrawRect("bg", px, py, pw, totalH, C'13,15,24', borderCol);

   int y = py + pad;

   // Title
   string titleStr = "HedgeStrike v6  |  " + dirStr
                   + "  |  " + (string)positions + " pos";
   DrawLabel("title", titleStr, px+pad, y, 9, InpColorNeutral, true);
   y += lh + 3;

   // Account section
   DrawLabel("s_acct", "ACCOUNT", px+pad, y, 7, C'90,90,120');
   y += lh;
   DrawLabel("equity",  "Equity      $" + DoubleToString(equity,2),   px+pad, y, 8, InpColorNeutral); y+=lh;
   DrawLabel("margin",  "Margin      $" + DoubleToString(margin,2),   px+pad, y, 8, InpColorNeutral); y+=lh;
   DrawLabel("freem",   "Free margin $" + DoubleToString(freeM,2),    px+pad, y, 8, InpColorNeutral); y+=lh;
   color ddC = (dd>5)?InpColorLoss:(dd>2)?InpColorAlert:InpColorNeutral;
   DrawLabel("dd",      "Drawdown    " + DoubleToString(dd,2)+"%",    px+pad, y, 8, ddC);             y+=lh+2;

   // Basket section
   DrawLabel("s_bask", "BASKET", px+pad, y, 7, C'90,90,120');
   y += lh;
   color pnlC  = (pnl>=0)?InpColorProfit:InpColorLoss;
   string pnlS = (pnl>=0?"+":"") + DoubleToString(pnl,2);
   string pipS = (totalPips>=0?"+":"") + DoubleToString(totalPips,1);
   DrawLabel("pnl",    "P&L         $"+pnlS+" ("+pipS+" pips)",   px+pad, y, 8, pnlC, true); y+=lh;
   DrawLabel("lots",   "Total lots  "+DoubleToString(totalLots,2), px+pad, y, 8, InpColorNeutral);    y+=lh;
   DrawLabel("be",     "Basket BE   "+DoubleToString(avgEntry,digits), px+pad, y, 8, InpColorAlert);  y+=lh;

   // Profit targets
   DrawLabel("sl_thr", "SL trigger  $"+DoubleToString(slThr,2)+" ("+DoubleToString(InpSLTriggerPct,0)+"%)",
             px+pad, y, 8, (pnl>=slThr)?InpColorProfit:InpColorNeutral); y+=lh;
   DrawLabel("tp_thr", "Auto TP     $"+DoubleToString(tpThr,2)+" ("+DoubleToString(InpAutoTPPct,0)+"%)",
             px+pad, y, 8, (pnl>=tpThr)?InpColorProfit:InpColorNeutral); y+=lh;
   if(g_slIntroduced)
   {
      DrawLabel("sl_st", "Trailing SL ACTIVE", px+pad, y, 8, InpColorProfit, true); y+=lh;
   }
   y += 2;

   // Recovery section
   DrawLabel("s_rec", "RECOVERY  (auto)", px+pad, y, 7, C'90,90,120'); y+=lh;

   for(int lvl=0; lvl<InpMaxRecoveryLevels && lvl<10; lvl++)
   {
      bool fired   = g_recoveryFired[lvl];
      bool reached = (dir==POSITION_TYPE_BUY)
                     ? (cur <= g_recoveryPrices[lvl])
                     : (cur >= g_recoveryPrices[lvl]);
      color lc = fired ? InpColorProfit : (reached ? InpColorAlert : InpColorNeutral);
      string status = fired ? "[OPEN]" : (reached ? "[NOW]" : "");
      string line1 = StringFormat("Lvl %d %s @ %s  lot %.2f",
         lvl+1, status,
         DoubleToString(g_recoveryPrices[lvl], digits),
         recLot[lvl]);
      string line2 = StringFormat("   BE->%s | need +%.1f pips",
         DoubleToString(recBE[lvl],digits),
         MathAbs((dir==POSITION_TYPE_BUY
                  ? recBE[lvl]-cur
                  : cur-recBE[lvl])/pt));
      DrawLabel("r"+IntegerToString(lvl*2),   line1, px+pad, y, 7, lc, fired); y+=lh-2;
      DrawLabel("r"+IntegerToString(lvl*2+1), line2, px+pad, y, 7, C'70,70,100');         y+=lh;
   }

   // Basket exit target
   if(g_recoveryCount > 0)
   {
      DrawLabel("bask_exit",
         "Basket exit at $"+DoubleToString(InpBasketExitProfit,2),
         px+pad, y, 8,
         (pnl>=InpBasketExitProfit)?InpColorProfit:InpColorAlert, true);
   }

   // Chart lines
   if(avgEntry > 0)
      DrawHLine("hline_be", avgEntry, InpColorAlert, STYLE_DOT,
                "Basket BE: "+DoubleToString(avgEntry,digits));

   double tpPrice = 0;
   // Approximate TP line from first position
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t))
         if(PositionGetInteger(POSITION_MAGIC)==InpMagic)
         {
            double op = PositionGetDouble(POSITION_PRICE_OPEN);
            double pv = PipValuePerLot(totalLots);
            if(pv>0)
            {
               double tpPips = tpThr / pv;
               tpPrice = (dir==POSITION_TYPE_BUY)
                         ? NormalizeDouble(op + tpPips*pt, digits)
                         : NormalizeDouble(op - tpPips*pt, digits);
            }
            break;
         }
   }
   if(tpPrice > 0)
      DrawHLine("hline_tp", tpPrice, InpColorProfit, STYLE_DASH,
                "Auto TP: $"+DoubleToString(tpThr,2));

   for(int lvl=0;lvl<InpMaxRecoveryLevels&&lvl<10;lvl++)
   {
      if(g_recoveryPrices[lvl] <= 0) continue;
      bool fired = g_recoveryFired[lvl];
      color lc   = fired ? InpColorProfit : C'80,80,160';
      DrawHLine("hline_rec"+(string)lvl, g_recoveryPrices[lvl], lc, STYLE_DASH,
                StringFormat("Recovery %d | Lot %.2f | BE->%s",
                lvl+1, recLot[lvl], DoubleToString(recBE[lvl],digits)));
   }

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Open entry                                                       |
//+------------------------------------------------------------------+
void OpenCycle(ENUM_ORDER_TYPE dir)
{
   if(!SpreadOk()) return;

   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot1   = NormalizeLot(InpLot1);
   double entry  = (dir==ORDER_TYPE_BUY) ? ask : bid;

   if(!HasEnoughMargin(dir, lot1, entry)) return;

   // Reset cycle state
   g_slIntroduced  = false;
   g_recoveryCount = 0;
   g_cycleActive   = true;
   g_lastEntryTime = TimeCurrent();
   ArrayInitialize(g_recoveryFired,  false);
   ArrayInitialize(g_recoveryPrices, 0);

   string label = (dir==ORDER_TYPE_BUY) ? "HSv6-E1-BUY" : "HSv6-E1-SELL";
   bool ok = (dir==ORDER_TYPE_BUY)
             ? trade.Buy(lot1,  _Symbol, entry, 0, 0, label)
             : trade.Sell(lot1, _Symbol, entry, 0, 0, label);

   if(!ok)
   {
      Print("ENTRY FAILED: ", trade.ResultRetcodeDescription());
      g_cycleActive = false;
      return;
   }

   g_lastWasBuy = (dir==ORDER_TYPE_BUY);
   Print("ENTRY OPEN | ", (dir==ORDER_TYPE_BUY?"BUY":"SELL"),
         " | Lot:", lot1, " @ ", entry,
         " | No SL/TP — EA watching");

   // Pre-calculate recovery trigger prices from this entry
   ENUM_POSITION_TYPE posDir = (dir==ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   CalcRecoveryTriggers(entry, posDir);
   for(int i=0;i<InpMaxRecoveryLevels&&i<10;i++)
      Print("Recovery level ", i+1, " trigger @ ", g_recoveryPrices[i]);
}

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(GetFillingMode());
   ArrayInitialize(g_recoveryFired,  false);
   ArrayInitialize(g_recoveryPrices, 0);

   Print("=== HedgeStrike EA v6.0 ===");
   Print("Profit: SL at ", InpSLTriggerPct, "% ($", DoubleToString(InpTargetProfit*(InpSLTriggerPct/100),2),
         ") | TP at ", InpAutoTPPct, "% ($", DoubleToString(InpTargetProfit*(InpAutoTPPct/100),2), ")");
   Print("Recovery: ", InpMaxRecoveryLevels, " levels x ", InpRecoverySpacePips,
         " pips | Basket exit: $", DoubleToString(InpBasketExitProfit,2));
   UpdatePanel();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { DeletePanel(); }

//+------------------------------------------------------------------+
void OnTick()
{
   int positions = CountMyPositions();

   //--- No position: wait for signal
   if(positions == 0)
   {
      if(g_cycleActive) MarkCycleComplete("All positions closed");

      if(InpRetrySeconds > 0)
         if((int)(TimeCurrent() - g_lastEntryTime) < InpRetrySeconds)
         { UpdatePanel(); return; }

      bool doBuy=false, doSell=false;
      if(InpForceDir==FORCE_BUY)            doBuy  = true;
      else if(InpForceDir==FORCE_SELL)      doSell = true;
      else if(InpForceDir==FORCE_ALTERNATE) { if(g_lastWasBuy) doSell=true; else doBuy=true; }

      // ── Wire real signal here ────────────────────────────────
      // if(InpForceDir==FORCE_OFF)
      // {
      //    doBuy  = (signalBuffer[0] == 1.0);
      //    doSell = (signalBuffer[0] == -1.0);
      // }
      // ─────────────────────────────────────────────────────────

      if(doBuy)  OpenCycle(ORDER_TYPE_BUY);
      if(doSell) OpenCycle(ORDER_TYPE_SELL);
      UpdatePanel();
      return;
   }

   //--- Trade running — full automation
   g_cycleActive = true;

   ManageProfitSL();      // introduce + trail SL once in profit
   ManageAutoTP();        // hard close at 50% target
   ManageAutoRecovery();  // open recovery positions in loss
   ManageBasketExit();    // close basket once recovery earns target

   UpdatePanel();
}

void OnChartEvent(const int id, const long &lp, const double &dp, const string &sp)
{
   if(id == CHARTEVENT_CHART_CHANGE) UpdatePanel();
}
//+------------------------------------------------------------------+
