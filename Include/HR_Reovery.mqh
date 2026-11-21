//+------------------------------------------------------------------+
//| HR_Recovery.mqh - Recovery, target trailing, Close All, WAITING  |
//+------------------------------------------------------------------+
#ifndef HR_RECOVERY_MQH
#define HR_RECOVERY_MQH

#include "HR_Config.mqh"
#include "HR_Validation.mqh"
#include "HR_Trade.mqh"
#include "HR_Positions.mqh"
#include "HR_Cycle.mqh"

#define HR_CLOSE_RETRY_MS     1000   // jeda retry Close All
#define HR_CLOSE_ALERT_AFTER  5      // alert jika gagal sebanyak ini berturut-turut

ENUM_RECOVERY_SIDE g_recoverySide        = RECOVERY_SIDE_NONE;
double             g_recoveryTarget      = 0.0;
double             g_recoveryOldestPrice = 0.0;  // entry tertua saat aktivasi
double             g_recoveryNewestPrice = 0.0;  // entry terbaru saat aktivasi
bool               g_closingAll          = false;
datetime           g_waitEnd             = 0;
int                g_recoveryCount       = 0;    // jumlah recovery yang selesai

//--- Konversi sisi -> tipe posisi
ENUM_POSITION_TYPE HR_SideToType(const ENUM_RECOVERY_SIDE side)
  {
   return (side == RECOVERY_SIDE_SELL) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
  }

//--- Ambil entry posisi terbaru, terbaru kedua, dan tertua pada satu sisi (posisi terbuka saja)
//--- Return true jika sisi itu punya minimal 2 posisi.
bool HR_GetSideLastTwo(const ENUM_POSITION_TYPE type, double &newestPrice, double &prevPrice,
                       double &oldestPrice, int &count)
  {
   newestPrice = 0.0; prevPrice = 0.0; oldestPrice = 0.0; count = 0;
   long  nT = 0, pT = 0, oT = 0;
   ulong nK = 0, pK = 0, oK = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;

      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      long   tm = PositionGetInteger(POSITION_TIME_MSC);
      count++;

      if(nK == 0 || tm > nT || (tm == nT && tk > nK))
        {
         pT = nT; pK = nK; prevPrice = newestPrice;
         nT = tm; nK = tk; newestPrice = op;
        }
      else if(pK == 0 || tm > pT || (tm == pT && tk > pK))
        {
         pT = tm; pK = tk; prevPrice = op;
        }

      if(oK == 0 || tm < oT || (tm == oT && tk < oK))
        {
         oT = tm; oK = tk; oldestPrice = op;
        }
     }
   return (count >= 2);
  }

//--- Pemilihan sisi (fungsi murni agar mudah diuji)
//--- Aturan: hanya sisi yang memenuhi syarat; jika keduanya -> posisi minus terbanyak,
//--- lalu total loss terbesar (nilai paling negatif), lalu BUY.
ENUM_RECOVERY_SIDE HR_PickSide(const int buyLosing, const int sellLosing,
                               const double buyLosingSum, const double sellLosingSum,
                               const int startPos)
  {
   bool buyOk  = (buyLosing  >= startPos);
   bool sellOk = (sellLosing >= startPos);

   if(!buyOk && !sellOk) return RECOVERY_SIDE_NONE;
   if(buyOk && !sellOk)  return RECOVERY_SIDE_BUY;
   if(!buyOk && sellOk)  return RECOVERY_SIDE_SELL;

   if(buyLosing != sellLosing)
      return (buyLosing > sellLosing) ? RECOVERY_SIDE_BUY : RECOVERY_SIDE_SELL;
   if(MathAbs(buyLosingSum - sellLosingSum) > 1e-9)
      return (buyLosingSum < sellLosingSum) ? RECOVERY_SIDE_BUY : RECOVERY_SIDE_SELL;
   return RECOVERY_SIDE_BUY;
  }

//--- Reset seluruh data recovery
void HR_ResetRecovery()
  {
   g_recoverySide        = RECOVERY_SIDE_NONE;
   g_recoveryTarget      = 0.0;
   g_recoveryOldestPrice = 0.0;
   g_recoveryNewestPrice = 0.0;
  }

//--- Kunci target awal = entry posisi sebelumnya (terbaru kedua) pada sisi recovery
bool LockRecoveryTarget(const ENUM_RECOVERY_SIDE side)
  {
   double newest, prev, oldest;
   int cnt;
   if(!HR_GetSideLastTwo(HR_SideToType(side), newest, prev, oldest, cnt))
      return false;
   g_recoveryTarget      = HR_NormalizePrice(prev);
   g_recoveryNewestPrice = newest;
   g_recoveryOldestPrice = oldest;
   return true;
  }

//--- Geser target hanya ke arah kerugian (BUY turun, SELL naik)
void UpdateRecoveryTarget(const double prevPrice)
  {
   double cand = HR_NormalizePrice(prevPrice);
   if(g_recoverySide == RECOVERY_SIDE_BUY && cand < g_recoveryTarget - 1e-9)
     {
      HR_Log(StringFormat("Target recovery BUY bergeser %.2f -> %.2f", g_recoveryTarget, cand));
      g_recoveryTarget = cand;
     }
   else if(g_recoverySide == RECOVERY_SIDE_SELL && cand > g_recoveryTarget + 1e-9)
     {
      HR_Log(StringFormat("Target recovery SELL bergeser %.2f -> %.2f", g_recoveryTarget, cand));
      g_recoveryTarget = cand;
     }
  }

//--- Aktifkan recovery pada sisi terpilih
bool ActivateRecovery(const ENUM_RECOVERY_SIDE side)
  {
   if(side == RECOVERY_SIDE_NONE)
      return false;
   if(!LockRecoveryTarget(side))
      return false;

   g_recoverySide = side;
   g_eaState      = EA_STATE_RECOVERY;
   HR_Alert(StringFormat("RECOVERY AKTIF sisi %s. Minus BUY=%d SELL=%d. Entry tertua=%.2f terbaru=%.2f. Target=%.2f",
                         (side == RECOVERY_SIDE_BUY ? "BUY" : "SELL"),
                         g_snap.buy.losing, g_snap.sell.losing,
                         g_recoveryOldestPrice, g_recoveryNewestPrice, g_recoveryTarget));
   return true;
  }

//--- Cek syarat aktivasi (memakai snapshot terbaru). Hanya satu recovery pada satu waktu.
bool CheckRecoveryActivation()
  {
   if(g_eaState != EA_STATE_RUNNING || g_closingAll)
      return false;

   ENUM_RECOVERY_SIDE side = HR_PickSide(g_snap.buy.losing, g_snap.sell.losing,
                                         g_snap.buy.losingSum, g_snap.sell.losingSum,
                                         RecoveryStartPosition);
   if(side == RECOVERY_SIDE_NONE)
      return false;
   return ActivateRecovery(side);
  }

//--- Kumpulkan dan tutup semua posisi EA. true jika tidak ada yang tersisa.
bool CloseAllEAPositions()
  {
   ulong tickets[];
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      ArrayResize(tickets, n + 1);
      tickets[n++] = t;
     }

   g_orderBusy = true;
   for(int k = 0; k < n; k++)
      HR_ClosePosition(tickets[k]);
   g_orderBusy = false;

   return (HR_CountEAPositions() == 0);
  }

//--- Mulai proses Close All: kunci pembukaan order, buang antrean pasangan
void HR_StartCloseAll(const string reason)
  {
   if(g_closingAll)
      return;
   g_closingAll     = true;
   g_openingLocked  = true;
   g_pendingPairs   = 0;
   g_missingLeg     = -1;
   HR_Alert("CLOSE ALL dimulai. Alasan: " + reason);
  }

//--- Selesai Close All: masuk WAITING
void HR_FinishCloseAll()
  {
   g_closingAll = false;
   HR_ResetRecovery();
   g_recoveryCount++;
   g_eaState = EA_STATE_WAITING;
   g_waitEnd = (datetime)(TimeCurrent() + (long)RecoveryWaitMinutes * 60);
   // g_openingLocked tetap true selama WAITING
   HR_Alert(StringFormat("CLOSE ALL selesai. WAITING %d menit sampai %s",
                         RecoveryWaitMinutes, TimeToString(g_waitEnd, TIME_DATE | TIME_SECONDS)));
  }

//--- Dipanggil tiap tick saat g_closingAll: retry aman sampai semua tertutup
void HR_ProcessCloseAll()
  {
   static ulong lastTry = 0;
   static int   fails   = 0;
   if(!g_closingAll)
      return;

   ulong now = GetTickCount64();
   if(lastTry != 0 && now - lastTry < HR_CLOSE_RETRY_MS)
      return;
   lastTry = now;

   if(CloseAllEAPositions())
     {
      lastTry = 0;
      fails   = 0;
      HR_FinishCloseAll();
      return;
     }

   fails++;
   HR_Log(StringFormat("Close All belum tuntas, sisa %d posisi. Percobaan ke-%d.", HR_CountEAPositions(), fails));
   if(fails == HR_CLOSE_ALERT_AFTER)
      HR_Alert("Close All gagal berulang kali. EA terus mencoba. Periksa koneksi/broker.");
  }

//--- Pantau target. true jika Close All dimulai pada tick ini.
bool CheckRecoveryTarget()
  {
   if(g_eaState != EA_STATE_RECOVERY || g_closingAll)
      return false;

   double newest, prev, oldest;
   int cnt;
   HR_GetSideLastTwo(HR_SideToType(g_recoverySide), newest, prev, oldest, cnt);

   //--- Sisi recovery sudah kosong (semua kena TP): recovery berakhir tanpa Close All
   if(cnt == 0)
     {
      HR_Alert("Recovery berakhir: semua posisi sisi recovery sudah tertutup.");
      HR_ResetRecovery();
      g_eaState = EA_STATE_RUNNING;
      return false;
     }

   if(cnt >= 2)
      UpdateRecoveryTarget(prev);

   bool reached = false;
   if(g_recoverySide == RECOVERY_SIDE_BUY)
      reached = (SymbolInfoDouble(_Symbol, SYMBOL_BID) >= g_recoveryTarget);
   else
      reached = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) <= g_recoveryTarget && SymbolInfoDouble(_Symbol, SYMBOL_ASK) > 0.0);

   if(!reached)
      return false;

   HR_StartCloseAll(StringFormat("target recovery %.2f tercapai (sisi %s)", g_recoveryTarget,
                                 (g_recoverySide == RECOVERY_SIDE_BUY ? "BUY" : "SELL")));
   HR_ProcessCloseAll();
   return true;
  }

//--- Periksa akhir masa tunggu (persistence ditambah di Tahap 6)
void CheckWaitingPeriod()
  {
   if(g_eaState != EA_STATE_WAITING)
      return;
   if(TimeCurrent() < g_waitEnd)
      return;

   g_eaState        = EA_STATE_RUNNING;
   g_openingLocked  = false;
   g_pendingPairs   = 0;
   g_lastOpenFailMs = 0;
   g_lastTPEventMs  = 0;
   HR_Log("WAITING selesai. EA kembali RUNNING, siklus baru dimulai.");
  }

//--- Log berkala saat recovery (10 detik)
void HR_LogRecoveryThrottled()
  {
   static datetime last = 0;
   if(g_eaState != EA_STATE_RECOVERY)
      return;
   datetime now = TimeCurrent();
   if(now - last < 10)
      return;
   last = now;
   HR_Log(StringFormat("RECOVERY sisi=%s target=%.2f Bid=%.2f Ask=%.2f",
                       (g_recoverySide == RECOVERY_SIDE_BUY ? "BUY" : "SELL"), g_recoveryTarget,
                       SymbolInfoDouble(_Symbol, SYMBOL_BID), SymbolInfoDouble(_Symbol, SYMBOL_ASK)));
  }

//--- Self-test logika murni (pemilihan sisi + target trailing)
//--- Aktifkan dengan #define HR_STAGE5_SELFTEST di file utama (sebelum #include)
bool HR_SelfTestRecovery()
  {
   bool ok = true;

   //--- Poin 3: pemilihan sisi
   if(HR_PickSide(5, 6, -60.0, -45.0, 5) != RECOVERY_SIDE_SELL) ok = false;
   if(HR_PickSide(5, 5, -60.0, -80.0, 5) != RECOVERY_SIDE_SELL) ok = false;
   if(HR_PickSide(5, 5, -70.0, -70.0, 5) != RECOVERY_SIDE_BUY)  ok = false;
   if(HR_PickSide(5, 4, -50.0, -40.0, 5) != RECOVERY_SIDE_BUY)  ok = false;
   if(HR_PickSide(4, 4, -50.0, -40.0, 5) != RECOVERY_SIDE_NONE) ok = false;

   //--- BUY: posisi ke-n -> target = entry posisi ke-(n-1)
   double buyE[]   = {4000, 3990, 3980, 3970, 3960, 3950, 3940, 3930};
   double buyExp[] = {3970, 3960, 3950, 3940};
   double target = 0.0;
   for(int n = 5; n <= 8; n++)
     {
      double cand = buyE[n - 2];
      if(target == 0.0 || cand < target) target = cand;
      if(MathAbs(target - buyExp[n - 5]) > 1e-9) ok = false;
     }

   //--- SELL: arah dibalik
   double sellE[]   = {4000, 4010, 4020, 4030, 4040, 4050};
   double sellExp[] = {4030, 4040};
   target = 0.0;
   for(int n = 5; n <= 6; n++)
     {
      double cand = sellE[n - 2];
      if(target == 0.0 || cand > target) target = cand;
      if(MathAbs(target - sellExp[n - 5]) > 1e-9) ok = false;
     }

   HR_Log(StringFormat("SELFTEST recovery -> %s", ok ? "LULUS" : "GAGAL"));
   return ok;
  }

#endif