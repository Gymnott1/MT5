//+------------------------------------------------------------------+
//|                                             seefactor_bot_v2.mq5 |
//|                    SEEFactor Hedge Strategy v2.0                 |
//|                                                                  |
//|  FULLY DYNAMIC — reads broker/symbol specs every tick:           |
//|  - PPM (money per point per lot) from tick value/size            |
//|  - Lot step, min, max from symbol info                           |
//|  - Stop level from broker                                        |
//|  - All distances in points (broker-native)                       |
//|                                                                  |
//|  STRATEGY:                                                       |
//|  Main opens at B. Hedge trigger at C. Hedge opens at C.         |
//|                                                                  |
//|  CORRECT SIZING:                                                 |
//|  We want the hedge to fully cover the main loss when price       |
//|  falls to Y. This requires hl > ml.                             |
//|  But then Path A (recovery to A) loses money on the hedge.      |
//|                                                                  |
//|  SOLUTION — TWO-PHASE HEDGE:                                     |
//|  Phase 1 (price at C): Open hedge with hl sized for Path A.     |
//|  Phase 2 (price falls past C toward Y): Trail hedge SL upward   |
//|  to lock in profit as hedge gains. When hedge SL locked at       |
//|  breakeven or above, the hedge covers the main loss regardless   |
//|  of direction.                                                   |
//|                                                                  |
//|  TRAIL LOGIC:                                                    |
//|  - Every tick, if hedge is profitable by >= TrailStep pts,       |
//|    move hedge SL to: hedge_entry - current_profit_in_pts + buffer|
//|  - This locks in profit that covers the main's unrealised loss.  |
//|  - When basket net (main+hedge) >= 0, close both.               |
//+------------------------------------------------------------------+
#property copyright "SEEFactor v2.0"
#property version   "2.00"

#include <Trade/Trade.mqh>
#define PFX "SF2_"
enum TradeSide { SideBuy=0, SideSell=1 };

//--- INPUTS -------------------------------------------------------
input group        "=== MAIN TRADE ==="
input TradeSide    InpSide      = SideBuy;
input double       InpLots      = 0.10;        // Main lots
input double       InpTpPts     = 500.0;       // TP distance from entry (points)
input double       InpSlPts     = 300.0;       // Hedge trigger C distance (points)

input group        "=== HEDGE ==="
input bool         InpHedge     = true;
// Hedge lots multiplier — hedge lots = main lots * this multiplier
// 1.0 = equal lots. Higher = more coverage on downside but less on recovery.
// Auto (0) = compute dynamically to balance both paths
input double       InpHedgeMult = 0.0;         // 0 = auto-compute

input group        "=== TRAIL STOP ON HEDGE ==="
input bool         InpTrail     = true;        // Trail hedge SL to lock profit
input double       InpTrailStep = 50.0;        // Trail every N points of hedge profit
input double       InpTrailBuf  = 20.0;        // Buffer behind trail (points)

input group        "=== BASKET EXIT ==="
// Close both when basket net >= this profit
input double       InpBasketTP  = 0.0;         // 0 = use computed Path A net
// Close both when basket net <= this loss (emergency)
input double       InpBasketSL  = 50.0;        // Emergency basket SL in USD

input group        "=== EXECUTION ==="
input bool         InpAuto      = true;
input int          InpMagic     = 20260320;
input int          InpCD        = 30;
input bool         InpCmt       = false;

input group        "=== SAFETY ==="
input bool         InpEqG       = true;
input double       InpEqL       = 500.0;

//--- SYMBOL SPECS (read dynamically) ------------------------------
struct SymbolSpecs
  {
   double ppm;        // money per point per lot
   double lot_min;
   double lot_max;
   double lot_step;
   double stop_dist;  // minimum stop distance in price
   double point;
   int    digits;
  };

SymbolSpecs g_sym;

void ReadSymbol()
  {
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_sym.ppm       = (ts>0) ? tv*(_Point/ts) : 0;
   g_sym.lot_min   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_sym.lot_max   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_sym.lot_step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(g_sym.lot_step<=0) g_sym.lot_step = g_sym.lot_min;
   long sl_lvl     = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long fr_lvl     = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   g_sym.stop_dist = (MathMax(sl_lvl,fr_lvl)+5)*_Point;
   g_sym.point     = _Point;
   g_sym.digits    = _Digits;
  }

// Floor-normalize lots (never round UP — would break constraints)
double NLfloor(double v)
  {
   if(g_sym.lot_step<=0) return MathMax(g_sym.lot_min,MathMin(g_sym.lot_max,v));
   double r = MathFloor(v/g_sym.lot_step)*g_sym.lot_step;
   return NormalizeDouble(MathMax(g_sym.lot_min,MathMin(g_sym.lot_max,r)),2);
  }

// Ceiling-normalize lots
double NLceil(double v)
  {
   if(g_sym.lot_step<=0) return MathMax(g_sym.lot_min,MathMin(g_sym.lot_max,v));
   double r = MathCeil(v/g_sym.lot_step)*g_sym.lot_step;
   return NormalizeDouble(MathMax(g_sym.lot_min,MathMin(g_sym.lot_max,r)),2);
  }

double NP(double p){return NormalizeDouble(p,g_sym.digits);}

double PP(TradeSide s,double from,double pts,bool fav)
  {
   double d=pts*g_sym.point;
   return s==SideBuy?NP(fav?from+d:from-d):NP(fav?from-d:from+d);
  }

double PNL(TradeSide s,double en,double ex,double lots)
  {
   double pts=(s==SideBuy)?(ex-en)/g_sym.point:(en-ex)/g_sym.point;
   return pts*g_sym.ppm*lots;
  }

double Ask(){return NP(SymbolInfoDouble(_Symbol,SYMBOL_ASK));}
double Bid(){return NP(SymbolInfoDouble(_Symbol,SYMBOL_BID));}
double Ref(TradeSide s){return s==SideBuy?Ask():Bid();}
double Cls(TradeSide s){return s==SideBuy?Bid():Ask();}

void SafeST(TradeSide s,double wsl,double wtp,double&osl,double&otp)
  {
   osl=NP(wsl); otp=NP(wtp);
   if(s==SideBuy)
     {
      if(osl>0) osl=NP(MathMin(osl,Bid()-g_sym.stop_dist));
      if(otp>0) otp=NP(MathMax(otp,Ask()+g_sym.stop_dist));
     }
   else
     {
      if(osl>0) osl=NP(MathMax(osl,Ask()+g_sym.stop_dist));
      if(otp>0) otp=NP(MathMin(otp,Bid()-g_sym.stop_dist));
     }
  }

string S2S(TradeSide s){return s==SideBuy?"BUY":"SELL";}
TradeSide Opp(TradeSide s){return s==SideBuy?SideSell:SideBuy;}

//--- STATE --------------------------------------------------------
CTrade g_tr;

ulong  g_mt=0;  bool   g_mp=false;
double g_me=0;  double g_ml=0;
double g_ma=0;  // A: main TP
double g_mc=0;  // C: hedge trigger

ulong  g_ht=0;  bool   g_hp=false;
double g_he=0;  double g_hl=0;
double g_htp=0; // Y: hedge TP
double g_hsl=0; // hedge SL (trailed)

// Plan
double g_Y      = 0;
double g_hl_p   = 0;
double g_nA     = 0;  // estimated net at A
double g_nY     = 0;  // estimated net at Y
double g_hl_maxA= 0;  // theoretical hl_maxA
bool   g_plan   = false;
bool   g_hfail  = false;

// Trail tracking
double g_trail_best = 0;  // best hedge PnL seen so far (for trailing)

datetime g_cd  = 0;
double   g_bal = 0;
string   g_st  = "IDLE";

//--- POSITION LOOKUP ----------------------------------------------
ulong FP(const string tag)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagic) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT),tag)>=0) return t;
     }
   return 0;
  }

bool SP(ulong&t,const string tag)
  {
   if(t>0&&PositionSelectByTicket(t)) return true;
   t=FP(tag);
   return t>0&&PositionSelectByTicket(t);
  }

double PPNL(ulong t)
  {
   if(t==0||!PositionSelectByTicket(t)) return 0;
   return PositionGetDouble(POSITION_PROFIT)
         +PositionGetDouble(POSITION_SWAP)
         +PositionGetDouble(POSITION_COMMISSION);
  }

//--- DYNAMIC PLAN COMPUTATION -------------------------------------
//
//  Reads live symbol specs every tick.
//  Computes hl and Y from actual broker lot constraints.
//
//  Strategy:
//  If InpHedgeMult == 0 (auto):
//    Compute hl_maxA = ml * e/(e+d)  [max for Path A profit]
//    Compute hl_minY = ml * (d+f)/f  [min for Path C breakeven]
//    If hl_minY <= hl_maxA: pick midpoint → both paths profit
//    Else: pick hl = hl_maxA (Path A profits, Path C reduced loss)
//         and set f (depth) = e+d (equal loss magnitude on Path C)
//  If InpHedgeMult > 0:
//    hl = ml * InpHedgeMult (user override)
//
void CalcPlan(double B,double A,double C,double ml)
  {
   g_plan=false;
   if(g_sym.ppm<=0||B<=0||A<=0||C<=0||ml<=0) return;

   double e=MathAbs(A-B);  // TP distance in price
   double d=MathAbs(B-C);  // trigger distance in price
   if(e<=0||d<=0) return;

   double hl_maxA = ml * e / (e+d);  // max hl for Path A net >= 0
   g_hl_maxA = hl_maxA;

   double hl = 0;

   if(InpHedgeMult > 0)
     {
      // User-specified multiplier
      hl = NLfloor(ml * InpHedgeMult);
     }
   else
     {
      // Auto: try to find hl that satisfies both paths
      // For Path C breakeven: hl_minY(f) = ml*(d+f)/f
      // Setting f=e+d (equal magnitude depth): hl_minY = ml*(d+e+d)/(e+d) = ml*(2d+e)/(e+d)
      double f_equal = e + d;
      double hl_minY_equal = ml * (d + f_equal) / f_equal;

      if(hl_minY_equal <= hl_maxA * 0.98)
        {
         // Both paths feasible — pick midpoint
         hl = NLfloor((hl_minY_equal + hl_maxA) / 2.0);
        }
      else
        {
         // Not feasible simultaneously — use hl_maxA * 0.85 (Path A profits, Path C reduced loss)
         hl = NLfloor(hl_maxA * 0.85);
        }
     }

   // Enforce broker minimum — if even min lots > hl_maxA, warn user
   if(hl < g_sym.lot_min) hl = g_sym.lot_min;

   // Compute depth f for Y
   // If hl > ml: can achieve Path C breakeven. Solve: ml*(d+f)/f = hl → f = ml*d/(hl-ml)
   // If hl <= ml: Path C will be negative. Use f=e+d (equal magnitude)
   double f;
   if(hl > ml * 1.001)
      f = ml * d / (hl - ml);
   else
      f = e + d;

   // Cap depth at a sensible maximum (10× the trigger distance)
   f = MathMin(f, d * 10);

   double Y = PP(InpSide, C, f/g_sym.point, false);

   double nA = PNL(InpSide,B,A,ml) + PNL(Opp(InpSide),C,A,hl);
   double nY = PNL(InpSide,B,Y,ml) + PNL(Opp(InpSide),C,Y,hl);

   g_Y    = Y;
   g_hl_p = hl;
   g_nA   = nA;
   g_nY   = nY;
   g_plan = true;

   PrintFormat("[SF2] Plan: B=%.5f A=%.5f C=%.5f  e=%.0f d=%.0f  "
               "hl=%.2f(maxA=%.3f) Y=%.5f(f=%.0f)  netA=%.2f netY=%.2f",
               B,A,C,e/g_sym.point,d/g_sym.point,
               hl,hl_maxA,Y,f/g_sym.point,nA,nY);
  }

//--- SYNC STATE ---------------------------------------------------
void Sync()
  {
   g_mp=SP(g_mt,"SF2-Main");
   g_hp=SP(g_ht,"SF2-Hedge");
   if(g_mp)
     {
      g_me=PositionGetDouble(POSITION_PRICE_OPEN);
      g_ml=PositionGetDouble(POSITION_VOLUME);
      double bt=PositionGetDouble(POSITION_TP);
      if(g_ma<=0&&bt>0) g_ma=bt;
      if(g_mc<=0) g_mc=PP(InpSide,g_me,InpSlPts,false);
     }
   if(g_hp)
     {
      g_he =PositionGetDouble(POSITION_PRICE_OPEN);
      g_hl =PositionGetDouble(POSITION_VOLUME);
      g_hsl=PositionGetDouble(POSITION_SL);
      g_htp=PositionGetDouble(POSITION_TP);
     }
  }

void ScanExist()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagic) continue;
      string c=PositionGetString(POSITION_COMMENT);
      if(StringFind(c,"SF2-Main")>=0)
        {
         g_mt=t; g_mp=true;
         g_me=PositionGetDouble(POSITION_PRICE_OPEN);
         g_ml=PositionGetDouble(POSITION_VOLUME);
         g_ma=PositionGetDouble(POSITION_TP);
         g_mc=PP(InpSide,g_me,InpSlPts,false);
         g_st="Resumed main #"+IntegerToString((long)t);
        }
      else if(StringFind(c,"SF2-Hedge")>=0)
        {
         g_ht=t; g_hp=true;
         g_he=PositionGetDouble(POSITION_PRICE_OPEN);
         g_hl=PositionGetDouble(POSITION_VOLUME);
         g_hsl=PositionGetDouble(POSITION_SL);
         g_htp=PositionGetDouble(POSITION_TP);
         g_st="Resumed hedge #"+IntegerToString((long)t);
        }
     }
  }

//--- APPLY STOPS --------------------------------------------------
void ApplyStops()
  {
   if(!g_plan||g_Y<=0) return;
   TradeSide hs=Opp(InpSide);

   // Main: remove SL entirely when hedge is active — hedge covers downside
   // Keep TP=A
   if(SP(g_mt,"SF2-Main"))
     {
      double cur_sl=PositionGetDouble(POSITION_SL);
      double cur_tp=PositionGetDouble(POSITION_TP);
      bool sl_chg = cur_sl > 0;
      bool tp_chg = MathAbs(cur_tp-g_ma)>g_sym.point;
      if(sl_chg||tp_chg)
        {
         double sl=0.0,tp=0.0;
         SafeST(InpSide,0.0,g_ma,sl,tp);
         if(g_tr.PositionModify(g_mt,sl,tp))
            PrintFormat("[SF2] Main SL removed, TP=A=%.5f",tp);
        }
     }

   // Hedge: TP=Y, SL=0 (managed by trail logic)
   if(SP(g_ht,"SF2-Hedge"))
     {
      double cur_tp=PositionGetDouble(POSITION_TP);
      bool tp_chg=MathAbs(cur_tp-g_Y)>g_sym.point;
      if(tp_chg)
        {
         double sl=g_hsl,tp=0.0;
         SafeST(hs,sl,g_Y,sl,tp);
         if(g_tr.PositionModify(g_ht,sl,tp))
           { g_htp=tp; PrintFormat("[SF2] Hedge TP=Y=%.5f",tp); }
        }
     }
  }

//--- TRAIL HEDGE SL -----------------------------------------------
void TrailHedge()
  {
   if(!InpTrail||!g_hp||g_ht==0) return;
   if(!SP(g_ht,"SF2-Hedge")) return;

   double hedge_pnl = PPNL(g_ht);
   if(hedge_pnl <= 0) return;

   // Update best PnL seen
   if(hedge_pnl > g_trail_best) g_trail_best = hedge_pnl;

   // Only trail if best PnL >= TrailStep * PPM
   double trail_trigger = InpTrailStep * g_sym.ppm * g_hl;
   if(g_trail_best < trail_trigger) return;

   // Compute new SL price: hedge entry moved by (best_pnl - buffer) in hedge's profitable direction
   TradeSide hs = Opp(InpSide);
   double pnl_pts  = g_trail_best / (g_sym.ppm * g_hl);     // best profit in points
   double buf_pts  = InpTrailBuf;
   double lock_pts = pnl_pts - buf_pts;
   if(lock_pts <= 0) return;

   // New SL = hedge entry moved lock_pts in hedge's favorable direction
   double new_sl = PP(hs, g_he, lock_pts, true);  // favorable for hedge
   double cur_sl = PositionGetDouble(POSITION_SL);

   // Only move SL in improving direction (for Sell hedge: SL moves down = worse, so check)
   bool improved;
   if(hs==SideSell)
      improved = (new_sl < cur_sl || cur_sl == 0);  // Sell hedge SL moves down = locks more
   else
      improved = (new_sl > cur_sl || cur_sl == 0);

   if(!improved) return;

   double sl,tp;
   SafeST(hs,new_sl,g_htp,sl,tp);

   if(MathAbs(sl-cur_sl) > g_sym.point)
     {
      if(g_tr.PositionModify(g_ht,sl,tp))
        {
         g_hsl=sl;
         PrintFormat("[SF2] Hedge SL trailed to %.5f (locked %.0f pts = $%.2f)",
                     sl, lock_pts, lock_pts*g_sym.ppm*g_hl);
        }
     }
  }

//--- BASKET MONITOR -----------------------------------------------
bool CheckBasket()
  {
   if(!g_mp&&!g_hp) return false;

   double mp = g_mp ? PPNL(g_mt) : 0;
   double hp = g_hp ? PPNL(g_ht) : 0;
   double net = mp + hp;

   // Basket TP: close both when net >= target
   double btp = (InpBasketTP>0) ? InpBasketTP : MathMax(0.01, g_nA*0.9);
   if(net >= btp)
     {
      bool mm=g_mp&&SP(g_mt,"SF2-Main");
      bool mh=g_hp&&SP(g_ht,"SF2-Hedge");
      if(mm) g_tr.PositionClose(g_mt);
      if(mh) g_tr.PositionClose(g_ht);
      StartCD(StringFormat("Basket TP net=%.2f",net));
      return true;
     }

   // Emergency basket SL — only if no hedge (hedge should prevent this)
   if(!g_hp && InpBasketSL>0 && net<=-MathAbs(InpBasketSL))
     {
      if(g_mp&&SP(g_mt,"SF2-Main")) g_tr.PositionClose(g_mt);
      StartCD(StringFormat("Emergency basket SL net=%.2f",net));
      return true;
     }

   return false;
  }

//--- OPEN HEDGE ---------------------------------------------------
bool OpenHedge()
  {
   if(!InpHedge||g_hp) return false;

   // Ensure plan is ready
   if(!g_plan||g_Y<=0||g_hl_p<=0)
     {
      if(g_me>0&&g_ma>0&&g_mc>0&&g_ml>0)
         CalcPlan(g_me,g_ma,g_mc,g_ml);
     }

   // Fallback if still not ready
   if(g_Y<=0||g_hl_p<=0)
     {
      double depth=(InpTpPts+InpSlPts);
      g_Y     = PP(InpSide,g_mc,depth,false);
      g_hl_p  = g_sym.lot_min;
      PrintFormat("[SF2] Hedge fallback: hl=%.2f Y=%.5f",g_hl_p,g_Y);
     }

   TradeSide hs=Opp(InpSide);
   double sl=0.0,tp=0.0;
   SafeST(hs,0.0,g_Y,sl,tp);

   bool ok=(hs==SideBuy)?g_tr.Buy(g_hl_p,_Symbol,0.0,sl,tp,"SF2-Hedge")
                         :g_tr.Sell(g_hl_p,_Symbol,0.0,sl,tp,"SF2-Hedge");
   if(!ok)
     {
      g_hfail=true;
      g_st="HEDGE OPEN FAILED: "+g_tr.ResultRetcodeDescription();
      PrintFormat("[SF2] CRITICAL: %s",g_st);
      return false;
     }

   g_ht=g_tr.ResultOrder(); g_hp=true; g_hfail=false;
   g_trail_best=0;

   if(SP(g_ht,"SF2-Hedge"))
     {
      g_he=PositionGetDouble(POSITION_PRICE_OPEN);
      g_hl=PositionGetDouble(POSITION_VOLUME);
      g_hsl=PositionGetDouble(POSITION_SL);
      g_htp=PositionGetDouble(POSITION_TP);
     }

   g_st=StringFormat("Hedge #%d %s %.2f @ %.5f TP=Y=%.5f",
                     (long)g_ht,S2S(hs),g_hl_p,g_he,g_Y);
   PrintFormat("[SF2] %s",g_st);
   ApplyStops();
   return true;
  }

//--- PLACE MAIN ---------------------------------------------------
bool PlaceMain()
  {
   ReadSymbol(); // refresh specs before placing

   if(InpEqG&&g_bal>0)
     {
      double eq=AccountInfoDouble(ACCOUNT_EQUITY);
      if(eq<g_bal-InpEqL){g_st=StringFormat("EQ guard %.2f",eq);return false;}
     }

   double entry=Ref(InpSide);
   double A    =PP(InpSide,entry,InpTpPts,true);
   double C    =PP(InpSide,entry,InpSlPts,false);
   double lots =NLfloor(InpLots);
   if(lots<=0){g_st="Lots zero";return false;}

   // Compute plan to get initial Y for broker SL
   CalcPlan(entry,A,C,lots);
   double Y_sl = g_Y>0 ? g_Y : PP(InpSide,C,InpTpPts+InpSlPts,false);

   double sl,tp;
   SafeST(InpSide,Y_sl,A,sl,tp);

   bool ok=(InpSide==SideBuy)?g_tr.Buy(lots,_Symbol,0.0,sl,tp,"SF2-Main")
                              :g_tr.Sell(lots,_Symbol,0.0,sl,tp,"SF2-Main");
   if(!ok){g_st="Main FAILED: "+g_tr.ResultRetcodeDescription();return false;}

   g_mt=g_tr.ResultOrder(); g_mp=true; g_ml=lots;
   g_hfail=false; g_trail_best=0;

   if(SP(g_mt,"SF2-Main"))
     {
      g_me=PositionGetDouble(POSITION_PRICE_OPEN);
      g_ma=PositionGetDouble(POSITION_TP);
      g_mc=C;
     }

   g_st=StringFormat("Main #%d %s %.2f B=%.5f A=%.5f C=%.5f",
                     (long)g_mt,S2S(InpSide),lots,g_me,g_ma,g_mc);
   PrintFormat("[SF2] %s",g_st);
   PrintFormat("[SF2] Symbol specs: PPM=%.4f lot_step=%.2f lot_min=%.2f stop_dist=%.5f",
               g_sym.ppm,g_sym.lot_step,g_sym.lot_min,g_sym.stop_dist);
   return true;
  }

//--- MANAGE MAIN --------------------------------------------------
void ManageMain()
  {
   if(!g_mp) return;
   if(!SP(g_mt,"SF2-Main"))
     {
      if(g_hp&&SP(g_ht,"SF2-Hedge"))
        {
         double hp=PPNL(g_ht);
         g_tr.PositionClose(g_ht);
         StartCD(StringFormat("Main closed; hedge closed hp=%.2f",hp));
         return;
        }
      StartCD("Main closed. Done.");
      return;
     }

   if(!g_hp)
     {
      double cur=Cls(InpSide);
      bool xC=(InpSide==SideBuy)?(cur<=g_mc):(cur>=g_mc);
      if(xC||(g_hfail&&xC))
        {
         PrintFormat("[SF2] C=%.5f hit at %.5f — opening hedge MARKET",g_mc,cur);
         OpenHedge();
        }
     }
  }

//--- MANAGE HEDGE -------------------------------------------------
void ManageHedge()
  {
   if(!g_hp||g_ht==0) return;
   if(!SP(g_ht,"SF2-Hedge")) return;
   ApplyStops();
   TrailHedge();
  }

void CheckHedgeClose()
  {
   if(g_ht==0) return;
   if(SP(g_ht,"SF2-Hedge")) return;
   bool ma=g_mp&&SP(g_mt,"SF2-Main");
   if(ma)
     {
      double mp=PPNL(g_mt);
      g_tr.PositionClose(g_mt);
      StartCD(StringFormat("Hedge TP hit; main closed mp=%.2f",mp));
      return;
     }
   StartCD("Both closed. Cycle done.");
  }

//--- COOLDOWN -----------------------------------------------------
void StartCD(const string r)
  {
   g_cd=TimeCurrent()+InpCD;
   g_mp=false; g_hp=false;
   g_mt=0;     g_ht=0;
   g_me=0;     g_ml=0;     g_ma=0;     g_mc=0;
   g_he=0;     g_hl=0;     g_hsl=0;   g_htp=0;
   g_Y=0;      g_hl_p=0;   g_nA=0;    g_nY=0;
   g_plan=false; g_hfail=false; g_trail_best=0;
   g_st=r;
   PrintFormat("[SF2] CD: %s (%ds)",r,InpCD);
  }

//--- PANEL --------------------------------------------------------
void PL(int r,string t,color c,int px=10,int py=20,int lh=18)
  {
   string n=PFX+IntegerToString(r);
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,px);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,py+r*lh);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,10);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
   ObjectSetString(0,n,OBJPROP_FONT,"Consolas");
   ObjectSetString(0,n,OBJPROP_TEXT,t);
  }
void CP(int f,int t){for(int r=f;r<=t;r++) ObjectSetString(0,PFX+IntegerToString(r),OBJPROP_TEXT,"");}
color PC(double v){return v>0.0?clrLime:v<0.0?clrRed:clrSilver;}
string FM(double v,int d=2){return(v>=0?"+":"")+DoubleToString(v,d);}

void Panel()
  {
   int r=0;
   string S="------------------------------------";
   TradeSide hs=Opp(InpSide);

   PL(r++,"=== SEEFactor v2  Hedge Strategy ===",clrWhite);
   PL(r++,_Symbol+"  "+S2S(InpSide)+"  "+DoubleToString(g_mp?g_ml:InpLots,2)+" lots",clrWhite);
   PL(r++,"PPM="+DoubleToString(g_sym.ppm,4)
      +"  step="+DoubleToString(g_sym.lot_step,2)
      +"  min="+DoubleToString(g_sym.lot_min,2),clrDimGray);
   PL(r++,S,clrDimGray);

   double B=g_me>0?g_me:Ref(InpSide);
   double A=g_ma>0?g_ma:PP(InpSide,B,InpTpPts,true);
   double C=g_mc>0?g_mc:PP(InpSide,B,InpSlPts,false);
   double ml=g_ml>0?g_ml:InpLots;
   double hl=g_hl_p>0?g_hl_p:0;

   PL(r++,"LEVELS",clrWhite);
   PL(r++,"  A (TP)      : "+DoubleToString(A,g_sym.digits)
      +"  "+FM(PNL(InpSide,B,A,ml))+" (main only)",clrLime);
   PL(r++,"  B (Entry)   : "+DoubleToString(B,g_sym.digits),clrWhite);
   PL(r++,"  C (Trigger) : "+DoubleToString(C,g_sym.digits)
      +"  ("+DoubleToString(InpSlPts,0)+"pts)",clrYellow);

   if(g_Y>0)
     {
      double depth=MathAbs(g_Y-C)/g_sym.point;
      PL(r++,"  Y (HedgeTP) : "+DoubleToString(g_Y,g_sym.digits)
         +"  ("+DoubleToString(depth,0)+"pts from C)",clrOrange);
     }
   else PL(r++,"  Y (HedgeTP) : computing...",clrDimGray);

   if(hl>0)
     {
      bool feasible=(g_hl_p>g_ml*1.001);
      PL(r++,"  Hedge lots  : "+DoubleToString(hl,2)
         +"  maxA="+DoubleToString(g_hl_maxA,3)
         +(feasible?"  [Path C breakeven]":"  [Path A profit only]"),
         feasible?clrLime:clrYellow);
      PL(r++,"  Net @ A     : "+FM(g_nA)+(g_nA>=-0.01?"  OK":"  !"),PC(g_nA));
      PL(r++,"  Net @ Y     : "+FM(g_nY)+(g_nY>=-0.01?"  OK":
         "  (set InpTpPts>="+DoubleToString(InpSlPts*2,0)+" for zero)"),PC(g_nY));
     }

   PL(r++,S,clrDimGray);

   double fm=g_mp?PPNL(g_mt):0;
   double fh=g_hp?PPNL(g_ht):0;
   double basket=fm+fh;
   PL(r++,"MAIN  FLOAT  : "+FM(fm),PC(fm));
   if(g_hp)
     {
      PL(r++,"HEDGE FLOAT  : "+FM(fh),PC(fh));
      PL(r++,"BASKET       : "+FM(basket),PC(basket));
      if(InpTrail&&g_trail_best>0)
         PL(r++,"TRAIL LOCKED : "+FM(g_trail_best)+" (best hedge)",clrCyan);
     }

   PL(r++,S,clrDimGray);
   PL(r++,"OUTCOMES (projected)",clrWhite);
   PL(r++,"  Path A (->A)     : "+FM(g_nA>0?g_nA:PNL(InpSide,B,A,ml))
      +"  [main TP fires]",PC(g_nA>0?g_nA:PNL(InpSide,B,A,ml)));
   if(g_Y>0&&hl>0)
      PL(r++,"  Path C (->Y)     : "+FM(g_nY)
         +(g_nY>=-0.01?"  [hedge TP fires]":"  [reduced loss]"),PC(g_nY));
   if(InpTrail)
      PL(r++,"  Trail exit (basket>=0): active",clrCyan);

   PL(r++,S,clrDimGray);
   PL(r++,"EXECUTION",clrWhite);
   if(!InpAuto)
      PL(r++,"  Auto OFF",clrDimGray);
   else if(g_cd>0&&TimeCurrent()<g_cd)
     {
      PL(r++,"  COOLDOWN "+IntegerToString((int)(g_cd-TimeCurrent()))+"s",clrYellow);
      PL(r++,"  "+g_st,clrSilver);
     }
   else
     {
      color sc=(g_mp||g_hp)?clrLime:clrYellow;
      PL(r++,"  "+g_st,sc);
      if(g_mp)
        {
         PL(r++,"  Main #"+IntegerToString((long)g_mt)
            +" B="+DoubleToString(g_me,g_sym.digits)
            +" TP="+DoubleToString(g_ma,g_sym.digits),clrSilver);
         string sl_str=g_hp?"  Main SL=NONE (hedge active)":"  Main SL=broker default";
         PL(r++,sl_str+"  C="+DoubleToString(g_mc,g_sym.digits),clrDimGray);
        }
      if(g_hp)
        {
         PL(r++,"  Hedge #"+IntegerToString((long)g_ht)
            +" "+DoubleToString(g_hl,2)+"L @ "+DoubleToString(g_he,g_sym.digits),clrYellow);
         PL(r++,"  Hedge TP=Y="+DoubleToString(g_htp,g_sym.digits)
            +" SL="+DoubleToString(g_hsl,g_sym.digits),clrSilver);
        }
      if(g_hfail) PL(r++,"  !! HEDGE FAILED — RETRYING !!",clrRed);
     }

   CP(r,80);
  }

//--- INIT / DEINIT / TICK ----------------------------------------
int OnInit()
  {
   g_tr.SetExpertMagicNumber(InpMagic);
   g_tr.SetDeviationInPoints(10);
   ReadSymbol();
   ScanExist();
   g_bal=AccountInfoDouble(ACCOUNT_BALANCE);

   // Print startup diagnostics
   double ml=NLfloor(InpLots);
   double e=InpTpPts*g_sym.point, d=InpSlPts*g_sym.point;
   double hl_maxA=ml*e/(e+d);
   double hl_minY_equal=ml*(d+(e+d))/(e+d);
   bool feasible=(hl_minY_equal<=hl_maxA);

   PrintFormat("[SF2] ===== STARTUP =====");
   PrintFormat("[SF2] Symbol=%s PPM=%.4f Point=%.5f Digits=%d",
               _Symbol,g_sym.ppm,g_sym.point,g_sym.digits);
   PrintFormat("[SF2] Lot: min=%.2f max=%.2f step=%.2f",
               g_sym.lot_min,g_sym.lot_max,g_sym.lot_step);
   PrintFormat("[SF2] StopDist=%.5f (%.0f pts)",
               g_sym.stop_dist,g_sym.stop_dist/g_sym.point);
   PrintFormat("[SF2] TP=%.0f SL=%.0f  hl_maxA=%.3f hl_minY=%.3f  %s",
               InpTpPts,InpSlPts,hl_maxA,hl_minY_equal,
               feasible?"BOTH PATHS PROFIT":"PATH C reduced loss — increase TP to "+
               DoubleToString(InpSlPts*2+100,0)+"pts");
   PrintFormat("[SF2] Balance=%.2f EqGuard=%.2f",g_bal,InpEqL);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   for(int r=0;r<=80;r++) ObjectDelete(0,PFX+IntegerToString(r));
   Comment("");
  }

void OnTick()
  {
   ReadSymbol(); // refresh broker specs every tick
   Sync();
   if(g_cd>0&&TimeCurrent()>=g_cd) g_cd=0;

   // Compute plan every tick while main is open
   if(g_mp&&g_me>0&&g_ma>0&&g_mc>0&&g_ml>0)
      CalcPlan(g_me,g_ma,g_mc,g_ml);

   if(InpAuto)
     {
      if(!CheckBasket())
        {
         if(g_cd==0)
           {
            if(!g_mp&&!g_hp) PlaceMain();
            else
              {
               ManageMain();
               if(g_hp) { ManageHedge(); CheckHedgeClose(); }
              }
           }
         else if(g_mp||g_hp)
           {
            ManageMain();
            if(g_hp) { ManageHedge(); CheckHedgeClose(); }
           }
        }
     }

   Panel();
   Comment(InpCmt?"SF2|"+g_st:"");
  }
//+------------------------------------------------------------------+