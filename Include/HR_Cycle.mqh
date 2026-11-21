//+------------------------------------------------------------------+
//| HR_Cycle.mqh - Initial entry, deteksi TP, pembukaan siklus baru  |
//+------------------------------------------------------------------+
#ifndef HR_CYCLE_MQH
#define HR_CYCLE_MQH

#include "HR_Config.mqh"
#include "HR_Validation.mqh"
#include "HR_Trade.mqh"

//--- true  : beberapa TP sebelum pasangan sempat dibuka -> digabung jadi 1 pasangan
//--- false : satu pasangan per event TP (literal)
#define HR_MERGE_SIMULTANEOUS_TP  true
#define HR_OPEN_RETRY_MS          5000   // jeda retry jika pembukaan pasangan gagal
#define HR_TP_EVENT_GUARD_MS      3000   // cegah initial entry tepat setelah event TP
#define HR_SEEN_DEALS_MAX         16

ENUM_EA_STATE g_eaState         = EA_STATE_RUNNING;
int           g_pendingPairs    = 0;     // pasangan baru yang menunggu dibuka
int           g_cycleCount      = 0;     // jumlah pasangan yang sudah dibuka
ulong         g_lastTPEventMs   = 0;
ulong         g_lastOpenFailMs  = 0;
ulong         g_seenDeals[HR_SEEN_DEALS_MAX];
int           g_seenIdx         = 0;

//--- Jumlah posisi milik EA (simbol + magic)
int HR_CountEAPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      n++;
     }
   return n;
  }

//--- Deal ini sudah pernah diproses?
bool HR_DealAlreadySeen(const ulong deal)
  {
   for(int i = 0; i < HR_SEEN_DEALS_MAX; i++)
      if(g_seenDeals[i] == deal)
         return true;
   return false;
  }

void HR_MarkDealSeen(const ulong deal)
  {
   g_seenDeals[g_seenIdx] = deal;
   g_seenIdx = (g_seenIdx + 1) % HR_SEEN_DEALS_MAX;
  }

//--- Pastikan deal tersedia di history
bool HR_SelectDeal(const ulong deal)
  {
   if(HistoryDealSelect(deal))
      return true;
   if(!HistorySelect(TimeCurrent() - 3600, TimeCurrent() + 60))
      return false;
   return HistoryDealSelect(deal);
  }

//--- Buka pasangan awal. Hanya jika tidak ada posisi aktif milik EA.
bool OpenInitialHedge()
  {
   if(HR_CountEAPositions() > 0)
     { HR_Log("Initial hedge dibatalkan: masih ada posisi aktif EA."); return false; }

   ulong b = 0, s = 0;
   if(!HR_OpenPair(b, s))
      return false;

   g_cycleCount++;
   HR_Log(StringFormat("INITIAL HEDGE dibuka. BUY=#%I64u SELL=#%I64u Siklus=%d", b, s, g_cycleCount));
   return true;
  }

//--- Buka pasangan baru setelah event TP
bool OpenNewCycle()
  {
   ulong b = 0, s = 0;
   if(!HR_OpenPair(b, s))
      return false;

   g_cycleCount++;
   if(g_pendingPairs > 0)
      g_pendingPairs--;
   HR_Log(StringFormat("PASANGAN BARU dibuka. BUY=#%I64u SELL=#%I64u Siklus=%d Pending=%d",
                       b, s, g_cycleCount, g_pendingPairs));
   return true;
  }

//--- Deteksi event TP dari OnTradeTransaction
void HR_HandleTradeTransaction(const MqlTradeTransaction &trans)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong deal = trans.deal;
   if(deal == 0 || HR_DealAlreadySeen(deal))
      return;
   if(!HR_SelectDeal(deal))
      return;

   if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
      return;
   if(HistoryDealGetInteger(deal, DEAL_MAGIC) != MagicNumber)
      return;
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;
   if((ENUM_DEAL_REASON)HistoryDealGetInteger(deal, DEAL_REASON) != DEAL_REASON_TP)
      return;

   HR_MarkDealSeen(deal);
   g_lastTPEventMs = GetTickCount64();

   //--- TP saat Close All / WAITING tidak boleh memicu pasangan baru
   if(g_openingLocked || g_eaState == EA_STATE_WAITING)
     { HR_Log(StringFormat("TP deal #%I64u diabaikan (EA terkunci/WAITING).", deal)); return; }

   if(HR_MERGE_SIMULTANEOUS_TP && g_pendingPairs > 0)
     { HR_Log(StringFormat("TP deal #%I64u digabung dengan pasangan yang sedang menunggu.", deal)); return; }

   g_pendingPairs++;
   HR_Log(StringFormat("TP terdeteksi deal #%I64u. Pasangan baru dijadwalkan (pending=%d).", deal, g_pendingPairs));
  }

//--- Dipanggil tiap tick: eksekusi pasangan pending / initial entry
void HR_ProcessCycle()
  {
   if(g_eaState == EA_STATE_WAITING)
      return;
   if(g_openingLocked || g_orderBusy || g_missingLeg >= 0)
      return;

   ulong now = GetTickCount64();
   if(g_lastOpenFailMs != 0 && now - g_lastOpenFailMs < HR_OPEN_RETRY_MS)
      return;

   if(g_pendingPairs > 0)
     {
      if(!OpenNewCycle())
         g_lastOpenFailMs = now;
      else
         g_lastOpenFailMs = 0;
      return;
     }

   if(g_eaState == EA_STATE_RUNNING &&
      HR_CountEAPositions() == 0 &&
      now - g_lastTPEventMs > HR_TP_EVENT_GUARD_MS)
     {
      if(!OpenInitialHedge())
         g_lastOpenFailMs = now;
      else
         g_lastOpenFailMs = 0;
     }
  }

#endif