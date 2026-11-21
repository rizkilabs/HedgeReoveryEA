//+------------------------------------------------------------------+
//| HR_Positions.mqh - Hitung & kelompokkan posisi BUY/SELL EA       |
//+------------------------------------------------------------------+
#ifndef HR_POSITIONS_MQH
#define HR_POSITIONS_MQH

#include "HR_Config.mqh"

//--- Statistik satu sisi (hanya posisi yang MASIH TERBUKA)
struct HR_SideStats
  {
   int      count;          // jumlah posisi terbuka
   int      losing;         // jumlah posisi floating minus (profit + swap < 0)
   double   profit;         // total floating (profit + swap) seluruh posisi sisi ini
   double   losingSum;      // total floating hanya dari posisi minus (<= 0)
   ulong    oldestTicket;   // posisi tertua
   double   oldestPrice;    // harga entry posisi tertua
   ulong    newestTicket;   // posisi terbaru yang masih terbuka
   double   newestPrice;    // harga entry posisi terbaru
   long     oldestTimeMsc;
   long     newestTimeMsc;

   void Reset()
     {
      count = 0; losing = 0; profit = 0.0; losingSum = 0.0;
      oldestTicket = 0; oldestPrice = 0.0; newestTicket = 0; newestPrice = 0.0;
      oldestTimeMsc = 0; newestTimeMsc = 0;
     }
  };

struct HR_Snapshot
  {
   HR_SideStats buy;
   HR_SideStats sell;
   double       totalProfit;

   void Reset()
     {
      buy.Reset();
      sell.Reset();
      totalProfit = 0.0;
     }
  };

HR_Snapshot g_snap;   // snapshot terakhir

//--- Definisi "floating minus": profit + swap < 0
bool HR_IsLosing(const double profit, const double swap)
  {
   return (profit + swap) < 0.0;
  }

//--- Update statistik satu sisi dengan satu posisi
void HR_AddToSide(HR_SideStats &s, const ulong ticket, const double open,
                  const double floating, const long timeMsc)
  {
   s.count++;
   s.profit += floating;
   if(floating < 0.0)
     {
      s.losing++;
      s.losingSum += floating;
     }

   //--- Tertua: waktu terkecil (seri -> ticket terkecil)
   if(s.oldestTicket == 0 || timeMsc < s.oldestTimeMsc ||
      (timeMsc == s.oldestTimeMsc && ticket < s.oldestTicket))
     {
      s.oldestTicket = ticket;
      s.oldestPrice = open;
      s.oldestTimeMsc = timeMsc;
     }

   //--- Terbaru: waktu terbesar (seri -> ticket terbesar)
   if(s.newestTicket == 0 || timeMsc > s.newestTimeMsc ||
      (timeMsc == s.newestTimeMsc && ticket > s.newestTicket))
     {
      s.newestTicket = ticket;
      s.newestPrice = open;
      s.newestTimeMsc = timeMsc;
     }
  }

//--- Scan seluruh posisi terbuka milik EA (simbol + magic). Real-time, tanpa history.
void HR_ScanPositions(HR_Snapshot &snap)
  {
   snap.Reset();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open     = PositionGetDouble(POSITION_PRICE_OPEN);
      double floating = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      long   tmsc     = PositionGetInteger(POSITION_TIME_MSC);

      if(type == POSITION_TYPE_BUY)
         HR_AddToSide(snap.buy, ticket, open, floating, tmsc);
      else if(type == POSITION_TYPE_SELL)
         HR_AddToSide(snap.sell, ticket, open, floating, tmsc);
     }
   snap.totalProfit = snap.buy.profit + snap.sell.profit;
  }

//--- Perbarui snapshot global (dipanggil sekali per tick)
void HR_RefreshSnapshot()
  {
   HR_ScanPositions(g_snap);
  }

//--- Fungsi sesuai spesifikasi (memakai scan baru agar selalu real-time)
int CountOpenBuyPositions()
  {
   HR_Snapshot s; HR_ScanPositions(s);
   return s.buy.count;
  }

int CountOpenSellPositions()
  {
   HR_Snapshot s; HR_ScanPositions(s);
   return s.sell.count;
  }

int CountLosingBuyPositions()
  {
   HR_Snapshot s; HR_ScanPositions(s);
   return s.buy.losing;
  }

int CountLosingSellPositions()
  {
   HR_Snapshot s; HR_ScanPositions(s);
   return s.sell.losing;
  }

//--- Teks ringkas untuk log
string HR_SnapshotText(const HR_Snapshot &s)
  {
   return StringFormat("BUY: open=%d minus=%d pnl=%.2f newest=%.2f | SELL: open=%d minus=%d pnl=%.2f newest=%.2f | Total=%.2f",
                       s.buy.count, s.buy.losing, s.buy.profit, s.buy.newestPrice,
                       s.sell.count, s.sell.losing, s.sell.profit, s.sell.newestPrice,
                       s.totalProfit);
  }

//--- Log berkala (30 detik) untuk bantu pengujian; diganti dashboard di Tahap 7
void HR_LogSnapshotThrottled()
  {
   static datetime last = 0;
   datetime now = TimeCurrent();
   if(now - last < 30)
      return;
   last = now;
   HR_Log(HR_SnapshotText(g_snap));
  }

//--- Self-test logika "floating minus" memakai contoh dari spesifikasi
//--- Aktifkan dengan #define HR_STAGE4_SELFTEST di file utama (sebelum #include)
bool HR_SelfTestCounting()
  {
   double buyPnl[]  = {-10.0, -8.0, -5.0};
   double sellPnl[] = { 4.0, 3.0};
   int buyLosing = 0, sellLosing = 0;
   for(int i = 0; i < ArraySize(buyPnl); i++)
      if(HR_IsLosing(buyPnl[i], 0.0)) buyLosing++;
   for(int i = 0; i < ArraySize(sellPnl); i++)
      if(HR_IsLosing(sellPnl[i], 0.0)) sellLosing++;

   bool ok = (buyLosing == 3 && sellLosing == 0);
   HR_Log(StringFormat("SELFTEST counting: BUY minus=%d (harus 3), SELL minus=%d (harus 0) -> %s",
                       buyLosing, sellLosing, ok ? "LULUS" : "GAGAL"));
   return ok;
  }

#endif