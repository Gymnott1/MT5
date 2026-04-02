//+------------------------------------------------------------------+
//|                                                    seefactor.mq5 |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property indicator_chart_window

#define SF_PANEL_PREFIX "SF_PANEL_"

enum TradeSide
  {
   SideBuy = 0,
   SideSell = 1
  };

input TradeSide InpMainSide                = SideBuy;
input double    InpStakeLots               = 0.10;
input bool      InpDynamicFromMarket       = true;
input double    InpEntryPrice              = 0.0;
input double    InpTakeProfit              = 0.0;
input double    InpStopLoss                = 0.0;
input double    InpMainTpPoints            = 500.0;
input double    InpMainSlPoints            = 300.0;

input bool      InpUseHedge                = true;
input double    InpHedgeLotsRatio          = 0.5;     // hedge lots = stake x ratio (auto-scales with any stake)
input double    InpHedgeEntryPrice         = 0.0;
input double    InpHedgeTakeProfit         = 0.0;
input double    InpHedgeStopLoss           = 0.0;
input double    InpHedgeTpPoints           = 300.0;
input double    InpHedgeSlPoints           = 250.0;

input double    InpRecoveryProfitPct       = 20.0;    // recovery target = this % of main TP profit (scales with market + stake)
input double    InpRecoveryDistancePoints  = 300.0;

input bool      InpAutoBestHedge           = true;
input double    InpBestHedgeTpPoints       = 300.0;   // must be > min TP distance shown on panel

input bool      InpShowCommentText         = false;
input double    InpSimBalance              = 100.0;

void SetPanelLine(const int row,
            const string text,
            const color text_color,
            const int x = 10,
            const int y = 20,
            const int line_height = 18)
  {
  const string obj_name = SF_PANEL_PREFIX + IntegerToString(row);

  if(ObjectFind(0, obj_name) < 0)
    ObjectCreate(0, obj_name, OBJ_LABEL, 0, 0, 0);

  ObjectSetInteger(0, obj_name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
  ObjectSetInteger(0, obj_name, OBJPROP_XDISTANCE, x);
  ObjectSetInteger(0, obj_name, OBJPROP_YDISTANCE, y + (row * line_height));
  ObjectSetInteger(0, obj_name, OBJPROP_COLOR, text_color);
  ObjectSetInteger(0, obj_name, OBJPROP_FONTSIZE, 10);
  ObjectSetInteger(0, obj_name, OBJPROP_SELECTABLE, false);
  ObjectSetInteger(0, obj_name, OBJPROP_HIDDEN, true);
  ObjectSetString(0, obj_name, OBJPROP_FONT, "Consolas");
  ObjectSetString(0, obj_name, OBJPROP_TEXT, text);
  }

void ClearPanelLines(const int from_row, const int to_row)
  {
  for(int row = from_row; row <= to_row; row++)
    {
    const string obj_name = SF_PANEL_PREFIX + IntegerToString(row);
    if(ObjectFind(0, obj_name) >= 0)
      ObjectSetString(0, obj_name, OBJPROP_TEXT, "");
    }
  }

color PnlColor(const double pnl)
  {
  if(pnl > 0.0)
    return clrLime;
  if(pnl < 0.0)
    return clrRed;
  return clrSilver;
  }

double MoneyPerPointPerLot()
  {
   const double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tick_size <= 0.0)
      return 0.0;

   return tick_value * (_Point / tick_size);
  }

double NormalizePrice(const double price)
  {
   return NormalizeDouble(price, _Digits);
  }

double NormalizeLots(const double lots)
  {
   const double lot_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double lot_max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lot_step <= 0.0)
      return MathMax(lot_min, MathMin(lot_max, lots));

   double normalized = MathRound(lots / lot_step) * lot_step;
   normalized = MathMax(lot_min, MathMin(lot_max, normalized));
   return NormalizeDouble(normalized, 2);
  }

double CurrentReferencePrice(const TradeSide side)
  {
   if(side == SideBuy)
      return NormalizePrice(SymbolInfoDouble(_Symbol, SYMBOL_ASK));

   return NormalizePrice(SymbolInfoDouble(_Symbol, SYMBOL_BID));
  }

double CurrentClosePrice(const TradeSide side)
  {
   if(side == SideBuy)
      return NormalizePrice(SymbolInfoDouble(_Symbol, SYMBOL_BID));

   return NormalizePrice(SymbolInfoDouble(_Symbol, SYMBOL_ASK));
  }

double PriceByPoints(const TradeSide side,
              const double entry_price,
              const double distance_points,
              const bool favorable_direction)
  {
  const double delta = distance_points * _Point;

  if(side == SideBuy)
    return NormalizePrice(favorable_direction ? (entry_price + delta) : (entry_price - delta));

  return NormalizePrice(favorable_direction ? (entry_price - delta) : (entry_price + delta));
  }

double TradePnlMoney(const TradeSide side,
                     const double entry_price,
                     const double exit_price,
                     const double lots)
  {
   const double signed_points = (side == SideBuy)
                                ? (exit_price - entry_price) / _Point
                                : (entry_price - exit_price) / _Point;

   return signed_points * MoneyPerPointPerLot() * lots;
  }

double SafePrice(const double input_price, const double fallback)
  {
   if(input_price > 0.0)
      return NormalizePrice(input_price);

   return NormalizePrice(fallback);
  }

string SideToText(const TradeSide side)
  {
   return (side == SideBuy) ? "BUY" : "SELL";
  }

string BuildScenarioReport()
  {
   int row = 0;

   const double point_money = MoneyPerPointPerLot();
   if(point_money <= 0.0)
     {
      SetPanelLine(row++, "SEEFactors | Hedge Visualizer", clrWhite);
      SetPanelLine(row++, "Cannot calculate: invalid symbol tick settings.", clrRed);
      ClearPanelLines(row, 40);
      return "Cannot calculate: invalid symbol tick settings.";
     }

   const TradeSide main_side = InpMainSide;
   const TradeSide hedge_side = (main_side == SideBuy) ? SideSell : SideBuy;

  const double live_entry = CurrentReferencePrice(main_side);
  const double main_entry = InpDynamicFromMarket ? live_entry : SafePrice(InpEntryPrice, live_entry);

  double main_tp = 0.0;
  double main_sl = 0.0;
  if(InpDynamicFromMarket)
    {
    if(InpMainTpPoints <= 0.0 || InpMainSlPoints <= 0.0)
        {
         SetPanelLine(row++, "SEEFactors | Hedge Visualizer", clrWhite);
         SetPanelLine(row++, "Set dynamic main TP/SL points > 0.", clrRed);
         ClearPanelLines(row, 40);
         return "Set dynamic main TP/SL points > 0.";
        }

    main_tp = PriceByPoints(main_side, main_entry, InpMainTpPoints, true);
    main_sl = PriceByPoints(main_side, main_entry, InpMainSlPoints, false);
    }
  else
    {
    main_tp = SafePrice(InpTakeProfit, 0.0);
    main_sl = SafePrice(InpStopLoss, 0.0);

    if(main_tp <= 0.0 || main_sl <= 0.0)
      {
      SetPanelLine(row++, "SEEFactors | Hedge Visualizer", clrWhite);
      SetPanelLine(row++, "Set main TP and SL prices to visualize outcomes.", clrRed);
      ClearPanelLines(row, 40);
      return "Set main TP and SL prices to visualize outcomes.";
      }
    }

   if(InpStakeLots <= 0.0)
    {
    SetPanelLine(row++, "SEEFactors | Hedge Visualizer", clrWhite);
    SetPanelLine(row++, "Stake lots must be > 0.", clrRed);
    ClearPanelLines(row, 40);
    return "Stake lots must be > 0.";
    }

   const double main_tp_money = TradePnlMoney(main_side, main_entry, main_tp, InpStakeLots);
   const double main_sl_money = TradePnlMoney(main_side, main_entry, main_sl, InpStakeLots);

   double hedge_entry = 0.0;
   double hedge_tp_money = 0.0;
   double hedge_sl_money = 0.0;
   double hedge_at_main_sl_money = 0.0;

   const double hedge_manual_lots = NormalizeLots(InpStakeLots * InpHedgeLotsRatio);

   if(InpUseHedge && InpHedgeLotsRatio > 0.0)
     {
      // Hedge opens exactly when main SL is hit — always in sync regardless of market or stake
      hedge_entry = InpDynamicFromMarket ? main_sl : SafePrice(InpHedgeEntryPrice, main_sl);
      hedge_at_main_sl_money = TradePnlMoney(hedge_side, hedge_entry, main_sl, hedge_manual_lots);

      if(InpDynamicFromMarket && InpHedgeTpPoints > 0.0)
        {
         const double hedge_tp = PriceByPoints(hedge_side, hedge_entry, InpHedgeTpPoints, true);
         hedge_tp_money = TradePnlMoney(hedge_side, hedge_entry, hedge_tp, hedge_manual_lots);
        }
      else if(InpHedgeTakeProfit > 0.0)
         hedge_tp_money = TradePnlMoney(hedge_side, hedge_entry, NormalizePrice(InpHedgeTakeProfit), hedge_manual_lots);

      if(InpDynamicFromMarket && InpHedgeSlPoints > 0.0)
        {
         const double hedge_sl = PriceByPoints(hedge_side, hedge_entry, InpHedgeSlPoints, false);
         hedge_sl_money = TradePnlMoney(hedge_side, hedge_entry, hedge_sl, hedge_manual_lots);
        }
      else if(InpHedgeStopLoss > 0.0)
         hedge_sl_money = TradePnlMoney(hedge_side, hedge_entry, NormalizePrice(InpHedgeStopLoss), hedge_manual_lots);
     }

   const double net_loss_scenario = main_sl_money + hedge_at_main_sl_money;
   // Recovery target scales with stake + market: % of what the main TP would have earned
   const double recovery_profit_target = main_tp_money * (InpRecoveryProfitPct / 100.0);

   double required_recovery_lots = 0.0;
   double recovery_money_needed = 0.0;
   if(net_loss_scenario < 0.0 && InpRecoveryDistancePoints > 0.0)
     {
      recovery_money_needed = MathAbs(net_loss_scenario) + MathMax(0.0, recovery_profit_target);
      required_recovery_lots = recovery_money_needed / (InpRecoveryDistancePoints * point_money);
     }

  double best_hedge_trigger   = 0.0;
  double best_hedge_be_price  = 0.0;
  double best_hedge_tp        = 0.0;
  double best_hedge_lots      = 0.0;
  double best_net_if_be       = 0.0;
  double best_net_if_tp       = 0.0;
  double hedge_pnl_per_lot_tp = 0.0;
  double be_points_needed     = 0.0;

  bool best_hedge_valid = false;
  if(InpAutoBestHedge)
    {
    // Trigger = main_sl — always locked in sync with stake and market
    best_hedge_trigger = main_sl;
    const double main_loss_at_trigger = main_sl_money;

    if(InpBestHedgeTpPoints > 0.0)
      {
      best_hedge_tp        = PriceByPoints(hedge_side, best_hedge_trigger, InpBestHedgeTpPoints, true);
      hedge_pnl_per_lot_tp = TradePnlMoney(hedge_side, best_hedge_trigger, best_hedge_tp, 1.0);

      if(hedge_pnl_per_lot_tp > 0.0)
        {
        // lots sized so hedge TP covers loss + recovery_profit_target (both scale with market + stake)
        const double money_needed = MathAbs(MathMin(0.0, main_loss_at_trigger)) + MathMax(0.0, recovery_profit_target);
        best_hedge_lots = NormalizeLots(money_needed / hedge_pnl_per_lot_tp);

        if(best_hedge_lots > 0.0)
          {
          be_points_needed    = MathAbs(main_loss_at_trigger) / (best_hedge_lots * point_money);
          best_hedge_be_price = PriceByPoints(hedge_side, best_hedge_trigger, be_points_needed, true);

          best_net_if_tp = main_loss_at_trigger + TradePnlMoney(hedge_side, best_hedge_trigger, best_hedge_tp, best_hedge_lots);
          best_net_if_be = main_loss_at_trigger + TradePnlMoney(hedge_side, best_hedge_trigger, best_hedge_be_price, best_hedge_lots);
          best_hedge_valid = true;
          }
        }
      }
    }

   string report = "SEEFactors | Hedge Scenario Visualizer\n";
   report += "Symbol: " + _Symbol + " | Main Side: " + SideToText(main_side) + "\n";
   report += "Stake: " + DoubleToString(InpStakeLots, 2) + " lots\n";
   report += "Entry mode: " + (InpDynamicFromMarket ? "dynamic market" : ((InpEntryPrice > 0.0) ? "manual" : "current market")) + "\n";

   if(InpDynamicFromMarket)
     {
      report += "Dynamic points - Main TP/SL: " + DoubleToString(InpMainTpPoints, 0)
                + " / " + DoubleToString(InpMainSlPoints, 0) + "\n";
              report += "Dynamic points - Hedge TP/SL: " + DoubleToString(InpHedgeTpPoints, 0)
                    + " / " + DoubleToString(InpHedgeSlPoints, 0)
                    + "  |  Hedge ratio: " + DoubleToString(InpHedgeLotsRatio * 100.0, 0) + "% of stake\n";
     }

   report += "Main Entry/TP/SL: " + DoubleToString(main_entry, _Digits) + " / "
             + DoubleToString(main_tp, _Digits) + " / " + DoubleToString(main_sl, _Digits) + "\n";
   report += "Main @TP: " + DoubleToString(main_tp_money, 2) + " | Main @SL: " + DoubleToString(main_sl_money, 2) + "\n";

   if(InpUseHedge && InpHedgeLotsRatio > 0.0)
     {
      report += "Hedge Side: " + SideToText(hedge_side) + " | Hedge Lots: " + DoubleToString(hedge_manual_lots, 2) + " (" + DoubleToString(InpHedgeLotsRatio * 100.0, 0) + "% stake)\n";
      report += "Hedge Entry: " + DoubleToString(hedge_entry, _Digits)
                + " | Hedge @MainSL: " + DoubleToString(hedge_at_main_sl_money, 2) + "\n";

      if(InpHedgeTakeProfit > 0.0)
         report += "Hedge standalone TP PnL: " + DoubleToString(hedge_tp_money, 2) + "\n";

      if(InpHedgeStopLoss > 0.0)
         report += "Hedge standalone SL PnL: " + DoubleToString(hedge_sl_money, 2) + "\n";
     }
   else
     {
      report += "Hedge: disabled\n";
     }

   report += "Net at main loss point (main SL + hedge effect): " + DoubleToString(net_loss_scenario, 2) + "\n";

   if(net_loss_scenario < 0.0)
     {
      report += "Recovery target: recover " + DoubleToString(recovery_money_needed, 2)
                + " over " + DoubleToString(InpRecoveryDistancePoints, 0)
                + " points => required lots: " + DoubleToString(required_recovery_lots, 2);
     }
   else
     {
      report += "Loss already covered by hedge at main SL scenario.";
     }

   report += "\n\nAUTO BEST HEDGE (opposite direction)\n";
   if(!InpAutoBestHedge)
     {
      report += "Auto best hedge: disabled.";
     }
   else if(!best_hedge_valid)
     {
      report += "Auto hedge unavailable: check TP/SL points and target settings.";
     }
   else
     {
      report += "Hedge Side: " + SideToText(hedge_side)
                + " | Trigger: " + DoubleToString(best_hedge_trigger, _Digits) + "\n";
      report += "Hedge BE target: " + DoubleToString(best_hedge_be_price, _Digits)
                + " | Full TP: " + DoubleToString(best_hedge_tp, _Digits) + "\n";
      report += "Suggested Hedge Lots: " + DoubleToString(best_hedge_lots, 2)
                + " (to recover loss + target)\n";
      report += "Net @ BE target: " + DoubleToString(best_net_if_be, 2)
                + " | Net @ full TP: " + DoubleToString(best_net_if_tp, 2);
     }

   const double live_close   = CurrentClosePrice(main_side);
   const double floating_pnl  = TradePnlMoney(main_side, main_entry, live_close, InpStakeLots);
   const string sep            = "------------------------------------";

   // ── Header ─────────────────────────────────────────────
   SetPanelLine(row++, "=== SEEFactors  Hedge Visualizer ===", clrWhite);
   SetPanelLine(row++, _Symbol + "  " + SideToText(main_side) + "  " + DoubleToString(InpStakeLots, 2) + " lots", clrWhite);
   SetPanelLine(row++, "Live price : " + DoubleToString(live_close, _Digits) + "   Entry: " + DoubleToString(main_entry, _Digits), clrSilver);

   // ── Live floating PnL ────────────────────────────────────
   SetPanelLine(row++, "FLOATING PnL : " + (floating_pnl >= 0 ? "+" : "") + DoubleToString(floating_pnl, 2), PnlColor(floating_pnl));
   SetPanelLine(row++, sep, clrDimGray);

   // ── Main trade scenario ──────────────────────────────────
   SetPanelLine(row++, "MAIN TRADE", clrWhite);
   SetPanelLine(row++, "  TP " + DoubleToString(main_tp, _Digits) + "  =>  " + (main_tp_money >= 0 ? "+" : "") + DoubleToString(main_tp_money, 2), PnlColor(main_tp_money));
   SetPanelLine(row++, "  SL " + DoubleToString(main_sl, _Digits) + "  =>  " + DoubleToString(main_sl_money, 2), PnlColor(main_sl_money));
   SetPanelLine(row++, sep, clrDimGray);

   // ── Manual / dynamic hedge block ─────────────────────────
   SetPanelLine(row++, "HEDGE  (" + SideToText(hedge_side) + ")", clrWhite);
   if(InpUseHedge && InpHedgeLotsRatio > 0.0)
     {
      SetPanelLine(row++, "  Entry : " + DoubleToString(hedge_entry, _Digits) + "   Lots: " + DoubleToString(hedge_manual_lots, 2) + " (" + DoubleToString(InpHedgeLotsRatio * 100.0, 0) + "% of stake)", clrSilver);
      SetPanelLine(row++, "  @ Main-SL : " + (hedge_at_main_sl_money >= 0 ? "+" : "") + DoubleToString(hedge_at_main_sl_money, 2), PnlColor(hedge_at_main_sl_money));

      if(InpHedgeTakeProfit > 0.0 || (InpDynamicFromMarket && InpHedgeTpPoints > 0.0))
         SetPanelLine(row++, "  Hedge TP  : +" + DoubleToString(hedge_tp_money, 2), PnlColor(hedge_tp_money));

      if(InpHedgeStopLoss > 0.0 || (InpDynamicFromMarket && InpHedgeSlPoints > 0.0))
         SetPanelLine(row++, "  Hedge SL  : " + DoubleToString(hedge_sl_money, 2), PnlColor(hedge_sl_money));

      SetPanelLine(row++, "  Net (main SL + hedge) : " + (net_loss_scenario >= 0 ? "+" : "") + DoubleToString(net_loss_scenario, 2), PnlColor(net_loss_scenario));
     }
   else
     {
      SetPanelLine(row++, "  Hedge disabled", clrDimGray);
     }

   if(net_loss_scenario < 0.0)
      SetPanelLine(row++, "  Recovery lots needed : " + DoubleToString(required_recovery_lots, 2), clrYellow);
   SetPanelLine(row++, sep, clrDimGray);

   // ── Auto best hedge ──────────────────────────────────────
   SetPanelLine(row++, "AUTO BEST HEDGE  (" + SideToText(hedge_side) + ")", clrWhite);
   if(!InpAutoBestHedge)
      SetPanelLine(row++, "  Disabled", clrDimGray);
   else if(!best_hedge_valid)
      SetPanelLine(row++, "  Unavailable - check points/targets", clrRed);
   else
     {
      SetPanelLine(row++, "  Trigger      : " + DoubleToString(best_hedge_trigger, _Digits), clrSilver);
      SetPanelLine(row++, "  BE  target   : " + DoubleToString(best_hedge_be_price, _Digits) + "  (net = 0)", clrYellow);
      SetPanelLine(row++, "  Full target  : " + DoubleToString(best_hedge_tp, _Digits) + "  (+profit)", clrSilver);
      SetPanelLine(row++, "  Lots         : " + DoubleToString(best_hedge_lots, 2) + "  (" + DoubleToString(InpRecoveryProfitPct, 0) + "% of main TP)", clrYellow);
      if(InpBestHedgeTpPoints <= be_points_needed)
        SetPanelLine(row++, "  !! TP too tight! Min needed: " + DoubleToString(be_points_needed, 0) + " pts  -- widen InpBestHedgeTpPoints", clrRed);
      else
        SetPanelLine(row++, "  Min TP dist : " + DoubleToString(be_points_needed, 0) + " pts  (" + DoubleToString(InpBestHedgeTpPoints - be_points_needed, 0) + " pts buffer OK)", clrLime);
      SetPanelLine(row++, "  Net @ BE target  : " + (best_net_if_be >= 0 ? "+" : "") + DoubleToString(best_net_if_be, 2), PnlColor(best_net_if_be));
      SetPanelLine(row++, "  Net @ full target: +" + DoubleToString(best_net_if_tp, 2), PnlColor(best_net_if_tp));
     }
   SetPanelLine(row++, sep, clrDimGray);

   // ── Scenario simulator ─────────────────────────────────
   SetPanelLine(row++, "SCENARIO SIMULATOR  (start: $" + DoubleToString(InpSimBalance, 2) + ")", clrWhite);

   // Scale all PnL figures to the simulation balance
   // Actual PnL was computed for InpStakeLots at real tick value.
   // For display we show account = balance + PnL (no rescaling needed;
   // the user sets their lots and the sim balance is just a reference start).
   const double sim = InpSimBalance;

   // 1. Main TP hit, no hedge
   double s1 = sim + main_tp_money;
   SetPanelLine(row++, "  A) Main TP only           => $" + DoubleToString(s1, 2), PnlColor(s1 - sim));

   // 2. Main SL hit, no hedge involved or hedge not entered
   double s2 = sim + main_sl_money;
   SetPanelLine(row++, "  B) Main SL  (no hedge)    => $" + DoubleToString(s2, 2), PnlColor(s2 - sim));

   // 3. Main SL hit + hedge hits full profit target
   double hedge_tp_val = 0.0;
   if(best_hedge_valid)
      hedge_tp_val = TradePnlMoney(hedge_side, best_hedge_trigger, best_hedge_tp, best_hedge_lots);
  else if(InpUseHedge && InpHedgeLotsRatio > 0.0)
      hedge_tp_val = hedge_tp_money;
   double s3 = sim + main_sl_money + hedge_tp_val;
   SetPanelLine(row++, "  C) Main SL + Hedge full TP => $" + DoubleToString(s3, 2), PnlColor(s3 - sim));

   // 4. Main SL hit + hedge hits breakeven target (net = 0 by design)
   double hedge_be_val = 0.0;
   if(best_hedge_valid)
      hedge_be_val = TradePnlMoney(hedge_side, best_hedge_trigger, best_hedge_be_price, best_hedge_lots);
  else if(InpUseHedge && InpHedgeLotsRatio > 0.0)
      hedge_be_val = hedge_sl_money;
   double s4 = sim + main_sl_money + hedge_be_val;
   SetPanelLine(row++, "  D) Main SL + Hedge BE tgt  => $" + DoubleToString(s4, 2), PnlColor(s4 - sim));

   // 5. Current floating result if you closed right now
   double s5 = sim + floating_pnl;
   SetPanelLine(row++, "  E) Close now (floating)    => $" + DoubleToString(s5, 2), PnlColor(floating_pnl));

   // 6. Range summary
   double worst_pct = (sim > 0.0) ? ((s4 - sim) / sim * 100.0) : 0.0;
   double best_pct  = (sim > 0.0) ? ((s3 - sim) / sim * 100.0) : 0.0;
   SetPanelLine(row++, "  Best: " + (best_pct >= 0 ? "+" : "") + DoubleToString(best_pct, 1) + "%"
                + "   Min (BE): " + (worst_pct >= 0 ? "+" : "") + DoubleToString(worst_pct, 1) + "%", clrYellow);

   SetPanelLine(row++, sep, clrDimGray);

   // ── Verdict ─────────────────────────────────────────────
   string verdict;
   color  verdict_color;
   if(floating_pnl > 0.0)
     { verdict = ">> IN PROFIT  - Hold / Trail SL <<";    verdict_color = clrLime;   }
   else if(floating_pnl == 0.0)
     { verdict = ">> BREAK EVEN  - Watch closely <<";     verdict_color = clrYellow; }
   else if(floating_pnl > main_sl_money * 0.5)
     { verdict = ">> EARLY LOSS  - Monitor hedge <<";     verdict_color = clrOrange; }
   else if(floating_pnl > main_sl_money)
     { verdict = ">> IN LOSS  - Activate hedge now! <<";  verdict_color = clrRed;    }
   else
     { verdict = ">> AT/BEYOND SL  - Hedge is URGENT <<"; verdict_color = clrRed;    }

   SetPanelLine(row++, verdict, verdict_color);

   ClearPanelLines(row, 60);

   return report;
  }
//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- indicator buffers mapping
   IndicatorSetString(INDICATOR_SHORTNAME, "SEEFactors Hedge Visualizer");

//---
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   for(int row = 0; row <= 60; row++)
      ObjectDelete(0, SF_PANEL_PREFIX + IntegerToString(row));
  }
//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
//+------------------------------------------------------------------+
int OnCalculate(const int32_t rates_total,
                const int32_t prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int32_t &spread[])
  {
//---
    const string report = BuildScenarioReport();
    if(InpShowCommentText)
      Comment(report);
    else
      Comment("");

//--- return value of prev_calculated for next call
   return(rates_total);
  }
//+------------------------------------------------------------------+
