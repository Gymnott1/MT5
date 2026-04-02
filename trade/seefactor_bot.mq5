//+------------------------------------------------------------------+
//|                                                seefactor_bot.mq5 |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade/Trade.mqh>

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
input double    InpHedgeLotsRatio          = 0.5;
input double    InpHedgeEntryPrice         = 0.0;
input double    InpHedgeTakeProfit         = 0.0;
input double    InpHedgeStopLoss           = 0.0;
input double    InpHedgeTpPoints           = 300.0;
input double    InpHedgeSlPoints           = 250.0;

input double    InpRecoveryProfitPct       = 20.0;
input double    InpRecoveryDistancePoints  = 300.0;

input bool      InpAutoBestHedge           = true;
input double    InpBestHedgeTpPoints       = 300.0;

input bool      InpShowCommentText         = false;
input double    InpSimBalance              = 100.0;
input bool      InpStakeInUsd              = false;   // false=use lots, true=derive lots from USD risk at main SL
input double    InpStakeUsd                = 10.0;    // USD risk for main SL when InpStakeInUsd=true
input double    InpMaxMainRiskPctStake     = 2.0;     // Block any new entry whose main SL risk exceeds this % of configured stake
input bool      InpAutoScaleMainLots       = true;    // Automatically reduce main lots to fit the max-risk cap instead of blocking entry

// --- TRADE EXECUTION -------------------------------------------------------
input bool      InpAutoTrade          = true;     // Place trades automatically (false = visualization only)
input int       InpMagicNumber        = 20260319; // Magic number to identify EA orders
input bool      InpAutoHedgeOnSL      = true;     // Auto-place hedge when main SL is hit
input bool      InpKeepMainOpenOnHedge = true;    // True hedge mode: keep main position open and add opposite hedge
input bool      InpCloseMainOnHedgeFill = false;  // Safety: close main when hedge fills (disable to let basket manage both)
input double    InpEmergencyMainSLMultiplier = 3.0; // Emergency SL = N × virtual SL distance (0=disabled). Protects main even in keep-open mode.
input int       InpCooldownSeconds    = 30;       // Seconds to wait between trade cycles
input bool      InpExitHedgeAtBeTarget = true;    // Close hedge when BE target is reached
input double    InpBeTargetProfitPct  = 5.0;      // BE target net profit as % of main TP money
input bool      InpUseBasketSafety    = true;     // Close basket on combined PnL thresholds (runs every tick)
input bool      InpAutoBasketFromStake = true;    // Derive basket TP/SL from stake instead of fixed placeholder USD values
input double    InpBasketTakeProfitPct = 1.0;     // Basket TP as % of stake when auto basket mode is enabled
input double    InpBasketStopLossPct   = 5.0;     // Basket SL as % of stake when auto basket mode is enabled
input double    InpBasketTakeProfitUSD = 2.0;     // Close all positions when basket net >= this (take profit)
input double    InpBasketStopLossUSD   = 20.0;    // Close all positions when basket net <= -this (hard stop)
input bool      InpUseEquityGuard      = true;     // Block new trades if equity falls below starting balance
input double    InpOpeningBalance      = 0.0;     // Starting balance (auto-set on first run if 0)
input double    InpEquityGuardLossUSD  = 50.0;    // Pause only after this much equity loss from baseline (0 = strict baseline)
input bool      InpUseEntryPathGuard   = true;    // Block entry if hedge paths cannot break even
input double    InpMinPathNetUSD       = 0.0;     // Minimum required net on each path to allow entry
input double    InpMinPathProfitPct    = 0.0;     // Minimum required net on each path as % of main TP money

// Global state for trade execution
CTrade   g_trade;
ulong    g_main_ticket        = 0;
ulong    g_hedge_ticket       = 0;
ulong    g_hedge_order_ticket = 0;
bool     g_main_placed        = false;
bool     g_hedge_placed       = false;
bool     g_hedge_pending      = false;
double   g_main_entry_actual  = 0.0;
double   g_main_sl_actual     = 0.0;
double   g_main_virtual_sl    = 0.0;
double   g_main_emergency_sl  = 0.0;
double   g_main_tp_actual     = 0.0;
double   g_main_lots_actual   = 0.0;
double   g_hedge_entry_actual = 0.0;
double   g_hedge_lots_actual  = 0.0;
double   g_hedge_sl_price     = 0.0;
double   g_hedge_be_price     = 0.0;
double   g_hedge_tp_price     = 0.0;
bool     g_hedge_be_locked    = false;
string   g_trade_status       = "IDLE";
datetime g_cooldown_until     = 0;
double   g_opening_balance    = 0.0;

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

double NormalizeLotsDown(const double lots)
  {
   const double lot_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double lot_max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lot_step <= 0.0)
      return NormalizeLots(lots);

   double clamped = MathMax(lot_min, MathMin(lot_max, lots));
   clamped = MathFloor(clamped / lot_step) * lot_step;
   clamped = MathMax(lot_min, MathMin(lot_max, clamped));
   return NormalizeDouble(clamped, 2);
  }

double NormalizeLotsUp(const double lots)
  {
  const double lot_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  const double lot_max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  const double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

  if(lot_step <= 0.0)
    return NormalizeLots(lots);

  double clamped = MathMax(lot_min, MathMin(lot_max, lots));
  clamped = MathCeil(clamped / lot_step) * lot_step;
  clamped = MathMax(lot_min, MathMin(lot_max, clamped));
  return NormalizeDouble(clamped, 2);
  }

bool SolveConstrainedHedgeLots(const double main_tp_money,
                               const double main_sl_money,
                               const double hedge_tp_per_lot,
                               const double hedge_sl_per_lot,
                               const double desired_extra_profit,
                               double &hedge_lots,
                               string &reason)
  {
   if(main_tp_money <= 0.0 || main_sl_money >= 0.0 || hedge_tp_per_lot <= 0.0 || hedge_sl_per_lot >= 0.0)
     {
      reason = "Invalid scenario inputs";
      return false;
     }

   const double lots_min_for_main_sl_hedge_tp = MathAbs(main_sl_money) / hedge_tp_per_lot;
   const double lots_max_for_main_tp_hedge_sl = main_tp_money / MathAbs(hedge_sl_per_lot);

   if(lots_min_for_main_sl_hedge_tp > lots_max_for_main_tp_hedge_sl)
     {
      reason = "No feasible hedge lots for all profit paths";
      return false;
     }

   const double desired_money = MathAbs(main_sl_money) + MathMax(0.0, desired_extra_profit);
   const double desired_lots = desired_money / hedge_tp_per_lot;
   const double bounded_lots = MathMax(lots_min_for_main_sl_hedge_tp,
                               MathMin(lots_max_for_main_tp_hedge_sl, desired_lots));

   hedge_lots = NormalizeLotsDown(bounded_lots);
   if(hedge_lots <= 0.0)
     {
      reason = "Computed hedge lots invalid";
      return false;
     }

   const double net_main_sl_hedge_tp = main_sl_money + (hedge_tp_per_lot * hedge_lots);
   const double net_main_tp_hedge_sl = main_tp_money + (hedge_sl_per_lot * hedge_lots);

   if(net_main_sl_hedge_tp < 0.0 || net_main_tp_hedge_sl < 0.0)
     {
      reason = "Rounded lots violate profit-path guard";
      return false;
     }

   reason = "OK";
   return true;
  }

bool ComputeAutoBestHedgePlan(const double main_entry_price,
                              const double main_trigger_price,
                              const double main_tp_price,
                              const double main_lots,
                              double &hedge_lots,
                              double &hedge_sl_price,
                              double &hedge_be_price,
                              double &hedge_tp_price,
                              double &be_points_needed,
                              double &tp_points_needed,
                              string &reason)
  {
   hedge_lots = 0.0;
   hedge_sl_price = 0.0;
   hedge_be_price = 0.0;
   hedge_tp_price = 0.0;
   be_points_needed = 0.0;
   tp_points_needed = 0.0;

   if(main_entry_price <= 0.0 || main_trigger_price <= 0.0 || main_tp_price <= 0.0 || main_lots <= 0.0)
     {
      reason = "Invalid main trade geometry";
      return false;
     }

   if(InpHedgeSlPoints <= 0.0)
     {
      reason = "Invalid InpHedgeSlPoints";
      return false;
     }

   const TradeSide main_side = InpMainSide;
   const TradeSide hedge_side = (main_side == SideBuy) ? SideSell : SideBuy;

   // Architecture:
   // B = main entry, C = hedge trigger (main virtual SL),
   // A = TP1 = hedge SL, D = SL1 = hedge TP.
   const double level_a = main_tp_price;
   const double level_c = main_trigger_price;
   const double level_d = PriceByPoints(hedge_side, level_c, InpHedgeSlPoints, true);

   const double main_at_a = TradePnlMoney(main_side, main_entry_price, level_a, main_lots);
   const double main_at_d = TradePnlMoney(main_side, main_entry_price, level_d, main_lots);

   const double hedge_at_a_per_lot = TradePnlMoney(hedge_side, level_c, level_a, 1.0);
   const double hedge_at_d_per_lot = TradePnlMoney(hedge_side, level_c, level_d, 1.0);

   if(main_at_a <= 0.0 || hedge_at_a_per_lot >= 0.0 || hedge_at_d_per_lot <= 0.0)
     {
      reason = "Invalid crossover geometry";
      return false;
     }

   const double min_path_profit = MathMax(0.0,
                                 MathMax(InpMinPathNetUSD,
                                         MathAbs(main_at_a) * (InpMinPathProfitPct / 100.0)));

   // At A: main TP + hedge SL >= target  => upper bound for hedge lots.
   const double lots_upper_a = (main_at_a - min_path_profit) / MathAbs(hedge_at_a_per_lot);
   // At D: main SL + hedge TP >= target  => lower bound for hedge lots.
   const double lots_lower_d = (min_path_profit - main_at_d) / hedge_at_d_per_lot;

   const double lower = MathMax(0.0, lots_lower_d);
   const double upper = MathMax(0.0, lots_upper_a);

   if(upper <= 0.0 || lower > upper)
     {
      reason = StringFormat("No feasible hedge lots for crossover paths (lower=%.4f upper=%.4f)", lower, upper);
      return false;
     }

   // Choose the smallest hedge that still protects the D-path.
   double solved_lots = NormalizeLotsUp(lower);
   if(solved_lots > upper)
      solved_lots = NormalizeLotsDown(upper);

   if(solved_lots <= 0.0 || solved_lots < lower || solved_lots > upper)
     {
      reason = "Rounded hedge lots violate crossover constraints";
      return false;
     }

   const double net_a = main_at_a + TradePnlMoney(hedge_side, level_c, level_a, solved_lots);
   const double net_d = main_at_d + TradePnlMoney(hedge_side, level_c, level_d, solved_lots);
   if(net_a < min_path_profit || net_d < min_path_profit)
     {
      reason = StringFormat("Crossover nets below target (A=%.2f D=%.2f target=%.2f)", net_a, net_d, min_path_profit);
      return false;
     }

   hedge_lots = solved_lots;
   hedge_sl_price = level_a; // TP1 = SL2
   hedge_be_price = level_a; // keep existing BE-management flow aligned with crossover A level
   hedge_tp_price = level_d; // TP2 = SL1
   be_points_needed = MathAbs(level_a - level_c) / _Point;
   tp_points_needed = MathAbs(level_d - level_c) / _Point;

   reason = "OK";
   return true;
  }

bool ComputeFallbackHedgePlan(const double main_entry_price,
                              const double main_trigger_price,
                              const double main_tp_price,
                              const double main_lots,
                              double &hedge_lots,
                              double &hedge_sl_price,
                              double &hedge_be_price,
                              double &hedge_tp_price,
                              double &be_points_needed,
                              string &reason)
  {
   hedge_lots = 0.0;
   hedge_sl_price = 0.0;
   hedge_be_price = 0.0;
   hedge_tp_price = 0.0;
   be_points_needed = 0.0;

   if(main_entry_price <= 0.0 || main_trigger_price <= 0.0 || main_tp_price <= 0.0 || main_lots <= 0.0)
     {
      reason = "Invalid main trade geometry";
      return false;
     }

   if(InpBestHedgeTpPoints <= 0.0 || InpHedgeSlPoints <= 0.0)
     {
      reason = "Invalid fallback hedge TP/SL points";
      return false;
     }

   const TradeSide main_side = InpMainSide;
   const TradeSide hedge_side = (main_side == SideBuy) ? SideSell : SideBuy;
   const double point_money = MoneyPerPointPerLot();
   if(point_money <= 0.0)
     {
      reason = "Invalid symbol point value";
      return false;
     }

   const double main_sl_money = TradePnlMoney(main_side, main_entry_price, main_trigger_price, main_lots);
   const double main_tp_money = TradePnlMoney(main_side, main_entry_price, main_tp_price, main_lots);
   if(main_tp_money <= 0.0 || main_sl_money >= 0.0)
     {
      reason = "Invalid main TP/SL direction";
      return false;
     }

   hedge_tp_price = PriceByPoints(hedge_side, main_trigger_price, InpBestHedgeTpPoints, true);
   hedge_sl_price = PriceByPoints(hedge_side, main_trigger_price, InpHedgeSlPoints, false);

   const double pnl_per_lot_tp = TradePnlMoney(hedge_side, main_trigger_price, hedge_tp_price, 1.0);
   const double pnl_per_lot_sl = TradePnlMoney(hedge_side, main_trigger_price, hedge_sl_price, 1.0);
   if(pnl_per_lot_tp <= 0.0 || pnl_per_lot_sl >= 0.0)
     {
      reason = "Invalid hedge direction PnL";
      return false;
     }

   const double recovery_extra = MathAbs(main_tp_money) * (InpRecoveryProfitPct / 100.0);
   string solve_reason;
   if(!SolveConstrainedHedgeLots(main_tp_money,
                                 main_sl_money,
                                 pnl_per_lot_tp,
                                 pnl_per_lot_sl,
                                 recovery_extra,
                                 hedge_lots,
                                 solve_reason))
     {
      reason = solve_reason;
      return false;
     }

   const double be_profit_extra = MathAbs(main_tp_money) * (InpBeTargetProfitPct / 100.0);
   const double be_target_money = MathAbs(main_sl_money) + MathMax(0.0, be_profit_extra);

   if(InpKeepMainOpenOnHedge)
     {
      const double per_point_net = (hedge_lots - main_lots) * point_money;
      if(per_point_net <= 0.0)
        {
         reason = "Fallback BE requires hedge lots > main lots";
         return false;
        }
      be_points_needed = be_target_money / per_point_net;
     }
   else
     {
      be_points_needed = be_target_money / (hedge_lots * point_money);
     }

   hedge_be_price = PriceByPoints(hedge_side, main_trigger_price, be_points_needed, true);
   reason = "OK";
   return true;
  }

bool ValidateEntryProfitPaths(const double entry_price,
                              const double main_sl_price,
                              const double main_tp_price,
                              const double main_lots,
                              string &reason)
  {
   if(!InpUseHedge || !InpAutoHedgeOnSL)
     {
      reason = "OK (hedge disabled)";
      return true;
     }

   if(InpAutoBestHedge)
     {
      double hedge_lots = 0.0;
      double hedge_sl_price = 0.0;
      double hedge_be_price = 0.0;
      double hedge_tp_price = 0.0;
      double be_points_needed = 0.0;
      double tp_points_needed = 0.0;
      const bool auto_ok = ComputeAutoBestHedgePlan(entry_price,
                                                    main_sl_price,
                                                    main_tp_price,
                                                    main_lots,
                                                    hedge_lots,
                                                    hedge_sl_price,
                                                    hedge_be_price,
                                                    hedge_tp_price,
                                                    be_points_needed,
                                                    tp_points_needed,
                                                    reason);

      if(auto_ok)
        {
         if(!InpUseEntryPathGuard)
           {
            reason = "OK (auto-fit)";
            return true;
           }

         reason = "OK";
         return true;
        }

      if(!InpUseEntryPathGuard)
        {
         reason = "OK (auto unavailable, guard off)";
         return true;
        }
     }

   if(InpBestHedgeTpPoints <= 0.0 || InpHedgeSlPoints <= 0.0)
     {
      reason = "Invalid hedge TP/SL points";
      return false;
     }

   const TradeSide hedge_side = (InpMainSide == SideBuy) ? SideSell : SideBuy;
   const double main_tp_money = TradePnlMoney(InpMainSide, entry_price, main_tp_price, main_lots);
   const double main_sl_money = TradePnlMoney(InpMainSide, entry_price, main_sl_price, main_lots);

   if(main_tp_money <= 0.0 || main_sl_money >= 0.0)
     {
      reason = "Invalid main TP/SL direction";
      return false;
     }

   const double hedge_tp_price = PriceByPoints(hedge_side, main_sl_price, InpBestHedgeTpPoints, true);
   const double hedge_sl_price = PriceByPoints(hedge_side, main_sl_price, InpHedgeSlPoints, false);
   const double hedge_tp_per_lot = TradePnlMoney(hedge_side, main_sl_price, hedge_tp_price, 1.0);
   const double hedge_sl_per_lot = TradePnlMoney(hedge_side, main_sl_price, hedge_sl_price, 1.0);

   if(hedge_tp_per_lot <= 0.0 || hedge_sl_per_lot >= 0.0)
     {
      reason = "Invalid hedge direction PnL";
      return false;
     }

   const double lots_min = MathAbs(main_sl_money) / hedge_tp_per_lot;
   const double lots_max = main_tp_money / MathAbs(hedge_sl_per_lot);

   if(lots_min > lots_max)
     {
      reason = StringFormat("No feasible lots: need %.2f but max is %.2f. Widen hedge TP or tighten hedge SL.", lots_min, lots_max);
      return false;
     }

   const double hedge_lots = NormalizeLotsDown(MathMax(lots_min, MathMin(lots_max, lots_min)));
   const double net_main_tp_hedge_sl = main_tp_money + (hedge_sl_per_lot * hedge_lots);
   const double net_main_sl_hedge_tp = main_sl_money + (hedge_tp_per_lot * hedge_lots);

   if(!InpUseEntryPathGuard)
     {
      reason = "OK (feasibility only)";
      return true;
     }

   if(net_main_tp_hedge_sl < InpMinPathNetUSD || net_main_sl_hedge_tp < InpMinPathNetUSD)
     {
      reason = StringFormat("Paths below min: A=%.2f B=%.2f min=%.2f", net_main_tp_hedge_sl, net_main_sl_hedge_tp, InpMinPathNetUSD);
      return false;
     }

   reason = "OK";
   return true;
  }

double RequestedMainLots(const double entry_price, const double sl_price)
  {
  if(!InpStakeInUsd)
    return NormalizeLots(InpStakeLots);

  const double point_money = MoneyPerPointPerLot();
  const double sl_points = MathAbs(entry_price - sl_price) / _Point;
  if(point_money <= 0.0 || sl_points <= 0.0 || InpStakeUsd <= 0.0)
    return 0.0;

  const double lots = InpStakeUsd / (sl_points * point_money);
  return NormalizeLots(lots);
  }

double MaxMainLotsForRiskCap(const double entry_price, const double sl_price)
  {
  if(InpMaxMainRiskPctStake <= 0.0)
    return RequestedMainLots(entry_price, sl_price);

  const double stake_usd = ConfiguredStakeUsd();
  const double max_risk_usd = stake_usd * (InpMaxMainRiskPctStake / 100.0);
  const double risk_per_lot = MainRiskUsd(entry_price, sl_price, 1.0);
  if(max_risk_usd <= 0.0 || risk_per_lot <= 0.0)
    return 0.0;

  return NormalizeLotsDown(max_risk_usd / risk_per_lot);
  }

double EffectiveMainLots(const double entry_price, const double sl_price)
  {
  double lots = RequestedMainLots(entry_price, sl_price);
  if(lots <= 0.0)
    return 0.0;

  if(!InpAutoScaleMainLots || InpMaxMainRiskPctStake <= 0.0)
    return lots;

  const double max_lots = MaxMainLotsForRiskCap(entry_price, sl_price);
  if(max_lots <= 0.0)
    return 0.0;

  return NormalizeLotsDown(MathMin(lots, max_lots));
  }

double MainRiskUsd(const double entry_price, const double sl_price, const double lots)
  {
   const double pnl_at_sl = TradePnlMoney(InpMainSide, entry_price, sl_price, lots);
   return MathMax(0.0, MathAbs(pnl_at_sl));
  }

double MainRiskPctOfStake(const double entry_price, const double sl_price, const double lots)
  {
   const double stake_usd = ConfiguredStakeUsd();
   if(stake_usd <= 0.0)
      return 0.0;

   return (MainRiskUsd(entry_price, sl_price, lots) / stake_usd) * 100.0;
  }

  double ConfiguredStakeUsd()
    {
    if(InpStakeInUsd && InpStakeUsd > 0.0)
      return InpStakeUsd;
    if(InpSimBalance > 0.0)
      return InpSimBalance;
    return 100.0;
    }

  double EffectiveBasketTakeProfitUsd()
    {
    if(!InpAutoBasketFromStake)
      return MathMax(0.0, InpBasketTakeProfitUSD);

    return MathMax(0.0, ConfiguredStakeUsd() * (InpBasketTakeProfitPct / 100.0));
    }

  double EffectiveBasketStopLossUsd()
    {
    if(!InpAutoBasketFromStake)
      return MathMax(0.0, InpBasketStopLossUSD);

    return MathMax(0.0, ConfiguredStakeUsd() * (InpBasketStopLossPct / 100.0));
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

double MinStopDistancePrice()
  {
   const long stops_level  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const long freeze_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   const long min_points   = MathMax(stops_level, freeze_level) + 5;
   return min_points * _Point;
  }

void BuildBrokerSafeStops(const TradeSide side,
                          const double desired_sl,
                          const double desired_tp,
                          double &safe_sl,
                          double &safe_tp)
  {
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double min_distance = MinStopDistancePrice();

   safe_sl = NormalizePrice(desired_sl);
   safe_tp = NormalizePrice(desired_tp);

   if(side == SideBuy)
     {
      if(safe_sl > 0.0)
         safe_sl = NormalizePrice(MathMin(safe_sl, bid - min_distance));
      if(safe_tp > 0.0)
         safe_tp = NormalizePrice(MathMax(safe_tp, ask + min_distance));
     }
   else
     {
      if(safe_sl > 0.0)
         safe_sl = NormalizePrice(MathMax(safe_sl, ask + min_distance));
      if(safe_tp > 0.0)
         safe_tp = NormalizePrice(MathMin(safe_tp, bid - min_distance));
     }
  }

  ulong FindPositionTicketByTag(const string tag)
    {
    for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
      const ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
        continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
        continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
        continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), tag) < 0)
        continue;
      return ticket;
      }

    return 0;
    }

  bool SelectTrackedPosition(ulong &ticket, const string tag)  
    {
    if(ticket > 0 && PositionSelectByTicket(ticket))
      return true;

    ticket = FindPositionTicketByTag(tag);
    if(ticket == 0)
      return false;

    return PositionSelectByTicket(ticket);
    }

ulong FindOrderTicketByTag(const string tag)
  {
  for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
    const ulong ticket = OrderGetTicket(i);
    if(ticket == 0 || !OrderSelect(ticket))
      continue;
    if(OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;
    if(OrderGetInteger(ORDER_MAGIC) != (long)InpMagicNumber)
      continue;
    if(StringFind(OrderGetString(ORDER_COMMENT), tag) < 0)
      continue;
    return ticket;
    }

  return 0;
  }

bool SelectTrackedOrder(ulong &ticket, const string tag)
  {
  if(ticket > 0 && OrderSelect(ticket))
    return true;

  ticket = FindOrderTicketByTag(tag);
  if(ticket == 0)
    return false;

  return OrderSelect(ticket);
  }

bool CancelHedgePending()
  {
  if(!g_hedge_pending)
    return true;
  if(!SelectTrackedOrder(g_hedge_order_ticket, "SEEFactor-Hedge"))
    {
    g_hedge_pending = false;
    g_hedge_order_ticket = 0;
    return true;
    }

  if(g_trade.OrderDelete(g_hedge_order_ticket))
    {
    g_hedge_pending = false;
    g_hedge_order_ticket = 0;
    Print("[SEEFactor] Hedge pending order cancelled.");
    return true;
    }

  g_trade_status = "Pending hedge delete failed: " + g_trade.ResultRetcodeDescription();
  return false;
  }

bool CancelAllHedgePendings()
  {
  bool all_ok = true;

  for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
    const ulong ticket = OrderGetTicket(i);
    if(ticket == 0 || !OrderSelect(ticket))
      continue;
    if(OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;
    if(OrderGetInteger(ORDER_MAGIC) != (long)InpMagicNumber)
      continue;
    if(StringFind(OrderGetString(ORDER_COMMENT), "SEEFactor-Hedge") < 0)
      continue;

    if(!g_trade.OrderDelete(ticket))
      {
      all_ok = false;
      PrintFormat("[SEEFactor] Failed deleting hedge pending #%d: %s",
                  (long)ticket, g_trade.ResultRetcodeDescription());
      }
    else
      {
      PrintFormat("[SEEFactor] Hedge pending #%d cancelled during cycle close.", (long)ticket);
      }
    }

  g_hedge_order_ticket = FindOrderTicketByTag("SEEFactor-Hedge");
  g_hedge_pending = (g_hedge_order_ticket > 0);
  return all_ok && !g_hedge_pending;
  }

bool GetClosedPositionProfit(const ulong position_ticket, double &close_profit)
  {
  close_profit = 0.0;
  if(position_ticket == 0)
    return false;

  if(!HistorySelectByPosition(position_ticket))
    return false;

  const int total = HistoryDealsTotal();
  for(int i = total - 1; i >= 0; i--)
    {
    const ulong deal = HistoryDealGetTicket(i);
    if((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID) != position_ticket)
      continue;
    if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      continue;

    close_profit = HistoryDealGetDouble(deal, DEAL_PROFIT)
                   + HistoryDealGetDouble(deal, DEAL_SWAP)
                   + HistoryDealGetDouble(deal, DEAL_COMMISSION);
    return true;
    }

  return false;
  }

double GetPositionNetPnl(const ulong ticket)
  {
  if(ticket == 0 || !PositionSelectByTicket(ticket))
    return 0.0;

  return PositionGetDouble(POSITION_PROFIT)
         + PositionGetDouble(POSITION_SWAP)
         + PositionGetDouble(POSITION_COMMISSION);
  }

bool PlaceHedgePendingFromMain()
  {
  if(!InpUseHedge || !InpAutoHedgeOnSL)
    return false;
  if(g_hedge_pending || g_hedge_placed)
    return true;
  if(g_main_entry_actual <= 0.0 || g_main_tp_actual <= 0.0)
    return false;

  const double main_trigger = (g_main_virtual_sl > 0.0) ? g_main_virtual_sl : g_main_sl_actual;
  if(main_trigger <= 0.0)
    return false;

  const TradeSide hedge_side = (InpMainSide == SideBuy) ? SideSell : SideBuy;
  double hedge_lots = 0.0;
  double hedge_sl_raw = 0.0;
  double hedge_be_price = 0.0;
  double hedge_tp_raw = 0.0;
  double be_points_needed = 0.0;
  double tp_points_needed = 0.0;
  string solve_reason;

  if(InpAutoBestHedge)
    {
     if(!ComputeAutoBestHedgePlan(g_main_entry_actual,
                                  main_trigger,
                                  g_main_tp_actual,
                                  g_main_lots_actual,
                                  hedge_lots,
                                  hedge_sl_raw,
                                  hedge_be_price,
                                  hedge_tp_raw,
                                  be_points_needed,
                                  tp_points_needed,
                                  solve_reason))
       {
        string fallback_reason;
        if(!ComputeFallbackHedgePlan(g_main_entry_actual,
                                     main_trigger,
                                     g_main_tp_actual,
                                     g_main_lots_actual,
                                     hedge_lots,
                                     hedge_sl_raw,
                                     hedge_be_price,
                                     hedge_tp_raw,
                                     be_points_needed,
                                     fallback_reason))
          {
           g_trade_status = "Hedge sizing blocked: auto=" + solve_reason + " | fallback=" + fallback_reason;
           Print("[SEEFactor] ", g_trade_status);
           return false;
          }

        Print("[SEEFactor] Auto hedge unavailable, using fallback hedge plan.");
       }
    }
  else
    {
     if(!ComputeFallbackHedgePlan(g_main_entry_actual,
                                  main_trigger,
                                  g_main_tp_actual,
                                  g_main_lots_actual,
                                  hedge_lots,
                                  hedge_sl_raw,
                                  hedge_be_price,
                                  hedge_tp_raw,
                                  be_points_needed,
                                  solve_reason))
       {
        g_trade_status = "Hedge sizing blocked: " + solve_reason;
        Print("[SEEFactor] ", g_trade_status);
        return false;
       }
    }

  if(hedge_lots <= 0.0)
    return false;

  double hedge_sl = 0.0;
  double hedge_tp = 0.0;
  // In crossover architecture (auto mode), hedge TP is the shared D level (TP2 = SL1)
  // and hedge SL is the shared A level (SL2 = TP1), so keep hard exits on order.
  const double hedge_tp_for_order = (InpAutoBestHedge ? hedge_tp_raw : (InpKeepMainOpenOnHedge ? 0.0 : hedge_tp_raw));
  BuildBrokerSafeStops(hedge_side, hedge_sl_raw, hedge_tp_for_order, hedge_sl, hedge_tp);

  bool ok;
  if(hedge_side == SideBuy)
    ok = g_trade.BuyStop(hedge_lots, main_trigger, _Symbol, hedge_sl, hedge_tp, ORDER_TIME_GTC, 0, "SEEFactor-Hedge");
  else
    ok = g_trade.SellStop(hedge_lots, main_trigger, _Symbol, hedge_sl, hedge_tp, ORDER_TIME_GTC, 0, "SEEFactor-Hedge");

  if(!ok)
    {
    g_trade_status = "Hedge pending FAILED: " + g_trade.ResultRetcodeDescription();
    Print("[SEEFactor] ", g_trade_status);
    return false;
    }

  g_hedge_order_ticket = g_trade.ResultOrder();
  g_hedge_pending = true;
  g_hedge_lots_actual = hedge_lots;
  g_hedge_sl_price = hedge_sl;
  g_hedge_be_price = hedge_be_price;
  g_hedge_tp_price = hedge_tp;
    g_trade_status = StringFormat("Hedge pending #%d %.2f lots @ %.5f", (long)g_hedge_order_ticket, hedge_lots, main_trigger);
  PrintFormat("[SEEFactor] Hedge pending %s %.2f lots trigger=%.5f BE=%.5f TP=%.5f",
      SideToText(hedge_side), hedge_lots, main_trigger, g_hedge_be_price, g_hedge_tp_price);
  return true;
  }

void SyncTradeState()
  {
  const bool has_main = SelectTrackedPosition(g_main_ticket, "SEEFactor-Main");
  const bool has_hedge_pos = SelectTrackedPosition(g_hedge_ticket, "SEEFactor-Hedge");
  const bool has_hedge_order = SelectTrackedOrder(g_hedge_order_ticket, "SEEFactor-Hedge");

  g_main_placed = has_main;
  g_hedge_placed = has_hedge_pos;
  g_hedge_pending = has_hedge_order && !has_hedge_pos;

  if(has_main)
    {
    g_main_entry_actual = PositionGetDouble(POSITION_PRICE_OPEN);
    const double pos_sl = PositionGetDouble(POSITION_SL);
    g_main_emergency_sl = pos_sl;
    if(InpKeepMainOpenOnHedge)
      {
       if(g_main_virtual_sl <= 0.0)
          g_main_virtual_sl = PriceByPoints(InpMainSide, g_main_entry_actual, InpMainSlPoints, false);
       g_main_sl_actual = g_main_virtual_sl;
      }
    else if(pos_sl > 0.0)
      {
       g_main_sl_actual = pos_sl;
      }
    else if(g_main_virtual_sl > 0.0)
      {
       g_main_sl_actual = g_main_virtual_sl;
      }
    g_main_tp_actual = PositionGetDouble(POSITION_TP);
    g_main_lots_actual = PositionGetDouble(POSITION_VOLUME);
    }

  if(has_hedge_pos)
    {
    g_hedge_entry_actual = PositionGetDouble(POSITION_PRICE_OPEN);
    g_hedge_sl_price = PositionGetDouble(POSITION_SL);
    g_hedge_tp_price = PositionGetDouble(POSITION_TP);
    g_hedge_lots_actual = PositionGetDouble(POSITION_VOLUME);
    }
  else if(has_hedge_order)
    {
    g_hedge_sl_price = OrderGetDouble(ORDER_SL);
    g_hedge_tp_price = OrderGetDouble(ORDER_TP);
    g_hedge_lots_actual = OrderGetDouble(ORDER_VOLUME_CURRENT);
    }
  }

//--- Scan open positions on restart and re-link EA state to existing trades
void ScanExistingPositions()
  {
   g_main_placed  = false;
   g_hedge_placed = false;
   g_main_ticket  = 0;
   g_hedge_ticket = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;

      const string comment = PositionGetString(POSITION_COMMENT);
      if(StringFind(comment, "SEEFactor-Main") >= 0)
        {
         g_main_ticket       = ticket;
         g_main_placed       = true;
         g_main_entry_actual = PositionGetDouble(POSITION_PRICE_OPEN);
         g_main_emergency_sl = PositionGetDouble(POSITION_SL);
         g_main_tp_actual    = PositionGetDouble(POSITION_TP);
         g_main_lots_actual  = PositionGetDouble(POSITION_VOLUME);
         if(InpKeepMainOpenOnHedge)
           {
            g_main_virtual_sl = PriceByPoints(InpMainSide, g_main_entry_actual, InpMainSlPoints, false);
            g_main_sl_actual = g_main_virtual_sl;
           }
         else if(g_main_emergency_sl > 0.0)
           {
            g_main_sl_actual = g_main_emergency_sl;
           }
         else if(g_main_sl_actual <= 0.0)
           {
            g_main_virtual_sl = PriceByPoints(InpMainSide, g_main_entry_actual, InpMainSlPoints, false);
            g_main_sl_actual = g_main_virtual_sl;
           }
         g_trade_status      = "Resumed main #" + IntegerToString((long)ticket);
         PrintFormat("[SEEFactor] Resumed main #%d entry=%.5f", (long)ticket, g_main_entry_actual);
        }
      else if(StringFind(comment, "SEEFactor-Hedge") >= 0)
        {
         g_hedge_ticket = ticket;
         g_hedge_placed = true;
         g_hedge_entry_actual = PositionGetDouble(POSITION_PRICE_OPEN);
         g_hedge_lots_actual  = PositionGetDouble(POSITION_VOLUME);
         g_hedge_sl_price     = PositionGetDouble(POSITION_SL);
         g_hedge_tp_price     = PositionGetDouble(POSITION_TP);
         g_trade_status = "Resumed hedge #" + IntegerToString((long)ticket);
         PrintFormat("[SEEFactor] Resumed hedge #%d", (long)ticket);
        }
     }
  }

//--- Place the main trade at current market price
bool PlaceMainTrade()
  {
   if(InpUseEquityGuard && g_opening_balance > 0.0)
     {
      const double current_equity = AccountInfoDouble(ACCOUNT_EQUITY);
      const double equity_floor = g_opening_balance - MathMax(0.0, InpEquityGuardLossUSD);
      if(current_equity < equity_floor)
        {
         g_trade_status = StringFormat("Equity guard: $%.2f < $%.2f floor. Paused.", current_equity, equity_floor);
         return false;
        }
     }

   const double entry = CurrentReferencePrice(InpMainSide);
  const double tp_raw = PriceByPoints(InpMainSide, entry, InpMainTpPoints, true);
  const double sl_raw = PriceByPoints(InpMainSide, entry, InpMainSlPoints, false);

  double sl = 0.0;
  double tp = 0.0;
  BuildBrokerSafeStops(InpMainSide, sl_raw, tp_raw, sl, tp);
  double order_sl = sl;
  if(InpKeepMainOpenOnHedge)
    {
     if(InpEmergencyMainSLMultiplier > 0.0)
       {
        const double emg_raw = PriceByPoints(InpMainSide, entry, InpMainSlPoints * InpEmergencyMainSLMultiplier, false);
        double emg_sl = 0.0, _dummy = 0.0;
        BuildBrokerSafeStops(InpMainSide, emg_raw, 0.0, emg_sl, _dummy);
        order_sl = emg_sl;
       }
     else
        order_sl = 0.0;
    }

  const double requested_main_lots = RequestedMainLots(entry, sl);
  const double main_lots = EffectiveMainLots(entry, sl);
  if(main_lots <= 0.0)
    {
    g_trade_status = "Main FAILED: invalid lots from stake settings";
    return false;
    }

  const double main_risk_usd = MainRiskUsd(entry, sl, main_lots);
  const double main_risk_pct = MainRiskPctOfStake(entry, sl, main_lots);
  // Only hard-block on risk cap when NOT auto-scaling.
  // When auto-scaling is on, EffectiveMainLots() already reduced to broker minimum;
  // if that minimum still exceeds the cap we accept it — we cannot go smaller.
  if(!InpAutoScaleMainLots && InpMaxMainRiskPctStake > 0.0 && main_risk_pct > InpMaxMainRiskPctStake)
    {
     g_trade_status = StringFormat("Main blocked: risk %.2f%% ($%.2f) > max %.2f%% of stake",
                                   main_risk_pct, main_risk_usd, InpMaxMainRiskPctStake);
     return false;
    }

  string path_reason;
  if(!ValidateEntryProfitPaths(entry, sl, tp, main_lots, path_reason))
    {
     g_trade_status = "Main blocked: " + path_reason;
     return false;
    }

   bool ok;
   if(InpMainSide == SideBuy)
    ok = g_trade.Buy(main_lots, _Symbol, 0.0, order_sl, tp, "SEEFactor-Main");
   else
    ok = g_trade.Sell(main_lots, _Symbol, 0.0, order_sl, tp, "SEEFactor-Main");

   if(ok)
     {
      g_main_ticket = g_trade.ResultOrder();
      g_main_placed = true;
      g_main_lots_actual = main_lots;

      if(SelectTrackedPosition(g_main_ticket, "SEEFactor-Main"))
        {
         g_main_entry_actual = PositionGetDouble(POSITION_PRICE_OPEN);
         g_main_emergency_sl = PositionGetDouble(POSITION_SL);
         g_main_tp_actual    = PositionGetDouble(POSITION_TP);
         g_main_lots_actual  = PositionGetDouble(POSITION_VOLUME);
        }

      g_main_virtual_sl = sl;
      if(InpKeepMainOpenOnHedge)
        g_main_sl_actual = g_main_virtual_sl;
      else
        g_main_sl_actual = g_main_emergency_sl;

      g_trade_status = "Main open #" + IntegerToString((long)g_main_ticket);
      PrintFormat("[SEEFactor] Main %s %.2f lots entry=%.5f SL=%.5f TP=%.5f",
                  SideToText(InpMainSide), g_main_lots_actual,
                  g_main_entry_actual, g_main_sl_actual, g_main_tp_actual);
  PlaceHedgePendingFromMain();
      return true;
     }

   g_trade_status = "Main FAILED: " + g_trade.ResultRetcodeDescription();
  PrintFormat("[SEEFactor] %s | req SL=%.5f TP=%.5f", g_trade_status, sl, tp);
   return false;
  }

//--- Handle main closure while hedge is pending/open
void CheckAndPlaceHedge()
  {
   if(g_main_ticket == 0)
     {
      if(g_hedge_pending)
        {
         if(CancelHedgePending())
            g_trade_status = "Orphan hedge pending cleared.";
         else
            g_trade_status = "Waiting to clear orphan hedge pending...";
        }
      return;
     }

   if(SelectTrackedPosition(g_main_ticket, "SEEFactor-Main"))
     {
      if(!g_hedge_pending && !g_hedge_placed)
        {
         if(!PlaceHedgePendingFromMain())
           {
            const double main_trigger = (g_main_virtual_sl > 0.0) ? g_main_virtual_sl : g_main_sl_actual;
            const double close_price = CurrentClosePrice(InpMainSide);
            const bool trigger_hit = (InpMainSide == SideBuy)
                                     ? (close_price <= main_trigger)
                                     : (close_price >= main_trigger);

            if(main_trigger > 0.0 && trigger_hit)
              {
               g_trade_status = "No hedge at SL trigger. Force-closing main...";
               if(g_trade.PositionClose(g_main_ticket))
                 {
                  PrintFormat("[SEEFactor] Main force-closed at %.5f because hedge was not active/pending.", close_price);
                  StartCooldown("Main force-closed (no hedge). Next in " + IntegerToString(InpCooldownSeconds) + "s");
                 }
               else
                 {
                  g_trade_status = "Force close failed: " + g_trade.ResultRetcodeDescription();
                 }
              }
            else
              {
               g_trade_status = "Hedge pending failed; guarding unhedged main.";
              }
           }
        }
      else if(g_hedge_pending && !g_hedge_placed)
        {
         const double main_trigger = (g_main_virtual_sl > 0.0) ? g_main_virtual_sl : g_main_sl_actual;
         const double close_price = CurrentClosePrice(InpMainSide);
         const bool trigger_hit = (InpMainSide == SideBuy)
                                  ? (close_price <= main_trigger)
                                  : (close_price >= main_trigger);

         if(main_trigger > 0.0 && trigger_hit)
           {
            g_trade_status = "Trigger crossed but hedge not filled. Emergency close main...";
            if(g_trade.PositionClose(g_main_ticket))
              {
               CancelHedgePending();
               PrintFormat("[SEEFactor] Emergency main close at %.5f (pending hedge not filled after trigger).", close_price);
               StartCooldown("Emergency close (pending hedge unfilled). Next in " + IntegerToString(InpCooldownSeconds) + "s");
               return;
              }

            g_trade_status = "Emergency main close failed: " + g_trade.ResultRetcodeDescription();
           }
        }
      else if(g_hedge_placed)
        {
         if(InpCloseMainOnHedgeFill)
           {
            g_trade_status = "Hedge active. Closing main to cap loss...";
            if(g_trade.PositionClose(g_main_ticket))
              {
               PrintFormat("[SEEFactor] Main closed on hedge activation. Main ticket=%d Hedge ticket=%d",
                           (long)g_main_ticket, (long)g_hedge_ticket);
               g_main_placed = false;
               g_main_ticket = 0;
               return;
              }

            g_trade_status = "Close main on hedge fill failed: " + g_trade.ResultRetcodeDescription();
           }
         else
           {
            g_trade_status = "Main + Hedge positions active";
           }
        }
      return;
     }

   if(g_hedge_placed)
     {
      double main_close_profit = 0.0;
      const bool main_closed_with_result = GetClosedPositionProfit(g_main_ticket, main_close_profit);

      if(main_closed_with_result && main_close_profit >= 0.0)
        {
         g_trade_status = "Main closed in profit. Closing hedge...";
         if(g_trade.PositionClose(g_hedge_ticket))
           {
            PrintFormat("[SEEFactor] Main closed at %.2f and hedge was closed with it.", main_close_profit);
            StartCooldown("Main TP + hedge handled. Next in " + IntegerToString(InpCooldownSeconds) + "s");
           }
         else
           {
            g_trade_status = "Main profit close; hedge close failed: " + g_trade.ResultRetcodeDescription();
           }
        }
      else
        {
         g_main_placed = false;
         g_trade_status = "Main closed. Hedge cycle active.";
        }
      return;
     }

   if(g_hedge_pending)
      CancelHedgePending();

  // Position closed — find the closing deal profit
  double close_profit = 0.0;
  GetClosedPositionProfit(g_main_ticket, close_profit);

   if(close_profit >= 0.0)
     {
      PrintFormat("[SEEFactor] Main closed at profit %.2f. Starting cooldown.", close_profit);
      StartCooldown("Cycle done (profit). Next in " + IntegerToString(InpCooldownSeconds) + "s");
      return;
     }

   PrintFormat("[SEEFactor] Main closed at loss %.2f and no hedge position opened.", close_profit);
   StartCooldown("Main loss without hedge fill. Next in " + IntegerToString(InpCooldownSeconds) + "s");
  }

bool RunBasketSafety()
  {
  if(!InpUseBasketSafety)
    return false;

  // In crossover architecture, exits are the shared A/D levels.
  // Do not interrupt an active main+hedge cycle with basket thresholds.
  if(InpAutoBestHedge && InpKeepMainOpenOnHedge && g_main_placed && g_hedge_placed)
    return false;

  const double basket_tp_usd = EffectiveBasketTakeProfitUsd();
  const double basket_sl_usd = EffectiveBasketStopLossUsd();

  const bool has_main_now  = g_main_placed  && SelectTrackedPosition(g_main_ticket,  "SEEFactor-Main");
  const bool has_hedge_now = g_hedge_placed && SelectTrackedPosition(g_hedge_ticket, "SEEFactor-Hedge");

  if(!has_main_now && !has_hedge_now)
    return false;

  double basket_pnl = 0.0;
  if(has_main_now)  basket_pnl += GetPositionNetPnl(g_main_ticket);
  if(has_hedge_now) basket_pnl += GetPositionNetPnl(g_hedge_ticket);

  const string pnl_str = DoubleToString(basket_pnl, 2);

  if(basket_tp_usd > 0.0 && basket_pnl >= basket_tp_usd)
    {
     g_trade_status = "Basket TP (" + pnl_str + "). Closing all...";
     bool ok = true;
     if(has_main_now)  ok = g_trade.PositionClose(g_main_ticket)  && ok;
     if(has_hedge_now) ok = g_trade.PositionClose(g_hedge_ticket) && ok;
     if(ok)
       {
        PrintFormat("[SEEFactor] Basket closed at TP %.2f", basket_pnl);
        StartCooldown("Basket TP (" + pnl_str + "). Next in " + IntegerToString(InpCooldownSeconds) + "s");
       }
     else
        g_trade_status = "Basket TP close failed: " + g_trade.ResultRetcodeDescription();
     return true;
    }

  if(basket_sl_usd > 0.0 && basket_pnl <= -MathAbs(basket_sl_usd))
    {
     g_trade_status = "Basket SL (" + pnl_str + "). Closing all...";
     bool ok = true;
     if(has_main_now)  ok = g_trade.PositionClose(g_main_ticket)  && ok;
     if(has_hedge_now) ok = g_trade.PositionClose(g_hedge_ticket) && ok;
     if(ok)
       {
        PrintFormat("[SEEFactor] Basket closed at SL %.2f", basket_pnl);
        StartCooldown("Basket SL (" + pnl_str + "). Next in " + IntegerToString(InpCooldownSeconds) + "s");
       }
     else
        g_trade_status = "Basket SL close failed: " + g_trade.ResultRetcodeDescription();
     return true;
    }

  return false;
  }

void SyncMainToCrossoverStops()
  {
  if(!InpAutoBestHedge || !InpKeepMainOpenOnHedge)
    return;
  if(!g_main_placed || !g_hedge_placed || g_main_ticket == 0)
    return;
  if(g_hedge_sl_price <= 0.0 || g_hedge_tp_price <= 0.0)
    return;
  if(!SelectTrackedPosition(g_main_ticket, "SEEFactor-Main"))
    return;

  const double target_main_tp = g_hedge_sl_price; // A level (TP1 = SL2)
  const double target_main_sl = g_hedge_tp_price; // D level (SL1 = TP2)

  double safe_sl = 0.0;
  double safe_tp = 0.0;
  BuildBrokerSafeStops(InpMainSide, target_main_sl, target_main_tp, safe_sl, safe_tp);
  if(safe_sl <= 0.0 || safe_tp <= 0.0)
    return;

  const double cur_sl = PositionGetDouble(POSITION_SL);
  const double cur_tp = PositionGetDouble(POSITION_TP);
  const bool need_update = (MathAbs(cur_sl - safe_sl) > (_Point * 1.5))
                           || (MathAbs(cur_tp - safe_tp) > (_Point * 1.5));
  if(!need_update)
    return;

  if(g_trade.PositionModify(g_main_ticket, safe_sl, safe_tp))
    {
    g_main_emergency_sl = safe_sl;
    g_main_tp_actual = safe_tp;
    g_trade_status = "Main synced to crossover A/D exits";
    }
  }

void ManageOpenHedge()
  {
  if(!g_hedge_placed || g_hedge_ticket == 0)
    return;

  if(!SelectTrackedPosition(g_hedge_ticket, "SEEFactor-Hedge"))
    return;

  if(g_hedge_be_locked || g_hedge_be_price <= 0.0)
    return;

  const long position_type = PositionGetInteger(POSITION_TYPE);
  const double market_price = (position_type == POSITION_TYPE_BUY)
                     ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                     : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

  const bool reached_be = (position_type == POSITION_TYPE_BUY)
                  ? (market_price >= g_hedge_be_price)
                  : (market_price <= g_hedge_be_price);

  if(!reached_be)
    return;

  if(InpExitHedgeAtBeTarget)
    {
    if(InpKeepMainOpenOnHedge)
      {
       g_trade_status = "Closing main+hedge basket at BE target...";
       if(!SelectTrackedPosition(g_main_ticket, "SEEFactor-Main"))
         {
          g_trade_status = "Basket close skipped: main not found";
          return;
         }

       if(!g_trade.PositionClose(g_main_ticket))
         {
          g_trade_status = "Main basket close failed: " + g_trade.ResultRetcodeDescription();
          return;
         }

       if(g_trade.PositionClose(g_hedge_ticket))
          PrintFormat("[SEEFactor] Basket closed at BE target %.5f", market_price);
       else
          g_trade_status = "Hedge basket close failed: " + g_trade.ResultRetcodeDescription();
      }
    else
      {
       g_trade_status = "Closing hedge at BE target...";
       if(g_trade.PositionClose(g_hedge_ticket))
         PrintFormat("[SEEFactor] Hedge closed at BE target %.5f", market_price);
       else
         g_trade_status = "Hedge BE close failed: " + g_trade.ResultRetcodeDescription();
      }
    return;
    }

  double safe_sl = 0.0;
  double safe_tp = 0.0;
  const TradeSide hedge_side = (position_type == POSITION_TYPE_BUY) ? SideBuy : SideSell;
  BuildBrokerSafeStops(hedge_side, g_hedge_be_price, g_hedge_tp_price, safe_sl, safe_tp);

  if(safe_sl <= 0.0)
    return;

  if(g_trade.PositionModify(g_hedge_ticket, safe_sl, safe_tp))
    {
    g_hedge_be_locked = true;
    g_trade_status = "Hedge BE locked at " + DoubleToString(safe_sl, _Digits);
    PrintFormat("[SEEFactor] Hedge BE locked. SL moved to %.5f", safe_sl);
    }
  }

//--- Reset all cycle state and start the cooldown timer
void StartCooldown(const string reason)
  {
   const bool pending_cleared = CancelHedgePending() && CancelAllHedgePendings();
   if(!pending_cleared)
     {
      g_main_placed    = false;
      g_hedge_placed   = false;
      g_main_ticket    = 0;
      g_hedge_ticket   = 0;
      g_trade_status   = "Cycle close blocked: pending hedge not cleared";
      Print("[SEEFactor] ", g_trade_status);
      return;
     }

   g_cooldown_until = TimeCurrent() + InpCooldownSeconds;
   g_main_placed    = false;
   g_hedge_placed   = false;
   g_hedge_pending  = false;
   g_main_ticket    = 0;
   g_hedge_ticket   = 0;
   g_hedge_order_ticket = 0;
  g_main_lots_actual = 0.0;
  g_main_virtual_sl = 0.0;
  g_main_emergency_sl = 0.0;
  g_hedge_entry_actual = 0.0;
  g_hedge_lots_actual = 0.0;
  g_hedge_sl_price  = 0.0;
  g_hedge_be_price  = 0.0;
  g_hedge_tp_price  = 0.0;
  g_hedge_be_locked = false;
   g_trade_status   = reason;
   PrintFormat("[SEEFactor] %s  (cooldown %ds)", reason, InpCooldownSeconds);
  }

//--- Monitor the open hedge; when it closes, start the cooldown
void CheckHedgeClose()
  {
   if(g_hedge_ticket == 0) return;

   // Still open — nothing to do
  if(SelectTrackedPosition(g_hedge_ticket, "SEEFactor-Hedge"))
      return;

   double close_profit = 0.0;
   if(HistorySelectByPosition(g_hedge_ticket))
     {
      const int total = HistoryDealsTotal();
      for(int i = total - 1; i >= 0; i--)
        {
         const ulong deal = HistoryDealGetTicket(i);
         if((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID) != g_hedge_ticket)
            continue;
         if(HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_OUT)
           {
            close_profit = HistoryDealGetDouble(deal, DEAL_PROFIT)
                           + HistoryDealGetDouble(deal, DEAL_SWAP)
                           + HistoryDealGetDouble(deal, DEAL_COMMISSION);
            break;
           }
        }
     }

   if(SelectTrackedPosition(g_main_ticket, "SEEFactor-Main"))
     {
      g_trade_status = "Hedge closed; main still open.";
      PrintFormat("[SEEFactor] Hedge closed (PnL=%.2f) but main still open; cycle not finished.", close_profit);
      return;
     }

   PrintFormat("[SEEFactor] Hedge closed. PnL=%.2f. Starting cooldown.", close_profit);
   const string label = close_profit >= 0.0
                        ? "Hedge TP hit (+" + DoubleToString(close_profit, 2) + "). Next in " + IntegerToString(InpCooldownSeconds) + "s"
                        : "Hedge closed (" + DoubleToString(close_profit, 2) + "). Next in " + IntegerToString(InpCooldownSeconds) + "s";
   StartCooldown(label);
  }

string BuildScenarioReport()
  {
   int row = 0;

   const double point_money = MoneyPerPointPerLot();
   if(point_money <= 0.0)
     {
      SetPanelLine(row++, "SEEFactors | Hedge Visualizer", clrWhite);
      SetPanelLine(row++, "Cannot calculate: invalid symbol tick settings.", clrRed);
      ClearPanelLines(row, 60);
      return "Cannot calculate: invalid symbol tick settings.";
     }

   const TradeSide main_side = InpMainSide;
   const TradeSide hedge_side = (main_side == SideBuy) ? SideSell : SideBuy;

   const double live_entry = CurrentReferencePrice(main_side);
  double main_entry = InpDynamicFromMarket ? live_entry : SafePrice(InpEntryPrice, live_entry);

   double main_tp = 0.0;
   double main_sl = 0.0;
   if(InpDynamicFromMarket)
     {
      if(InpMainTpPoints <= 0.0 || InpMainSlPoints <= 0.0)
        {
         SetPanelLine(row++, "SEEFactors | Hedge Visualizer", clrWhite);
         SetPanelLine(row++, "Set dynamic main TP/SL points > 0.", clrRed);
         ClearPanelLines(row, 60);
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
         ClearPanelLines(row, 60);
         return "Set main TP and SL prices to visualize outcomes.";
        }
     }

      if(InpAutoTrade && (g_main_placed || g_main_entry_actual > 0.0))
        {
        main_entry = g_main_entry_actual;
        if(g_main_tp_actual > 0.0)
          main_tp = g_main_tp_actual;
        const double live_main_trigger = (g_main_virtual_sl > 0.0) ? g_main_virtual_sl : g_main_sl_actual;
        if(live_main_trigger > 0.0)
          main_sl = live_main_trigger;
        }

  const double requested_main_lots = RequestedMainLots(main_entry, main_sl);
  double main_lots = EffectiveMainLots(main_entry, main_sl);
  if(InpAutoTrade && g_main_lots_actual > 0.0)
    main_lots = g_main_lots_actual;

  if(main_lots <= 0.0)
     {
      SetPanelLine(row++, "SEEFactors | Hedge Visualizer", clrWhite);
    SetPanelLine(row++, "Stake settings invalid. Check lots/USD risk.", clrRed);
      ClearPanelLines(row, 60);
    return "Stake settings invalid. Check lots/USD risk.";
     }

  const double main_tp_money = TradePnlMoney(main_side, main_entry, main_tp, main_lots);
  const double main_sl_money = TradePnlMoney(main_side, main_entry, main_sl, main_lots);
  const double main_risk_usd = MainRiskUsd(main_entry, main_sl, main_lots);
  const double main_risk_pct = MainRiskPctOfStake(main_entry, main_sl, main_lots);

   double hedge_entry = 0.0;
   double hedge_tp_money = 0.0;
   double hedge_sl_money = 0.0;
   double hedge_at_main_sl_money = 0.0;
  double hedge_at_main_tp_money = 0.0;

    double hedge_manual_lots = NormalizeLots(main_lots * InpHedgeLotsRatio);
    if(InpAutoTrade && g_hedge_lots_actual > 0.0)
      hedge_manual_lots = g_hedge_lots_actual;

   if(InpUseHedge && InpHedgeLotsRatio > 0.0)
     {
      hedge_entry = InpDynamicFromMarket ? main_sl : SafePrice(InpHedgeEntryPrice, main_sl);
    if(InpAutoTrade && g_main_sl_actual > 0.0)
      hedge_entry = g_main_sl_actual;
    if(InpAutoTrade && g_hedge_placed && g_hedge_entry_actual > 0.0)
      hedge_entry = g_hedge_entry_actual;
      hedge_at_main_sl_money = TradePnlMoney(hedge_side, hedge_entry, main_sl, hedge_manual_lots);
      hedge_at_main_tp_money = TradePnlMoney(hedge_side, hedge_entry, main_tp, hedge_manual_lots);

      if(InpDynamicFromMarket && InpHedgeTpPoints > 0.0)
        {
         const double hedge_tp = (InpAutoTrade && g_hedge_tp_price > 0.0)
                                 ? g_hedge_tp_price
                                 : PriceByPoints(hedge_side, hedge_entry, InpHedgeTpPoints, true);
         hedge_tp_money = TradePnlMoney(hedge_side, hedge_entry, hedge_tp, hedge_manual_lots);
        }
      else if(InpHedgeTakeProfit > 0.0)
         hedge_tp_money = TradePnlMoney(hedge_side, hedge_entry, NormalizePrice(InpHedgeTakeProfit), hedge_manual_lots);

      if(InpDynamicFromMarket && InpHedgeSlPoints > 0.0)
        {
         const double hedge_sl = (InpAutoTrade && g_hedge_sl_price > 0.0)
                                 ? g_hedge_sl_price
                                 : PriceByPoints(hedge_side, hedge_entry, InpHedgeSlPoints, false);
         hedge_sl_money = TradePnlMoney(hedge_side, hedge_entry, hedge_sl, hedge_manual_lots);
        }
      else if(InpHedgeStopLoss > 0.0)
         hedge_sl_money = TradePnlMoney(hedge_side, hedge_entry, NormalizePrice(InpHedgeStopLoss), hedge_manual_lots);
     }

  const double net_loss_scenario = main_sl_money + hedge_at_main_sl_money;
  const double net_main_tp_with_hedge_reversal = main_tp_money + hedge_at_main_tp_money;
  const double net_main_tp_with_hedge_sl = main_tp_money + hedge_sl_money;
  const double net_main_sl_with_hedge_tp = main_sl_money + hedge_tp_money;
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
   double tp_points_needed     = 0.0;

   bool best_hedge_valid = false;
   if(InpAutoBestHedge)
     {
      best_hedge_trigger = main_sl;
      if(InpAutoTrade && g_main_sl_actual > 0.0)
        best_hedge_trigger = g_main_sl_actual;
      string solve_reason;
      double best_hedge_sl = 0.0;
      if(ComputeAutoBestHedgePlan(main_entry,
                                  best_hedge_trigger,
                                  main_tp,
                                  main_lots,
                                  best_hedge_lots,
                                  best_hedge_sl,
                                  best_hedge_be_price,
                                  best_hedge_tp,
                                  be_points_needed,
                                  tp_points_needed,
                                  solve_reason))
        {
         if(InpAutoTrade && g_hedge_lots_actual > 0.0)
            best_hedge_lots = g_hedge_lots_actual;
         if(InpAutoTrade && g_hedge_be_price > 0.0)
            best_hedge_be_price = g_hedge_be_price;
         if(InpAutoTrade && g_hedge_tp_price > 0.0)
            best_hedge_tp = g_hedge_tp_price;

         hedge_pnl_per_lot_tp = TradePnlMoney(hedge_side, best_hedge_trigger, best_hedge_tp, 1.0);
         if(InpKeepMainOpenOnHedge)
           {
            best_net_if_tp = TradePnlMoney(main_side, main_entry, best_hedge_tp, main_lots)
                             + TradePnlMoney(hedge_side, best_hedge_trigger, best_hedge_tp, best_hedge_lots);
            best_net_if_be = TradePnlMoney(main_side, main_entry, best_hedge_be_price, main_lots)
                             + TradePnlMoney(hedge_side, best_hedge_trigger, best_hedge_be_price, best_hedge_lots);
           }
         else
           {
            const double main_loss_at_trigger = main_sl_money;
            best_net_if_tp = main_loss_at_trigger + TradePnlMoney(hedge_side, best_hedge_trigger, best_hedge_tp, best_hedge_lots);
            best_net_if_be = main_loss_at_trigger + TradePnlMoney(hedge_side, best_hedge_trigger, best_hedge_be_price, best_hedge_lots);
           }
         best_hedge_valid = true;
        }
     }

   string report = "SEEFactors | Hedge Scenario Visualizer\n";
   report += "Symbol: " + _Symbol + " | Main Side: " + SideToText(main_side) + "\n";
  report += "Stake: " + DoubleToString(main_lots, 2) + " lots"
         + (InpStakeInUsd ? (" (from $" + DoubleToString(InpStakeUsd, 2) + " risk)") : "") + "\n";
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
            report += "A level (TP1=SL2): " + DoubleToString(best_hedge_be_price, _Digits)
            + " | D level (SL1=TP2): " + DoubleToString(best_hedge_tp, _Digits) + "\n";
      report += "Suggested Hedge Lots: " + DoubleToString(best_hedge_lots, 2)
            + " (minimum that protects D-path)\n";
      if(InpKeepMainOpenOnHedge)
         report += "Basket @ A path: " + DoubleToString(best_net_if_be, 2)
           + " | Basket @ D path: " + DoubleToString(best_net_if_tp, 2);
      else
         report += "Net @ A path: " + DoubleToString(best_net_if_be, 2)
           + " | Net @ D path: " + DoubleToString(best_net_if_tp, 2);
     }

   const double live_close   = CurrentClosePrice(main_side);
  const double floating_pnl = TradePnlMoney(main_side, main_entry, live_close, main_lots);
   const string sep = "------------------------------------";

   SetPanelLine(row++, "=== SEEFactors  Hedge Visualizer ===", clrWhite);
  SetPanelLine(row++, _Symbol + "  " + SideToText(main_side) + "  " + DoubleToString(main_lots, 2) + " lots"
           + (InpStakeInUsd ? ("  ($" + DoubleToString(InpStakeUsd, 2) + " risk)") : ""), clrWhite);
   if(MathAbs(requested_main_lots - main_lots) >= 0.01)
      SetPanelLine(row++, "Requested lots: " + DoubleToString(requested_main_lots, 2)
                   + "  ->  scaled to " + DoubleToString(main_lots, 2), clrYellow);
   SetPanelLine(row++, "Live price : " + DoubleToString(live_close, _Digits) + "   Entry: " + DoubleToString(main_entry, _Digits), clrSilver);

   SetPanelLine(row++, "FLOATING PnL : " + (floating_pnl >= 0 ? "+" : "") + DoubleToString(floating_pnl, 2), PnlColor(floating_pnl));
   if(InpAutoTrade && g_hedge_placed)
     {
      const double basket_live = GetPositionNetPnl(g_main_ticket) + GetPositionNetPnl(g_hedge_ticket);
      const double basket_tp_usd = EffectiveBasketTakeProfitUsd();
      const double basket_sl_usd = EffectiveBasketStopLossUsd();
      SetPanelLine(row++, "BASKET PnL   : " + (basket_live >= 0 ? "+" : "") + DoubleToString(basket_live, 2)
           + "   TP=$" + DoubleToString(basket_tp_usd, 2)
           + "  SL=-$" + DoubleToString(basket_sl_usd, 2), PnlColor(basket_live));
     }
   SetPanelLine(row++, sep, clrDimGray);

   SetPanelLine(row++, "MAIN TRADE", clrWhite);
  // When auto-scaling is on the risk % may still exceed the cap (broker minimum floor) — show in yellow, not red.
  color main_risk_color = (InpMaxMainRiskPctStake <= 0.0 || main_risk_pct <= InpMaxMainRiskPctStake)
                          ? clrSilver
                          : (InpAutoScaleMainLots ? clrYellow : clrRed);
  SetPanelLine(row++, "  Risk: $" + DoubleToString(main_risk_usd, 2) + "  (" + DoubleToString(main_risk_pct, 1) + "% of stake)"
               + (InpAutoScaleMainLots && main_risk_pct > InpMaxMainRiskPctStake ? "  [min-lot floor]" : ""),
               main_risk_color);
   SetPanelLine(row++, "  TP " + DoubleToString(main_tp, _Digits) + "  =>  " + (main_tp_money >= 0 ? "+" : "") + DoubleToString(main_tp_money, 2), PnlColor(main_tp_money));
   SetPanelLine(row++, "  SL " + DoubleToString(main_sl, _Digits) + "  =>  " + DoubleToString(main_sl_money, 2), PnlColor(main_sl_money));
   SetPanelLine(row++, sep, clrDimGray);

   SetPanelLine(row++, "HEDGE  (" + SideToText(hedge_side) + ")", clrWhite);
   if(InpUseHedge && InpHedgeLotsRatio > 0.0)
     {
      SetPanelLine(row++, "  Entry : " + DoubleToString(hedge_entry, _Digits) + "   Lots: " + DoubleToString(hedge_manual_lots, 2) + " (" + DoubleToString(InpHedgeLotsRatio * 100.0, 0) + "% of stake)", clrSilver);
      SetPanelLine(row++, "  @ Main-SL : " + (hedge_at_main_sl_money >= 0 ? "+" : "") + DoubleToString(hedge_at_main_sl_money, 2), PnlColor(hedge_at_main_sl_money));

      if(InpHedgeTakeProfit > 0.0 || (InpDynamicFromMarket && InpHedgeTpPoints > 0.0))
         SetPanelLine(row++, "  Hedge TP  : +" + DoubleToString(hedge_tp_money, 2), PnlColor(hedge_tp_money));

      if(InpHedgeStopLoss > 0.0 || (InpDynamicFromMarket && InpHedgeSlPoints > 0.0))
         SetPanelLine(row++, "  Hedge SL  : " + DoubleToString(hedge_sl_money, 2), PnlColor(hedge_sl_money));

      SetPanelLine(row++, "  Net @ hedge trigger : " + (net_loss_scenario >= 0 ? "+" : "") + DoubleToString(net_loss_scenario, 2), PnlColor(net_loss_scenario));
      SetPanelLine(row++, "  Net (main TP + hedge @mainTP) : " + (net_main_tp_with_hedge_reversal >= 0 ? "+" : "") + DoubleToString(net_main_tp_with_hedge_reversal, 2), PnlColor(net_main_tp_with_hedge_reversal));
      SetPanelLine(row++, "  Net (main TP + hedge SL) : " + (net_main_tp_with_hedge_sl >= 0 ? "+" : "") + DoubleToString(net_main_tp_with_hedge_sl, 2), PnlColor(net_main_tp_with_hedge_sl));
      SetPanelLine(row++, "  Net (main SL + hedge TP) : " + (net_main_sl_with_hedge_tp >= 0 ? "+" : "") + DoubleToString(net_main_sl_with_hedge_tp, 2), PnlColor(net_main_sl_with_hedge_tp));
     }
   else
     {
      SetPanelLine(row++, "  Hedge disabled", clrDimGray);
     }

   if(net_loss_scenario < 0.0)
      SetPanelLine(row++, "  Recovery lots needed : " + DoubleToString(required_recovery_lots, 2), clrYellow);
   SetPanelLine(row++, sep, clrDimGray);

   SetPanelLine(row++, "AUTO BEST HEDGE  (" + SideToText(hedge_side) + ")", clrWhite);
   if(!InpAutoBestHedge)
      SetPanelLine(row++, "  Disabled", clrDimGray);
   else if(!best_hedge_valid)
      SetPanelLine(row++, "  Unavailable - check points/targets", clrRed);
   else
     {
      SetPanelLine(row++, "  Trigger      : " + DoubleToString(best_hedge_trigger, _Digits), clrSilver);
      SetPanelLine(row++, "  A (TP1=SL2)  : " + DoubleToString(best_hedge_be_price, _Digits), clrYellow);
      SetPanelLine(row++, "  D (SL1=TP2)  : " + DoubleToString(best_hedge_tp, _Digits), clrSilver);
      SetPanelLine(row++, "  Lots         : " + DoubleToString(best_hedge_lots, 2) + "  [dynamic crossover]", clrYellow);
    SetPanelLine(row++, "  C->A distance: " + DoubleToString(be_points_needed, 0) + " pts", clrSilver);
    SetPanelLine(row++, "  C->D distance: " + DoubleToString(tp_points_needed, 0) + " pts", clrLime);
      if(InpKeepMainOpenOnHedge)
        {
         SetPanelLine(row++, "  Basket @ A path  : " + (best_net_if_be >= 0 ? "+" : "") + DoubleToString(best_net_if_be, 2), PnlColor(best_net_if_be));
         SetPanelLine(row++, "  Basket @ D path  : " + (best_net_if_tp >= 0 ? "+" : "") + DoubleToString(best_net_if_tp, 2), PnlColor(best_net_if_tp));
        }
      else
        {
         SetPanelLine(row++, "  Net @ A path     : " + (best_net_if_be >= 0 ? "+" : "") + DoubleToString(best_net_if_be, 2), PnlColor(best_net_if_be));
         SetPanelLine(row++, "  Net @ D path     : " + (best_net_if_tp >= 0 ? "+" : "") + DoubleToString(best_net_if_tp, 2), PnlColor(best_net_if_tp));
        }
     }
   SetPanelLine(row++, sep, clrDimGray);

   SetPanelLine(row++, "SCENARIO SIMULATOR  (start: $" + DoubleToString(InpSimBalance, 2) + ")", clrWhite);

   const double sim = InpSimBalance;

   const double s1 = sim + main_tp_money;
   SetPanelLine(row++, "  A) Main TP only           => $" + DoubleToString(s1, 2), PnlColor(s1 - sim));

  const double s2 = sim + net_main_tp_with_hedge_sl;
  SetPanelLine(row++, "  B) Main TP + Hedge SL     => $" + DoubleToString(s2, 2), PnlColor(s2 - sim));

  double s3 = sim + net_main_sl_with_hedge_tp;
  if(best_hedge_valid)
    s3 = sim + best_net_if_tp;
  SetPanelLine(row++, "  C) B->C->D (TP2 + SL1)     => $" + DoubleToString(s3, 2), PnlColor(s3 - sim));

  double s4 = sim;
  if(best_hedge_valid)
    {
    if(InpKeepMainOpenOnHedge)
      s4 += TradePnlMoney(main_side, main_entry, best_hedge_be_price, main_lots)
          + TradePnlMoney(hedge_side, best_hedge_trigger, best_hedge_be_price, best_hedge_lots);
    else
      s4 += main_sl_money + TradePnlMoney(hedge_side, best_hedge_trigger, best_hedge_be_price, best_hedge_lots);
    }
  else if(InpUseHedge && InpHedgeLotsRatio > 0.0)
    s4 += main_sl_money + hedge_sl_money;
  SetPanelLine(row++, "  D) B->C->A (TP1 + SL2)     => $" + DoubleToString(s4, 2), PnlColor(s4 - sim));

   const double s5 = sim + floating_pnl;
   SetPanelLine(row++, "  E) Close now (floating)    => $" + DoubleToString(s5, 2), PnlColor(floating_pnl));

   const double worst_pct = (sim > 0.0) ? ((s4 - sim) / sim * 100.0) : 0.0;
   const double best_pct  = (sim > 0.0) ? ((s3 - sim) / sim * 100.0) : 0.0;
   SetPanelLine(row++, "  Best: " + (best_pct >= 0 ? "+" : "") + DoubleToString(best_pct, 1) + "%"
                + "   Min (BE): " + (worst_pct >= 0 ? "+" : "") + DoubleToString(worst_pct, 1) + "%", clrYellow);

   SetPanelLine(row++, sep, clrDimGray);

   string verdict;
   color verdict_color;
   if(floating_pnl > 0.0)
     {
      verdict = ">> IN PROFIT  - Hold / Trail SL <<";
      verdict_color = clrLime;
     }
   else if(floating_pnl == 0.0)
     {
      verdict = ">> BREAK EVEN  - Watch closely <<";
      verdict_color = clrYellow;
     }
   else if(floating_pnl > main_sl_money * 0.5)
     {
      verdict = ">> EARLY LOSS  - Monitor hedge <<";
      verdict_color = clrOrange;
     }
   else if(floating_pnl > main_sl_money)
     {
      verdict = ">> IN LOSS  - Activate hedge now! <<";
      verdict_color = clrRed;
     }
   else
     {
      verdict = ">> AT/BEYOND SL  - Hedge is URGENT <<";
      verdict_color = clrRed;
     }

   SetPanelLine(row++, verdict, verdict_color);
   SetPanelLine(row++, sep, clrDimGray);

   SetPanelLine(row++, "TRADE EXECUTION", clrWhite);
   if(!InpAutoTrade)
     {
      SetPanelLine(row++, "  Auto-trade: OFF  (enable InpAutoTrade to go live)", clrDimGray);
     }
   else if(g_cooldown_until > 0 && TimeCurrent() < g_cooldown_until)
     {
      const int secs_left = (int)(g_cooldown_until - TimeCurrent());
      SetPanelLine(row++, "  COOLDOWN: " + IntegerToString(secs_left) + "s until next cycle", clrYellow);
      SetPanelLine(row++, "  " + g_trade_status, clrSilver);
     }
   else
     {
      const color status_color = (g_main_placed || g_hedge_placed) ? clrLime : clrYellow;
      SetPanelLine(row++, "  " + g_trade_status, status_color);
      if(g_main_placed)
        SetPanelLine(row++, StringFormat("  Main  #%d  entry=%.5f  trigger=%.5f  TP=%.5f",
                              (long)g_main_ticket, g_main_entry_actual,
                              g_main_sl_actual, g_main_tp_actual), clrSilver);
      if(g_main_placed && InpKeepMainOpenOnHedge && g_main_emergency_sl > 0.0)
        SetPanelLine(row++, "  Main emergency SL: " + DoubleToString(g_main_emergency_sl, _Digits), clrDimGray);
      if(g_hedge_pending)
        SetPanelLine(row++, "  Hedge pending #" + IntegerToString((long)g_hedge_order_ticket)
                 + "  trigger=" + DoubleToString((g_main_virtual_sl > 0.0 ? g_main_virtual_sl : g_main_sl_actual), _Digits)
                 + "  lots=" + DoubleToString(g_hedge_lots_actual, 2), clrYellow);
      if(g_hedge_placed)
         SetPanelLine(row++, "  Hedge #" + IntegerToString((long)g_hedge_ticket) + "  active", clrYellow);
      if((g_hedge_pending || g_hedge_placed) && g_hedge_sl_price > 0.0)
        SetPanelLine(row++, "  Hedge SL     : " + DoubleToString(g_hedge_sl_price, _Digits), clrSilver);
              if(g_hedge_placed && g_hedge_be_price > 0.0)
                SetPanelLine(row++, "  Hedge BE lock: " + DoubleToString(g_hedge_be_price, _Digits)
                         + (g_hedge_be_locked ? "  [LOCKED]" : "  [waiting]"), g_hedge_be_locked ? clrLime : clrSilver);
     }

   // Entry path guard status — always shown so user can see whether next entry is free or blocked
   {
      string guard_reason;
    const double guard_lots = EffectiveMainLots(main_entry, main_sl);
    bool guard_ok = (guard_lots > 0.0) && ValidateEntryProfitPaths(main_entry, main_sl, main_tp, guard_lots, guard_reason);
    const double panel_main_risk_pct = MainRiskPctOfStake(main_entry, main_sl, guard_lots);
    const double panel_main_risk_usd = MainRiskUsd(main_entry, main_sl, guard_lots);
    // Only block in the guard when NOT auto-scaling (same logic as PlaceMainTrade).
    if(!InpAutoScaleMainLots && guard_ok && InpMaxMainRiskPctStake > 0.0 && panel_main_risk_pct > InpMaxMainRiskPctStake)
      {
      guard_ok = false;
      guard_reason = StringFormat("main risk %.2f%% ($%.2f) > max %.2f%%", panel_main_risk_pct, panel_main_risk_usd, InpMaxMainRiskPctStake);
      }
    if(guard_lots <= 0.0)
      {
       guard_ok = false;
       guard_reason = "scaled lots invalid for current stake/risk cap";
      }
      SetPanelLine(row++, sep, clrDimGray);
    if(!InpUseEntryPathGuard && guard_ok)
      SetPanelLine(row++, "  Entry guard : OFF  (feasibility-only mode)", clrDimGray);
      else if(guard_ok)
         SetPanelLine(row++, "  Entry guard : OK - entry allowed", clrLime);
      else
         SetPanelLine(row++, "  Entry guard : BLOCKED - " + guard_reason, clrRed);
   }

   ClearPanelLines(row, 60);

   return report;
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(10);
   ScanExistingPositions();
   
   if(InpOpeningBalance <= 0.0)
     {
      g_opening_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      PrintFormat("[SEEFactor] Opening balance auto-set to %.2f", g_opening_balance);
     }
   else
     {
      g_opening_balance = InpOpeningBalance;
      PrintFormat("[SEEFactor] Opening balance set to %.2f", g_opening_balance);
     }
   
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   for(int row = 0; row <= 60; row++)
      ObjectDelete(0, SF_PANEL_PREFIX + IntegerToString(row));

   Comment("");
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   SyncTradeState();

   if(InpAutoTrade)
     {
      // Cooldown between cycles
      if(g_cooldown_until > 0)
        {
         if(TimeCurrent() >= g_cooldown_until)
            g_cooldown_until = 0;   // cooldown expired — allow next cycle
         // else: still waiting, skip trade logic this tick
        }

      RunBasketSafety();

      if(g_cooldown_until == 0)
        {
         if(!g_main_placed && !g_hedge_placed && !g_hedge_pending)
            PlaceMainTrade();
         else if(g_main_placed)
            CheckAndPlaceHedge();
         else if(g_hedge_pending)
            CheckAndPlaceHedge();
        }

      // Hedge management must run even while main and hedge are both open.
      if(g_hedge_placed)
        {
         SyncMainToCrossoverStops();
         ManageOpenHedge();
         CheckHedgeClose();
        }
     }

   const string report = BuildScenarioReport();
   if(InpShowCommentText)
      Comment(report);
   else
      Comment("");
  }
//+------------------------------------------------------------------+
