//+------------------------------------------------------------------+
//| HedgeRecoveryEA.mq5                                              |
//| BUY+SELL hedging, TP persentase, recovery berbasis jumlah posisi |
//+------------------------------------------------------------------+
#property copyright "HedgeRecoveryEA"
#property version   "1.00"
#property strict

//#define HR_STAGE4_SELFTEST
//#define HR_STAGE5_SELFTEST

#include "Include/HR_Config.mqh"
#include "Include/HR_Validation.mqh"
#include "Include/HR_Trade.mqh"
#include "Include/HR_Positions.mqh"
#include "Include/HR_Cycle.mqh"
#include "Include/HR_Recovery.mqh"
#include "Include/HR_State.mqh"

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
   ArrayInitialize(g_seenDeals, 0);

   string tradeErr = "";
   if(!HR_IsTradingAllowed(tradeErr))
      HR_Log("Peringatan: " + tradeErr);

   HR_Log(StringFormat("v%s siap. Symbol=%s Lot=%.2f TP=%.3f%% RecoveryStart=%d Wait=%dmnt Magic=%I64d",
                       HR_VERSION, _Symbol, LotSize, TakeProfitPercent,
                       RecoveryStartPosition, RecoveryWaitMinutes, MagicNumber));

#ifdef HR_STAGE4_SELFTEST
   HR_SelfTestCounting();
#endif
#ifdef HR_STAGE5_SELFTEST
   HR_SelfTestRecovery();
#endif

   HR_StateInit();
   RestoreEAState();
   EventSetTimer(1);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   SaveEAState();
   HR_Log("Dihentikan. Reason=" + IntegerToString(reason));
  }

//+------------------------------------------------------------------+
void HR_TickLogic()
  {
   HR_RefreshSnapshot();
   HR_CheckMarginWarning();

   //--- Close All sedang berjalan: hanya retry penutupan
   if(g_closingAll)
     {
      HR_ProcessCloseAll();
      return;
     }

   //--- WAITING: tidak ada order sama sekali
   CheckWaitingPeriod();
   if(g_eaState == EA_STATE_WAITING)
      return;

   HR_RetryMissingLeg();
   HR_EnsureAllTP();

   if(g_eaState == EA_STATE_RUNNING)
      CheckRecoveryActivation();

   if(g_eaState == EA_STATE_RECOVERY)
     {
      if(CheckRecoveryTarget())
         return;
      HR_LogRecoveryThrottled();
     }

   HR_ProcessCycle();
   HR_LogSnapshotThrottled();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   HR_TickLogic();
   HR_SaveStateIfChanged();
  }

//+------------------------------------------------------------------+
//| Timer 1 detik: retry Close All dan WAITING tetap jalan saat sepi |
//+------------------------------------------------------------------+
void OnTimer()
  {
   HR_RefreshSnapshot();
   if(g_closingAll)
      HR_ProcessCloseAll();
   else
      CheckWaitingPeriod();
   HR_SaveStateIfChanged();
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   HR_HandleTradeTransaction(trans);
   HR_NoteTPDeal(trans);
   HR_SaveStateIfChanged();
  }