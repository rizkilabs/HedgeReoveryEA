//+------------------------------------------------------------------+
//| HR_State.mqh - SaveEAState / RestoreEAState (Global Variables)   |
//+------------------------------------------------------------------+
#ifndef HR_STATE_MQH
#define HR_STATE_MQH

#include "HR_Config.mqh"
#include "HR_Trade.mqh"
#include "HR_Positions.mqh"
#include "HR_Cycle.mqh"
#include "HR_Recovery.mqh"

#define HR_STATE_VERSION     1
#define HR_SAVE_FORCE_SEC    60   // simpan ulang minimal tiap 60 dtk (menjaga GV tidak kedaluwarsa)

string   g_gvPrefix       = "";
bool     g_stateEnabled   = false;  // false di Strategy Tester
bool     g_stateReady     = false;  // true setelah RestoreEAState dipanggil (cegah menimpa state saat init gagal)
long     g_lastTPDealMsc  = 0;      // waktu (msc) deal TP terakhir yang sudah diproses
string   g_lastSig        = "";
datetime g_lastSaveTime   = 0;

//--- Hash sederhana nama simbol (nama Global Variable maks 63 karakter)
string HR_SymbolHash()
  {
   uint h = 5381;
   string s = _Symbol;
   for(int i = 0; i < StringLen(s); i++)
      h = h * 33 + (uint)StringGetCharacter(s, i);
   return IntegerToString((long)h);
  }

//--- Prefix unik per akun + magic + simbol
void HR_StateInit()
  {
   g_stateEnabled = !MQLInfoInteger(MQL_TESTER);
   g_gvPrefix = "HR" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" +
                IntegerToString(MagicNumber) + "_" + HR_SymbolHash() + "_";
  }

string HR_K(const string name) { return g_gvPrefix + name; }

double HR_GetGV(const string name, const double def)
  {
   double v = 0.0;
   if(!GlobalVariableGet(HR_K(name), v))
      return def;
   return v;
  }

void HR_SetGV(const string name, const double value)
  {
   GlobalVariableSet(HR_K(name), value);
  }

//--- Tanda tangan state: dipakai untuk mendeteksi perubahan
string HR_StateSig()
  {
   return StringFormat("%d|%d|%.5f|%.5f|%.5f|%I64d|%d|%d|%d|%d|%d|%I64d",
                       (int)g_eaState, (int)g_recoverySide, g_recoveryTarget,
                       g_recoveryOldestPrice, g_recoveryNewestPrice, (long)g_waitEnd,
                       g_pendingPairs, g_cycleCount, g_recoveryCount,
                       (int)g_closingAll, g_missingLeg, g_lastTPDealMsc);
  }

//--- Simpan seluruh state penting
void SaveEAState()
  {
   if(!g_stateEnabled || !g_stateReady)
      return;
   HR_SetGV("state",     (double)(int)g_eaState);
   HR_SetGV("side",      (double)(int)g_recoverySide);
   HR_SetGV("target",    g_recoveryTarget);
   HR_SetGV("oldest",    g_recoveryOldestPrice);
   HR_SetGV("newest",    g_recoveryNewestPrice);
   HR_SetGV("waitEnd",   (double)(long)g_waitEnd);
   HR_SetGV("pending",   (double)g_pendingPairs);
   HR_SetGV("cycles",    (double)g_cycleCount);
   HR_SetGV("recCount",  (double)g_recoveryCount);
   HR_SetGV("closing",   g_closingAll ? 1.0 : 0.0);
   HR_SetGV("missLeg",   (double)g_missingLeg);
   HR_SetGV("lastTPMsc", (double)g_lastTPDealMsc);
   g_lastSaveTime = TimeTradeServer();
   HR_SetGV("savedAt",   (double)(long)g_lastSaveTime);
   HR_SetGV("valid",     (double)HR_STATE_VERSION);
   g_lastSig = HR_StateSig();
  }

//--- Simpan hanya jika berubah (atau sudah lama tidak disimpan)
void HR_SaveStateIfChanged()
  {
   if(!g_stateEnabled || !g_stateReady)
      return;
   if(HR_StateSig() != g_lastSig || TimeTradeServer() - g_lastSaveTime >= HR_SAVE_FORCE_SEC)
      SaveEAState();
  }

//--- Catat waktu deal TP terakhir (dipanggil dari OnTradeTransaction setelah handler)
void HR_NoteTPDeal(const MqlTradeTransaction &trans)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;
   ulong d = trans.deal;
   if(!HR_SelectDeal(d))
      return;
   if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) return;
   if(HistoryDealGetInteger(d, DEAL_MAGIC) != MagicNumber) return;
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;
   if((ENUM_DEAL_REASON)HistoryDealGetInteger(d, DEAL_REASON) != DEAL_REASON_TP) return;
   long t = HistoryDealGetInteger(d, DEAL_TIME_MSC);
   if(t > g_lastTPDealMsc)
      g_lastTPDealMsc = t;
  }

//--- Hitung deal TP milik EA yang terjadi setelah sinceMsc (saat EA mati)
int HR_CountMissedTPDeals(const long sinceMsc, long &maxMsc)
  {
   maxMsc = 0;
   if(!HistorySelect((datetime)(sinceMsc / 1000), (datetime)(TimeTradeServer() + 3600)))
      return 0;
   int n = 0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != MagicNumber) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      if((ENUM_DEAL_REASON)HistoryDealGetInteger(d, DEAL_REASON) != DEAL_REASON_TP) continue;
      long t = HistoryDealGetInteger(d, DEAL_TIME_MSC);
      if(t <= sinceMsc) continue;
      n++;
      if(t > maxMsc) maxMsc = t;
     }
   return n;
  }

//--- Pulihkan state. true jika ada state tersimpan yang dipulihkan.
bool RestoreEAState()
  {
   g_stateReady = true;
   if(!g_stateEnabled)
     { HR_Log("Persistence nonaktif di Strategy Tester."); return false; }

   if((int)HR_GetGV("valid", 0.0) != HR_STATE_VERSION)
     {
      HR_Log(StringFormat("Tidak ada state tersimpan. Mulai baru. Posisi aktif EA: %d", HR_CountEAPositions()));
      return false;
     }

   int st = (int)HR_GetGV("state", 0.0);
   int sd = (int)HR_GetGV("side", 0.0);
   if(st < 0 || st > 2) st = 0;
   if(sd < 0 || sd > 2) sd = 0;

   g_eaState             = (ENUM_EA_STATE)st;
   g_recoverySide        = (ENUM_RECOVERY_SIDE)sd;
   g_recoveryTarget      = HR_GetGV("target", 0.0);
   g_recoveryOldestPrice = HR_GetGV("oldest", 0.0);
   g_recoveryNewestPrice = HR_GetGV("newest", 0.0);
   g_waitEnd             = (datetime)(long)HR_GetGV("waitEnd", 0.0);
   g_pendingPairs        = (int)HR_GetGV("pending", 0.0);
   g_cycleCount          = (int)HR_GetGV("cycles", 0.0);
   g_recoveryCount       = (int)HR_GetGV("recCount", 0.0);
   g_closingAll          = (HR_GetGV("closing", 0.0) > 0.5);
   g_missingLeg          = (int)HR_GetGV("missLeg", -1.0);
   g_lastTPDealMsc       = (long)HR_GetGV("lastTPMsc", 0.0);
   datetime savedAt      = (datetime)(long)HR_GetGV("savedAt", 0.0);

   if(g_missingLeg != (int)POSITION_TYPE_BUY && g_missingLeg != (int)POSITION_TYPE_SELL)
      g_missingLeg = -1;
   if(g_pendingPairs < 0) g_pendingPairs = 0;

   //--- Konsistensi recovery
   if(g_eaState == EA_STATE_RECOVERY && (g_recoverySide == RECOVERY_SIDE_NONE || g_recoveryTarget <= 0.0))
     {
      HR_Log("State recovery tidak lengkap, direset ke RUNNING (recovery akan aktif ulang jika syarat terpenuhi).");
      HR_ResetRecovery();
      g_eaState = EA_STATE_RUNNING;
     }
   if(g_eaState == EA_STATE_RUNNING && g_recoverySide != RECOVERY_SIDE_NONE)
      HR_ResetRecovery();

   //--- WAITING: lanjutkan sisa waktu, kunci pembukaan order
   if(g_eaState == EA_STATE_WAITING)
     {
      g_closingAll    = false;
      g_openingLocked = true;
      g_pendingPairs  = 0;
      g_missingLeg    = -1;
      HR_ResetRecovery();
      long remain = (long)g_waitEnd - (long)TimeTradeServer();
      HR_Log(StringFormat("State WAITING dipulihkan. Sisa waktu tunggu: %d detik (berakhir %s).",
                          (int)MathMax(0, remain), TimeToString(g_waitEnd, TIME_DATE | TIME_SECONDS)));
      if(HR_CountEAPositions() > 0)
         HR_Log("Peringatan: ada posisi aktif EA saat WAITING. Posisi tidak disentuh.");
     }
   //--- Close All terputus: lanjutkan sampai tuntas
   else if(g_closingAll)
     {
      g_openingLocked = true;
      g_pendingPairs  = 0;
      g_missingLeg    = -1;
      HR_Alert("Close All sebelumnya belum tuntas. EA melanjutkan penutupan semua posisi.");
     }
   //--- RUNNING / RECOVERY: periksa TP yang terlewat saat EA mati
   else
     {
      long since = (g_lastTPDealMsc > 0) ? g_lastTPDealMsc : (long)savedAt * 1000;
      if(since > 0)
        {
         long maxMsc = 0;
         int missed = HR_CountMissedTPDeals(since, maxMsc);
         if(missed > 0)
           {
            if(HR_MERGE_SIMULTANEOUS_TP)
               g_pendingPairs = (int)MathMax(g_pendingPairs, 1);
            else
               g_pendingPairs += missed;
            if(maxMsc > g_lastTPDealMsc)
               g_lastTPDealMsc = maxMsc;
            HR_Alert(StringFormat("%d TP terlewat saat EA mati. Pasangan baru dijadwalkan (pending=%d).",
                                  missed, g_pendingPairs));
           }
        }
      if(g_eaState == EA_STATE_RECOVERY)
         HR_Log(StringFormat("State RECOVERY dipulihkan. Sisi=%s Target=%.2f (target lama dipakai, tidak dihitung ulang).",
                             (g_recoverySide == RECOVERY_SIDE_BUY ? "BUY" : "SELL"), g_recoveryTarget));
      else
         HR_Log(StringFormat("State RUNNING dipulihkan. Posisi aktif EA=%d Pending=%d Siklus=%d",
                             HR_CountEAPositions(), g_pendingPairs, g_cycleCount));
     }

   SaveEAState();
   return true;
  }

#endif