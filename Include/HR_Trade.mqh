//+------------------------------------------------------------------+
//| HR_Trade.mqh - Eksekusi order, retry, anti-duplikat, TP          |
//+------------------------------------------------------------------+
#ifndef HR_TRADE_MQH
#define HR_TRADE_MQH

#include <Trade\Trade.mqh>
#include "HR_Config.mqh"
#include "HR_Validation.mqh"

#define HR_MAX_RETRY       3
#define HR_RETRY_DELAY_MS  250
#define HR_TP_RETRY_MS     1000
#define HR_LEG_RETRY_MS    2000

CTrade g_trade;
bool   g_openingLocked = false;  // true saat Close All / WAITING (diatur tahap berikutnya)
bool   g_orderBusy     = false;  // guard re-entrancy
int    g_missingLeg    = -1;     // -1 = tidak ada; POSITION_TYPE_BUY/SELL = leg yang gagal dibuka
ulong  g_orderSeq      = 0;

//--- Inisialisasi objek trade
void HR_TradeInit()
  {
   g_trade.SetExpertMagicNumber((ulong)MagicNumber);
   g_trade.SetDeviationInPoints((ulong)Slippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
  }

//--- Rotasi filling mode jika broker menolak (INVALID_FILL)
void HR_RotateFilling()
  {
   static int step = 0;
   step++;
   ENUM_ORDER_TYPE_FILLING f = ORDER_FILLING_FOK;
   if(step % 3 == 1)      f = ORDER_FILLING_IOC;
   else if(step % 3 == 2) f = ORDER_FILLING_RETURN;
   g_trade.SetTypeFilling(f);
   HR_Log("Filling mode diganti ke " + EnumToString(f));
  }

//--- Klasifikasi retcode
bool HR_IsSuccessRetcode(const uint rc)
  {
   switch(rc)
     {
      case TRADE_RETCODE_DONE:
      case TRADE_RETCODE_DONE_PARTIAL:
      case TRADE_RETCODE_PLACED:
         return true;
     }
   return false;
  }

bool HR_IsRetryable(const uint rc)
  {
   switch(rc)
     {
      case TRADE_RETCODE_REQUOTE:
      case TRADE_RETCODE_PRICE_CHANGED:
      case TRADE_RETCODE_PRICE_OFF:
      case TRADE_RETCODE_TIMEOUT:
      case TRADE_RETCODE_TOO_MANY_REQUESTS:
      case TRADE_RETCODE_CONNECTION:
      case TRADE_RETCODE_REJECT:
      case TRADE_RETCODE_ERROR:
      case TRADE_RETCODE_LOCKED:
      case TRADE_RETCODE_FROZEN:
      case TRADE_RETCODE_INVALID_FILL:
         return true;
     }
   return false;
  }

//--- Perhitungan TP dari harga entry aktual
double CalculateBuyTP(const double entry)
  {
   return HR_NormalizePrice(entry + entry * (TakeProfitPercent / 100.0));
  }

double CalculateSellTP(const double entry)
  {
   return HR_NormalizePrice(entry - entry * (TakeProfitPercent / 100.0));
  }

//--- Cek awal sebelum membuka order
bool HR_PreTradeCheck(string &err)
  {
   if(g_openingLocked)
     { err = "Pembukaan order dikunci (Close All / WAITING)."; return false; }
   if(g_orderBusy)
     { err = "Order lain sedang diproses."; return false; }
   if(!HR_IsTradingAllowed(err))
      return false;
   if(!HR_IsSpreadOK())
     { err = "Spread melebihi MaxSpread."; return false; }
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t) || t.ask <= 0.0 || t.bid <= 0.0)
     { err = "Tick/harga belum tersedia."; return false; }
   return true;
  }

//--- Margin cukup untuk satu order?
bool HR_HasMarginForOrder(const ENUM_POSITION_TYPE type, const double lot, string &err)
  {
   double price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                              : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double margin = 0.0;
   ENUM_ORDER_TYPE ot = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcMargin(ot, _Symbol, lot, price, margin))
     { err = "OrderCalcMargin gagal, error " + IntegerToString(GetLastError()); return false; }
   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < margin)
     {
      err = StringFormat("Margin bebas %.2f < kebutuhan %.2f.", AccountInfoDouble(ACCOUNT_MARGIN_FREE), margin);
      return false;
     }
   return true;
  }

//--- Ambil ticket posisi dari hasil order
ulong HR_TicketFromResult()
  {
   ulong deal = g_trade.ResultDeal();
   if(deal > 0 && HistoryDealSelect(deal))
     {
      ulong pid = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(pid > 0)
         return pid;
     }
   return g_trade.ResultOrder();
  }

//--- Cari posisi EA berdasarkan comment unik (anti-duplikat saat hasil order tidak pasti)
bool HR_FindPositionByComment(const string comment, ulong &ticket)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_COMMENT) == comment)
        { ticket = t; return true; }
     }
   return false;
  }

//--- Buka satu posisi market (tanpa TP), dengan retry dan anti-duplikat
bool HR_OpenMarket(const ENUM_POSITION_TYPE type, ulong &ticket)
  {
   ticket = 0;
   string err = "";
   if(!HR_PreTradeCheck(err))
     { HR_Log("Open ditolak: " + err); return false; }

   double lot = HR_NormalizeVolume(LotSize);
   if(!HR_HasMarginForOrder(type, lot, err))
     { HR_Alert("Open ditolak: " + err); return false; }

   g_orderSeq++;
   string comment = StringFormat("HR%s%u%u", (type == POSITION_TYPE_BUY ? "B" : "S"),
                                 (uint)TimeCurrent(), (uint)g_orderSeq);
   bool success = false;
   g_orderBusy = true;

   for(int attempt = 1; attempt <= HR_MAX_RETRY; attempt++)
     {
      bool sent = (type == POSITION_TYPE_BUY) ? g_trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, comment)
                                              : g_trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, comment);
      uint rc = g_trade.ResultRetcode();
      if(sent && HR_IsSuccessRetcode(rc))
        {
         ticket = HR_TicketFromResult();
         success = (ticket > 0);
         if(success) break;
        }

      HR_Log(StringFormat("Open %s gagal (percobaan %d/%d): %u %s", EnumToString(type), attempt,
                          HR_MAX_RETRY, rc, g_trade.ResultRetcodeDescription()));

      //--- Hasil bisa tidak pasti (timeout/koneksi): cek dulu apakah order sebenarnya masuk
      if(HR_FindPositionByComment(comment, ticket))
        { success = true; HR_Log("Posisi ditemukan via comment, tidak dikirim ulang."); break; }

      if(rc == TRADE_RETCODE_INVALID_FILL)
         HR_RotateFilling();
      if(!HR_IsRetryable(rc))
         break;
      if(attempt < HR_MAX_RETRY)
         Sleep(HR_RETRY_DELAY_MS * attempt);
     }

   g_orderBusy = false;
   return success;
  }

//--- Pasang TP dari harga entry aktual posisi
bool HR_SetTP(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return true;  // sudah tertutup, tidak ada yang perlu dipasang
   if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MagicNumber)
      return false;
   if(PositionGetDouble(POSITION_TP) > 0.0)
      return true;

   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl   = PositionGetDouble(POSITION_SL);
   double tp   = (type == POSITION_TYPE_BUY) ? CalculateBuyTP(open) : CalculateSellTP(open);

   for(int attempt = 1; attempt <= HR_MAX_RETRY; attempt++)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double minDist = HR_MinStopDistance();
      bool valid = (type == POSITION_TYPE_BUY) ? (tp > bid && tp - bid >= minDist - 1e-9)
                                               : (tp < ask && ask - tp >= minDist - 1e-9);
      if(!valid)
        {
         HR_Log(StringFormat("TP #%I64u (%.5f) belum valid terhadap harga/Stop Level, dicoba lagi nanti.", ticket, tp));
         return false;
        }

      bool sent = g_trade.PositionModify(ticket, sl, tp);
      uint rc = g_trade.ResultRetcode();
      if((sent && HR_IsSuccessRetcode(rc)) || rc == TRADE_RETCODE_NO_CHANGES)
         return true;
      if(rc == TRADE_RETCODE_POSITION_CLOSED || !PositionSelectByTicket(ticket))
         return true;

      HR_Log(StringFormat("Set TP #%I64u gagal (%d/%d): %u %s", ticket, attempt, HR_MAX_RETRY,
                          rc, g_trade.ResultRetcodeDescription()));
      if(!HR_IsRetryable(rc))
         return false;
      if(attempt < HR_MAX_RETRY)
         Sleep(HR_RETRY_DELAY_MS * attempt);
     }
   return false;
  }

//--- Buka posisi lalu pasang TP. true jika posisi berhasil dibuka.
bool HR_OpenPositionWithTP(const ENUM_POSITION_TYPE type, ulong &ticket)
  {
   if(!HR_OpenMarket(type, ticket))
      return false;
   if(!HR_SetTP(ticket))
      HR_Log(StringFormat("TP #%I64u belum terpasang, akan dicoba ulang otomatis.", ticket));
   return true;
  }

//--- Buka pasangan BUY + SELL secepat mungkin.
//--- Return true jika minimal satu leg terbuka. Leg yang gagal dicatat di g_missingLeg.
bool HR_OpenPair(ulong &buyTicket, ulong &sellTicket)
  {
   buyTicket = 0;
   sellTicket = 0;
   string err = "";

   if(g_missingLeg >= 0)
     { HR_Log("Masih ada leg yang belum terbuka, pasangan baru ditunda."); return false; }
   if(!HR_PreTradeCheck(err))
     { HR_Log("Open pair ditolak: " + err); return false; }
   if(!HR_HasMarginForPair(HR_NormalizeVolume(LotSize), err))
     { HR_Alert("Open pair ditolak: " + err); return false; }

   //--- Buka kedua leg dulu (tanpa TP) agar waktunya sedekat mungkin
   bool okBuy  = HR_OpenMarket(POSITION_TYPE_BUY, buyTicket);
   bool okSell = HR_OpenMarket(POSITION_TYPE_SELL, sellTicket);

   if(okBuy)  HR_SetTP(buyTicket);
   if(okSell) HR_SetTP(sellTicket);

   if(!okBuy && !okSell)
      return false;

   if(okBuy != okSell)
     {
      g_missingLeg = okBuy ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
      HR_Alert("Satu leg gagal dibuka (" + (okBuy ? "SELL" : "BUY") + "). EA akan mencoba lagi otomatis.");
     }
   return true;
  }

//--- Coba lagi leg yang hilang (dipanggil dari OnTick)
void HR_RetryMissingLeg()
  {
   static ulong lastTry = 0;
   if(g_missingLeg < 0 || g_openingLocked || g_orderBusy)
      return;
   ulong now = GetTickCount64();
   if(now - lastTry < HR_LEG_RETRY_MS)
      return;
   lastTry = now;

   ulong t = 0;
   if(HR_OpenPositionWithTP((ENUM_POSITION_TYPE)g_missingLeg, t))
     {
      HR_Log("Leg yang hilang berhasil dibuka #" + IntegerToString((long)t));
      g_missingLeg = -1;
     }
  }

//--- Pastikan semua posisi EA yang TP-nya 0 dipasangi TP (dipanggil dari OnTick)
void HR_EnsureAllTP()
  {
   static ulong lastTry = 0;
   ulong now = GetTickCount64();
   if(now - lastTry < HR_TP_RETRY_MS)
      return;
   lastTry = now;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetDouble(POSITION_TP) > 0.0) continue;
      HR_SetTP(t);
     }
  }

//--- Tutup satu posisi EA dengan retry. true jika posisi sudah tidak ada.
bool HR_ClosePosition(const ulong ticket)
  {
   for(int attempt = 1; attempt <= HR_MAX_RETRY; attempt++)
     {
      if(!PositionSelectByTicket(ticket))
         return true;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MagicNumber)
        { HR_Log("Menolak menutup posisi bukan milik EA #" + IntegerToString((long)ticket)); return false; }

      bool sent = g_trade.PositionClose(ticket, (ulong)Slippage);
      uint rc = g_trade.ResultRetcode();
      if(sent && HR_IsSuccessRetcode(rc))
         return true;
      if(rc == TRADE_RETCODE_POSITION_CLOSED)
         return true;

      HR_Log(StringFormat("Close #%I64u gagal (%d/%d): %u %s", ticket, attempt, HR_MAX_RETRY,
                          rc, g_trade.ResultRetcodeDescription()));
      if(rc == TRADE_RETCODE_INVALID_FILL)
         HR_RotateFilling();
      if(!HR_IsRetryable(rc))
         break;
      if(attempt < HR_MAX_RETRY)
         Sleep(HR_RETRY_DELAY_MS * attempt);
     }
   return !PositionSelectByTicket(ticket);
  }

#endif