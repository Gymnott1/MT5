//+------------------------------------------------------------------+
//|                                                 newtesthedge.mq5 |
//|                   Asymmetric Hedge + Dynamic P3 Rescue EA        |
//+------------------------------------------------------------------+
#property copyright "2026"
#property version   "3.00"

input double InpLotHeavy          = 0.1;
input double InpLotLight          = 0.05;
input double InpExitNoHedge       = 5.0;   // $ exit — no P3
input double InpExitWithHedge     = 3.0;   // $ exit — with P3
input double InpTriggerLossFactor = 0.5;   // P3 fires when loss = X * spreadCost
input int    InpMagic             = 20260001;

enum HedgeState { STATE_IDLE, STATE_PHASE1, STATE_PHASE2 };
HedgeState g_state = STATE_IDLE;

//--- We track positions by magic+comment scan, NOT by ticket
//--- because res.order can be unreliable on hedging accounts
double g_pointVal    = 0.0;
double g_spreadCost  = 0.0;
double g_triggerLoss = 0.0;
double g_entryAsk    = 0.0;
double g_entryBid    = 0.0;
double g_p3Lots      = 0.0;

//--- Entry guard: prevents re-entry while already trying to open
bool   g_opening     = false;

//+------------------------------------------------------------------+
int OnInit()
{
   //--- Close any orphan positions from previous EA runs
   CloseAllMagic();
   g_state   = STATE_IDLE;
   g_opening = false;

   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_pointVal = (tickSize > 0) ? tickVal / tickSize * _Point : 0;

   if(g_pointVal <= 0)
   {
      Print("ERROR: Cannot calculate point value.");
      return INIT_FAILED;
   }
   Print("=== EA v3 Ready. PointVal=", DoubleToString(g_pointVal,6),
         " Magic=", InpMagic);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { g_opening = false; }

//+------------------------------------------------------------------+
void OnTick()
{
   if(g_opening) return; // hard guard — never re-enter during open sequence

   switch(g_state)
   {
      case STATE_IDLE:   HandleIdle();   break;
      case STATE_PHASE1: HandlePhase1(); break;
      case STATE_PHASE2: HandlePhase2(); break;
   }
}

//+------------------------------------------------------------------+
//| Find a position opened by this EA by its comment tag            |
//+------------------------------------------------------------------+
ulong FindPositionByComment(string tag)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_COMMENT) == tag) return ticket;
   }
   return 0;
}

bool PositionLiveByComment(string tag)
{
   return FindPositionByComment(tag) != 0;
}

double ProfitByComment(string tag)
{
   ulong ticket = FindPositionByComment(tag);
   if(ticket == 0) return 0.0;
   PositionSelectByTicket(ticket);
   return PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
}

//+------------------------------------------------------------------+
//| IDLE — open A + B once, then lock state                         |
//+------------------------------------------------------------------+
void HandleIdle()
{
   //--- Safety: if somehow positions already exist, recover state
   bool aExists = PositionLiveByComment("HedgeA");
   bool bExists = PositionLiveByComment("HedgeB");
   if(aExists && bExists)  { g_state = STATE_PHASE1; return; }
   if(aExists || bExists)  { CloseAllMagic(); return; } // partial — clean up

   g_opening = true; // LOCK — prevents any re-entry

   g_entryAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   g_entryBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double liveSpread = g_entryAsk - g_entryBid;
   double valPerPt   = g_pointVal / _Point;
   g_spreadCost  = liveSpread * valPerPt * (InpLotHeavy + InpLotLight) * 2.0;
   g_triggerLoss = MathMax(g_spreadCost * InpTriggerLossFactor, 1.0);

   //--- Open A
   bool okA = SendOrder(ORDER_TYPE_BUY, InpLotHeavy, g_entryAsk, "HedgeA");
   if(!okA)
   {
      Print("Failed A. Aborting.");
      g_opening = false;
      return;
   }

   //--- Open B
   bool okB = SendOrder(ORDER_TYPE_SELL, InpLotLight, g_entryBid, "HedgeB");
   if(!okB)
   {
      Print("Failed B. Closing A.");
      ulong tA = FindPositionByComment("HedgeA");
      if(tA != 0) CloseByTicket(tA);
      g_opening = false;
      return;
   }

   //--- Both open — advance state
   g_state   = STATE_PHASE1;
   g_opening = false;

   double netPerPtUp = (InpLotHeavy - InpLotLight) * valPerPt;
   double ptsUp = (netPerPtUp > 0) ? (InpExitNoHedge + g_spreadCost) / netPerPtUp : 0;

   Print("=== Phase 1 Open. Spread=$", DoubleToString(g_spreadCost,4),
         " P3Trigger=$-", DoubleToString(g_triggerLoss,2),
         " NeedUp=", DoubleToString(ptsUp,_Digits), "pts for $", InpExitNoHedge);
}

//+------------------------------------------------------------------+
//| PHASE 1                                                          |
//+------------------------------------------------------------------+
void HandlePhase1()
{
   bool aLive = PositionLiveByComment("HedgeA");
   bool bLive = PositionLiveByComment("HedgeB");

   if(!aLive || !bLive)
   {
      Print("WARNING: Position closed externally. Resetting.");
      CloseAllMagic();
      g_state = STATE_IDLE;
      return;
   }

   double profitA = ProfitByComment("HedgeA");
   double profitB = ProfitByComment("HedgeB");
   double net     = profitA + profitB;

   if(net >= InpExitNoHedge)
   {
      Print("Phase 1 exit. Net=$", DoubleToString(net,2));
      CloseAllMagic();
      g_state = STATE_IDLE;
      return;
   }

   if(net <= -g_triggerLoss)
   {
      Print("P3 triggered. Net=$", DoubleToString(net,2));
      OpenP3(profitA, profitB);
   }
}

//+------------------------------------------------------------------+
//| Open P3 — dynamic lot, rescue sell                              |
//+------------------------------------------------------------------+
void OpenP3(double profitA, double profitB)
{
   if(g_opening) return;
   g_opening = true;

   double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double liveSpread = ask - bid;
   double valPerPt   = g_pointVal / _Point;

   double currentNet  = profitA + profitB;
   double needed      = InpExitWithHedge - currentNet;
   double reversalDist = MathMax(liveSpread * 2.0, 10.0 * _Point);

   //--- Initial L3 estimate
   double l3Calc = needed / (reversalDist / _Point * valPerPt);
   double l3Min  = InpLotHeavy; // sells must dominate buys
   double l3Raw  = MathMax(l3Calc, l3Min);

   //--- Adjust for P3's own spread cost
   double p3Spread = liveSpread * valPerPt * l3Raw * 2.0;
   l3Raw = MathMax((needed + p3Spread) / (reversalDist / _Point * valPerPt), l3Min);

   //--- Snap to broker rules
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   g_p3Lots = NormalizeDouble(
      MathMax(MathMin(MathCeil(l3Raw / stepLot) * stepLot, maxLot), minLot), 2);

   bool ok = SendOrder(ORDER_TYPE_SELL, g_p3Lots, bid, "HedgeP3");
   if(!ok)
   {
      Print("CRITICAL: P3 open failed. l3Lots=", g_p3Lots);
      g_opening = false;
      return;
   }

   g_state   = STATE_PHASE2;
   g_opening = false;

   Print("=== Phase 2 Open. L3=", g_p3Lots,
         " CurrentNet=$", DoubleToString(currentNet,2),
         " Needed=$", DoubleToString(needed,2),
         " Exit when net>=$", InpExitWithHedge);
}

//+------------------------------------------------------------------+
//| PHASE 2                                                          |
//+------------------------------------------------------------------+
void HandlePhase2()
{
   bool aLive  = PositionLiveByComment("HedgeA");
   bool bLive  = PositionLiveByComment("HedgeB");
   bool p3Live = PositionLiveByComment("HedgeP3");

   if(!aLive || !bLive || !p3Live)
   {
      Print("WARNING: Position closed externally in Phase 2. Resetting.");
      CloseAllMagic();
      g_state = STATE_IDLE;
      return;
   }

   double profitA  = ProfitByComment("HedgeA");
   double profitB  = ProfitByComment("HedgeB");
   double profitP3 = ProfitByComment("HedgeP3");
   double net      = profitA + profitB + profitP3;

   if(net >= InpExitWithHedge)
   {
      Print("=== Phase 2 Exit. Net=$", DoubleToString(net,2),
            " A=$", DoubleToString(profitA,2),
            " B=$", DoubleToString(profitB,2),
            " P3=$", DoubleToString(profitP3,2));
      CloseAllMagic();
      g_state = STATE_IDLE;
   }
}

//+------------------------------------------------------------------+
//| UTILITIES                                                        |
//+------------------------------------------------------------------+
bool SendOrder(ENUM_ORDER_TYPE type, double lots, double price, string comment)
{
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.volume       = lots;
   req.type         = type;
   req.price        = price;
   req.deviation    = 30;
   req.magic        = InpMagic;
   req.comment      = comment;
   req.type_filling = ORDER_FILLING_FOK;

   if(!OrderSend(req, res))
   {
      Print("OrderSend failed: ", res.retcode, " ", res.comment,
            " [", comment, "] lots=", lots);
      return false;
   }

   //--- Verify the position actually appeared (most reliable check)
   Sleep(200);
   if(!PositionLiveByComment(comment))
   {
      Print("Order accepted but position not found: ", comment,
            " retcode=", res.retcode);
      return false;
   }
   return true;
}

void CloseByTicket(ulong ticket)
{
   bool found = false;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(PositionGetTicket(i) == ticket) { found = true; break; }
   if(!found || !PositionSelectByTicket(ticket)) return;

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.volume       = PositionGetDouble(POSITION_VOLUME);
   req.deviation    = 30;
   req.magic        = InpMagic;
   req.type_filling = ORDER_FILLING_FOK;

   if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
   { req.type = ORDER_TYPE_SELL; req.price = SymbolInfoDouble(_Symbol, SYMBOL_BID); }
   else
   { req.type = ORDER_TYPE_BUY;  req.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK); }

   if(!OrderSend(req, res))
      Print("CloseByTicket failed: ", res.retcode, " ticket=", ticket);
}

void CloseAllMagic()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
         if((int)PositionGetInteger(POSITION_MAGIC) == InpMagic)
            CloseByTicket(ticket);
   }
}
//+------------------------------------------------------------------+