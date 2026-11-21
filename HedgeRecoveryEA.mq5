//+------------------------------------------------------------------+
//| HedgeRecoveryEA.mq5                                              |
//| BUY+SELL hedging, TP persentase, recovery berbasis jumlah posisi |
//+------------------------------------------------------------------+
#property copyright "HedgeRecoveryEA"
#property version   "1.00"
#property strict

#include "Include/HR_Config.mqh"
#include "Include/HR_Validation.mqh"
#include "Include/HR_Trade.mqh"

//--- Hapus tanda // di bawah untuk uji Tahap 2 (buka 1 pasangan sekali). Dihapus di Tahap 3.
//#define HR_STAGE2_SMOKE_TEST

//+------------------------------------------------------------------+
int OnInit()
  {
   string err = "";
   if(!HR_ValidateAll(err))
     {
      HR_Alert("Inisialisasi gagal: " + err);
      return INIT_PARAMETERS_INCORRECT;
     }

   HR_WarnSymbolName();
   HR_TradeInit();

   string tradeErr = "";
   if(!HR_IsTradingAllowed(tradeErr))
      HR_Log("Peringatan: " + tradeErr);

   HR_Log(StringFormat("v%s siap. Symbol=%s Lot=%.2f TP=%.3f%% RecoveryStart=%d Wait=%dmnt Magic=%I64d",
                       HR_VERSION, _Symbol, LotSize, TakeProfitPercent,
                       RecoveryStartPosition, RecoveryWaitMinutes, MagicNumber));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   HR_Log("Dihentikan. Reason=" + IntegerToString(reason));
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   HR_CheckMarginWarning();
   HR_RetryMissingLeg();
   HR_EnsureAllTP();

#ifdef HR_STAGE2_SMOKE_TEST
   static bool done = false;
   if(!done)
     {
      done = true;
      ulong b = 0, s = 0;
      bool ok = HR_OpenPair(b, s);
      HR_Log(StringFormat("SMOKE TEST pair ok=%s BUY=#%I64u SELL=#%I64u", (ok ? "true" : "false"), b, s));
     }
#endif
  }