// Input parameters
input int    EMA_Fast_Period = 5;        // Fast EMA Period
input int    EMA_Slow_Period = 12;       // Slow EMA Period
input int    EMA_Trend_Period = 50;      // Trend EMA Period
input int    MACD_Fast = 12;             // MACD Fast EMA
input int    MACD_Slow = 26;             // MACD Slow EMA
input int    MACD_Signal = 9;            // MACD Signal Line
input int    ATR_Period = 14;            // ATR Period
input double Risk_Per_Trade = 0.01;      // Risk per trade (1%)
input double Max_Daily_Drawdown = 0.04;  // Max daily drawdown (4%)
input int    Max_Daily_Trades = 3;       // Max trades per day
input double Trailing_Trigger = 1.0;      // Trailing stop trigger (ATR multiplier)
input double Trailing_Distance = 1.5;     // Trailing stop distance (ATR multiplier)
input int    Trading_Hour_Start = 8;      // Trading start hour (GMT)
input int    Trading_Hour_End = 16;       // Trading end hour (GMT)

// Include trade library
#include <Trade\Trade.mqh>
CTrade trade;

// Global variables
double balance_start_day;
datetime last_trade_date;
int trade_count_today;
double daily_pnl;
int log_file_handle = INVALID_HANDLE;

// Structure for virtual stops
struct VirtualStop {
   ulong ticket;
   double virtual_sl;
   double virtual_tp;
};

// Array for virtual stops
VirtualStop virtual_stops[];
int virtual_stop_count = 0;

// Structure for instruments
struct Instrument {
   string symbol;
   int handle_ema_fast;
   int handle_ema_slow;
   int handle_ema_trend;
   int handle_macd;
   int handle_atr;
};

// Array of instruments
Instrument instruments[2];

// Initialize instruments
void OnInit() {
   // Set up US100
   instruments[0].symbol = "US100";
   instruments[0].handle_ema_fast = iMA("US100", PERIOD_H1, EMA_Fast_Period, 0, ENUM_MA_METHOD::MODE_EMA, PRICE_CLOSE);
   instruments[0].handle_ema_slow = iMA("US100", PERIOD_H1, EMA_Slow_Period, 0, ENUM_MA_METHOD::MODE_EMA, PRICE_CLOSE);
   instruments[0].handle_ema_trend = iMA("US100", PERIOD_H1, EMA_Trend_Period, 0, ENUM_MA_METHOD::MODE_EMA, PRICE_CLOSE);
   instruments[0].handle_macd = iMACD("US100", PERIOD_H1, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   instruments[0].handle_atr = iATR("US100", PERIOD_H1, ATR_Period);

   // Set up XAUUSD
   instruments[1].symbol = "XAUUSD";
   instruments[1].handle_ema_fast = iMA("XAUUSD", PERIOD_H1, EMA_Fast_Period, 0, ENUM_MA_METHOD::MODE_EMA, PRICE_CLOSE);
   instruments[1].handle_ema_slow = iMA("XAUUSD", PERIOD_H1, EMA_Slow_Period, 0, ENUM_MA_METHOD::MODE_EMA, PRICE_CLOSE);
   instruments[1].handle_ema_trend = iMA("XAUUSD", PERIOD_H1, EMA_Trend_Period, 0, ENUM_MA_METHOD::MODE_EMA, PRICE_CLOSE);
   instruments[1].handle_macd = iMACD("XAUUSD", PERIOD_H1, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   instruments[1].handle_atr = iATR("XAUUSD", PERIOD_H1, ATR_Period);

   // Initialize daily tracking
   balance_start_day = AccountInfoDouble(ACCOUNT_BALANCE);
   last_trade_date = TimeCurrent();
   trade_count_today = 0;
   daily_pnl = 0;

   // Initialize logging
   log_file_handle = FileOpen("TradeLog_" + TimeToString(TimeCurrent(), TIME_DATE) + ".csv", FILE_WRITE | FILE_CSV);
   if (log_file_handle != INVALID_HANDLE) {
      FileWrite(log_file_handle, "Time,Symbol,Action,Price,Lots,SL,TP,Profit,Message");
   }

   // Set trade properties
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Initialize virtual stops
   ArrayResize(virtual_stops, 0);
   virtual_stop_count = 0;
}

void OnDeinit(const int reason) {
   // Clean up indicator handles
   for (int i = 0; i < 2; i++) {
      IndicatorRelease(instruments[i].handle_ema_fast);
      IndicatorRelease(instruments[i].handle_ema_slow);
      IndicatorRelease(instruments[i].handle_ema_trend);
      IndicatorRelease(instruments[i].handle_macd);
      IndicatorRelease(instruments[i].handle_atr);
   }

   // Close log file
   if (log_file_handle != INVALID_HANDLE) {
      FileClose(log_file_handle);
   }
}

void OnTick() {
   // Update daily tracking
   datetime current_date = TimeCurrent();
   MqlDateTime current_time_struct, last_time_struct;
   TimeToStruct(current_date, current_time_struct);
   TimeToStruct(last_trade_date, last_time_struct);
   
   if (current_time_struct.day != last_time_struct.day) {
      balance_start_day = AccountInfoDouble(ACCOUNT_BALANCE);
      trade_count_today = 0;
      daily_pnl = 0;
      last_trade_date = current_date;
      if (log_file_handle != INVALID_HANDLE) {
         FileClose(log_file_handle);
         log_file_handle = FileOpen("TradeLog_" + TimeToString(TimeCurrent(), TIME_DATE) + ".csv", FILE_WRITE | FILE_CSV);
         if (log_file_handle != INVALID_HANDLE) {
            FileWrite(log_file_handle, "Time,Symbol,Action,Price,Lots,SL,TP,Profit,Message");
         }
      }
   }

   // Check drawdown limit
   daily_pnl = AccountInfoDouble(ACCOUNT_EQUITY) - balance_start_day;
   if (daily_pnl / balance_start_day <= -Max_Daily_Drawdown) {
      LogMessage("Drawdown limit reached: " + DoubleToString(daily_pnl / balance_start_day * 100, 2) + "%");
      return;
   }

   // Check trade limit
   if (trade_count_today >= Max_Daily_Trades) {
      LogMessage("Max daily trades reached: " + IntegerToString(trade_count_today));
      return;
   }

   // Check trading hours
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   if (time.hour < Trading_Hour_Start || time.hour >= Trading_Hour_End) return;

   // Check signals, manage virtual stops, and trailing stops
   for (int i = 0; i < 2; i++) {
      CheckTradeSignal(instruments[i]);
      ManageVirtualStops(instruments[i].symbol);
      ManageTrailingStop(instruments[i].symbol);
   }
}

void CheckTradeSignal(Instrument &inst) {
   // Get indicator values
   double ema_fast[], ema_slow[], ema_trend[], macd[], signal[], atr[];
   CopyBuffer(inst.handle_ema_fast, 0, 0, 3, ema_fast);
   CopyBuffer(inst.handle_ema_slow, 0, 0, 3, ema_slow);
   CopyBuffer(inst.handle_ema_trend, 0, 0, 3, ema_trend);
   CopyBuffer(inst.handle_macd, 0, 0, 3, macd);
   CopyBuffer(inst.handle_macd, 1, 0, 3, signal);
   CopyBuffer(inst.handle_atr, 0, 0, 3, atr);

   // Check for open positions
   if (PositionSelect(inst.symbol)) return;

   double price = SymbolInfoDouble(inst.symbol, ENUM_SYMBOL_INFO_DOUBLE::SYMBOL_BID);

   // Long signal
   if (ema_fast[1] > ema_slow[1] && ema_fast[2] <= ema_slow[2] && macd[1] > 0 && atr[1] > 0 && price > ema_trend[1]) {
      double sl = price - 2 * atr[1];
      double tp = price + 3 * atr[1];
      double lots = CalculateLotSize(inst.symbol, price - sl);
      if (trade.Buy(lots, inst.symbol, price, 0, 0)) {
         trade_count_today++;
         AddVirtualStop(trade.ResultDeal(), sl, tp);
         LogMessage(inst.symbol + " BUY at " + DoubleToString(price, 5) + ", Lots: " + DoubleToString(lots, 2) +
                    ", SL: " + DoubleToString(sl, 5) + ", TP: " + DoubleToString(tp, 5));
      } else {
         LogMessage("Failed to open BUY on " + inst.symbol + ": " + trade.ResultComment());
      }
   }

   // Short signal
   if (ema_fast[1] < ema_slow[1] && ema_fast[2] >= ema_slow[2] && macd[1] < 0 && atr[1] > 0 && price < ema_trend[1]) {
      double sl = price + 2 * atr[1];
      double tp = price - 3 * atr[1];
      double lots = CalculateLotSize(inst.symbol, sl - price);
      if (trade.Sell(lots, inst.symbol, price, 0, 0)) {
         trade_count_today++;
         AddVirtualStop(trade.ResultDeal(), sl, tp);
         LogMessage(inst.symbol + " SELL at " + DoubleToString(price, 5) + ", Lots: " + DoubleToString(lots, 2) +
                    ", SL: " + DoubleToString(sl, 5) + ", TP: " + DoubleToString(tp, 5));
      } else {
         LogMessage("Failed to open SELL on " + inst.symbol + ": " + trade.ResultComment());
      }
   }
}

void ManageVirtualStops(string symbol) {
   double price = SymbolInfoDouble(symbol, ENUM_SYMBOL_INFO_DOUBLE::SYMBOL_BID);
   for (int i = virtual_stop_count - 1; i >= 0; i--) {
      if (PositionSelectByTicket(virtual_stops[i].ticket) && PositionGetString(POSITION_SYMBOL) == symbol) {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
            if (price <= virtual_stops[i].virtual_sl || price >= virtual_stops[i].virtual_tp) {
               trade.PositionClose(virtual_stops[i].ticket);
               LogMessage(symbol + " Closed BUY at " + DoubleToString(price, 5) + ", Profit: " + DoubleToString(profit, 2));
               RemoveVirtualStop(i);
            }
         } else {
            if (price >= virtual_stops[i].virtual_sl || price <= virtual_stops[i].virtual_tp) {
               trade.PositionClose(virtual_stops[i].ticket);
               LogMessage(symbol + " Closed SELL at " + DoubleToString(price, 5) + ", Profit: " + DoubleToString(profit, 2));
               RemoveVirtualStop(i);
            }
         }
      } else {
         RemoveVirtualStop(i);
      }
   }
}

void ManageTrailingStop(string symbol) {
   double atr[];
   int handle_atr = iATR(symbol, PERIOD_H1, ATR_Period);
   CopyBuffer(handle_atr, 0, 0, 1, atr);
   IndicatorRelease(handle_atr);

   for (int i = virtual_stop_count - 1; i >= 0; i--) {
      if (PositionSelectByTicket(virtual_stops[i].ticket) && PositionGetString(POSITION_SYMBOL) == symbol) {
         double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
         double current_price = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ?
                               SymbolInfoDouble(symbol, ENUM_SYMBOL_INFO_DOUBLE::SYMBOL_BID) :
                               SymbolInfoDouble(symbol, ENUM_SYMBOL_INFO_DOUBLE::SYMBOL_ASK);

         if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
            if (current_price >= open_price + Trailing_Trigger * atr[0]) {
               double new_sl = current_price - Trailing_Distance * atr[0];
               if (new_sl > virtual_stops[i].virtual_sl) {
                  virtual_stops[i].virtual_sl = new_sl;
                  LogMessage(symbol + " Updated BUY trailing SL to " + DoubleToString(new_sl, 5));
               }
            }
         } else {
            if (current_price <= open_price - Trailing_Trigger * atr[0]) {
               double new_sl = current_price + Trailing_Distance * atr[0];
               if (new_sl < virtual_stops[i].virtual_sl || virtual_stops[i].virtual_sl == 0) {
                  virtual_stops[i].virtual_sl = new_sl;
                  LogMessage(symbol + " Updated SELL trailing SL to " + DoubleToString(new_sl, 5));
               }
            }
         }
      }
   }
}

void AddVirtualStop(ulong ticket, double sl, double tp) {
   ArrayResize(virtual_stops, virtual_stop_count + 1);
   virtual_stops[virtual_stop_count].ticket = ticket;
   virtual_stops[virtual_stop_count].virtual_sl = sl;
   virtual_stops[virtual_stop_count].virtual_tp = tp;
   virtual_stop_count++;
}

void RemoveVirtualStop(int index) {
   if (index < 0 || index >= virtual_stop_count) return;
   for (int i = index; i < virtual_stop_count - 1; i++) {
      virtual_stops[i] = virtual_stops[i + 1];
   }
   virtual_stop_count--;
   ArrayResize(virtual_stops, virtual_stop_count);
}

double CalculateLotSize(string symbol, double sl_points) {
   double risk = AccountInfoDouble(ACCOUNT_BALANCE) * Risk_Per_Trade;
   double tick_size = SymbolInfoDouble(symbol, ENUM_SYMBOL_INFO_DOUBLE::SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(symbol, ENUM_SYMBOL_INFO_DOUBLE::SYMBOL_TRADE_TICK_VALUE);
   double sl_pips = sl_points / tick_size;
   double lot_size = risk / (sl_pips * tick_value);
   return NormalizeDouble(lot_size, 2);
}

void LogMessage(string message) {
   Print(message);
   if (log_file_handle != INVALID_HANDLE) {
      FileWrite(log_file_handle, TimeToString(TimeCurrent()), "", "", "", "", "", "", message);
   }
}
