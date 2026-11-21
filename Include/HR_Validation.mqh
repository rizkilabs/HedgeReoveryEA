//+------------------------------------------------------------------+
//| HR_Validation.mqh - Validasi input, akun, simbol, margin, stops  |
//+------------------------------------------------------------------+
#ifndef HR_VALIDATION_MQH
#define HR_VALIDATION_MQH

#include "HR_Config.mqh"

//--- Validasi nilai input
bool HR_ValidateInputs(string &err)
  {
   if(LotSize <= 0.0)
     { err = "LotSize harus > 0."; return false; }
   if(TakeProfitPercent <= 0.0 || TakeProfitPercent > 50.0)
     { err = "TakeProfitPercent harus > 0 dan <= 50."; return false; }
   if(RecoveryStartPosition < HR_MIN_RECOVERY_POS)
     { err = "RecoveryStartPosition minimal " + IntegerToString(HR_MIN_RECOVERY_POS) + "."; return false; }
   if(RecoveryWaitMinutes < 0)
     { err = "RecoveryWaitMinutes tidak boleh negatif."; return false; }
   if(MaxSpread < 0)
     { err = "MaxSpread tidak boleh negatif (0 = nonaktif)."; return false; }
   if(MagicNumber <= 0)
     { err = "MagicNumber harus > 0 (0 dipakai order manual)."; return false; }
   if(Slippage < 0)
     { err = "Slippage tidak boleh negatif."; return false; }
   if(MinMarginLevelWarn < 0.0)
     { err = "MinMarginLevelWarn tidak boleh negatif."; return false; }
   return true;
  }

//--- Akun harus Hedging
bool HR_ValidateAccount(string &err)
  {
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      err = "Akun bukan Hedging. EA hanya bisa berjalan pada akun Hedging.";
      return false;
     }
   return true;
  }

//--- Jumlah digit desimal dari volume step
int HR_VolumeDigits(const double step)
  {
   int d = 0;
   while(d < 8 && MathAbs(step * MathPow(10.0, d) - MathRound(step * MathPow(10.0, d))) > 1e-9)
      d++;
   return d;
  }

//--- Normalisasi volume ke step broker dan batas min/max
double HR_NormalizeVolume(const double volume)
  {
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double v    = volume;
   if(step > 0.0)
      v = MathFloor(v / step + 1e-9) * step;
   v = MathMax(vmin, MathMin(vmax, v));
   return NormalizeDouble(v, HR_VolumeDigits(step > 0.0 ? step : 0.01));
  }

//--- Normalisasi harga ke tick size broker
double HR_NormalizePrice(const double price)
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(tick > 0.0)
      return NormalizeDouble(MathRound(price / tick) * tick, digits);
   return NormalizeDouble(price, digits);
  }

//--- Jarak minimum (harga) untuk TP: max(Stop Level, Freeze Level)
double HR_MinStopDistance()
  {
   long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)MathMax(stops, freeze) * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  }

//--- Validasi simbol, lot, tick, digits, stops
bool HR_ValidateSymbol(string &err)
  {
   if(!SymbolSelect(_Symbol, true))
     { err = "Gagal memilih simbol " + _Symbol + " di Market Watch."; return false; }

   if((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
     { err = "Simbol " + _Symbol + " tidak mengizinkan trading penuh (Buy & Sell)."; return false; }

   if(SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) <= 0)
     { err = "Digits simbol tidak valid."; return false; }
   if(SymbolInfoDouble(_Symbol, SYMBOL_POINT) <= 0.0)
     { err = "Point simbol tidak valid."; return false; }
   if(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE) <= 0.0)
     { err = "Tick size simbol tidak valid."; return false; }

   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(LotSize < vmin - 1e-9 || LotSize > vmax + 1e-9)
     {
      err = StringFormat("LotSize %.4f di luar batas broker (min %.4f, max %.4f).", LotSize, vmin, vmax);
      return false;
     }
   if(step > 0.0)
     {
      double steps = LotSize / step;
      if(MathAbs(steps - MathRound(steps)) > 1e-6)
        {
         err = StringFormat("LotSize %.4f bukan kelipatan volume step %.4f.", LotSize, step);
         return false;
        }
     }
   return true;
  }

//--- Peringatan nama simbol (tidak menolak)
void HR_WarnSymbolName()
  {
   string s = _Symbol;
   StringToUpper(s);
   if(StringFind(s, "XAUUSD") != 0 && StringFind(s, "GOLD") < 0)
      HR_Alert("Simbol " + _Symbol + " bukan XAUUSD. EA dirancang untuk XAUUSD, pastikan parameter sesuai.");
  }

//--- Validasi jarak TP terhadap Stop Level / Freeze Level
bool HR_ValidateTPDistance(const double refPrice, string &err)
  {
   double tpDist  = refPrice * (TakeProfitPercent / 100.0);
   double minDist = HR_MinStopDistance();
   if(tpDist <= minDist)
     {
      err = StringFormat("Jarak TP (%.5f) <= Stop/Freeze Level broker (%.5f). Naikkan TakeProfitPercent.", tpDist, minDist);
      return false;
     }
   return true;
  }

//--- Koneksi dan izin trading
bool HR_IsTradingAllowed(string &err)
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     { err = "AutoTrading terminal nonaktif."; return false; }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     { err = "Trading dinonaktifkan untuk EA ini (cek pengaturan EA)."; return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     { err = "Trading tidak diizinkan pada akun ini."; return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
     { err = "Akun tidak mengizinkan Expert Advisor."; return false; }
   if(!MQLInfoInteger(MQL_TESTER) && !TerminalInfoInteger(TERMINAL_CONNECTED))
     { err = "Terminal tidak terhubung ke server."; return false; }
   return true;
  }

//--- Filter spread (MaxSpread = 0 -> nonaktif)
bool HR_IsSpreadOK()
  {
   if(MaxSpread <= 0)
      return true;
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= MaxSpread);
  }

//--- Margin bebas cukup untuk membuka sepasang BUY + SELL?
bool HR_HasMarginForPair(const double lot, string &err)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double mBuy = 0.0, mSell = 0.0;

   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, ask, mBuy) ||
      !OrderCalcMargin(ORDER_TYPE_SELL, _Symbol, lot, bid, mSell))
     { err = "Gagal menghitung margin (OrderCalcMargin), error " + IntegerToString(GetLastError()); return false; }

   double need = mBuy + mSell;
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(free < need)
     {
      err = StringFormat("Margin bebas %.2f tidak cukup untuk sepasang posisi (butuh %.2f).", free, need);
      return false;
     }
   return true;
  }

//--- Peringatan margin level (dibatasi sekali per 60 detik)
void HR_CheckMarginWarning()
  {
   static datetime lastWarn = 0;
   if(AccountInfoDouble(ACCOUNT_MARGIN) <= 0.0)
      return;
   double level = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(level < MinMarginLevelWarn && TimeCurrent() - lastWarn >= 60)
     {
      lastWarn = TimeCurrent();
      HR_Alert(StringFormat("PERINGATAN MARGIN: Margin Level %.1f%% di bawah batas %.1f%%.", level, MinMarginLevelWarn));
     }
  }

//--- Validasi menyeluruh saat OnInit
bool HR_ValidateAll(string &err)
  {
   if(!HR_ValidateInputs(err))  return false;
   if(!HR_ValidateAccount(err)) return false;
   if(!HR_ValidateSymbol(err))  return false;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0.0)
     { err = "Harga belum tersedia. Pastikan chart punya data tick."; return false; }

   if(!HR_ValidateTPDistance(ask, err)) return false;
   return true;
  }

#endif