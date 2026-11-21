//+------------------------------------------------------------------+
//| HR_Config.mqh - Input, enum, konstanta                           |
//+------------------------------------------------------------------+
#ifndef HR_CONFIG_MQH
#define HR_CONFIG_MQH

#define HR_EA_NAME             "HedgeRecoveryEA"
#define HR_VERSION             "1.00"
#define HR_MIN_RECOVERY_POS    3

input group "=== Strategi ==="
input double LotSize               = 0.01;   // Lot tiap posisi BUY/SELL
input double TakeProfitPercent     = 0.25;   // TP (% dari harga entry)
input int    RecoveryStartPosition = 5;      // Min. posisi floating minus per sisi (min 3)
input int    RecoveryWaitMinutes   = 5;      // Waktu tunggu setelah Close All (menit)

input group "=== Eksekusi ==="
input int    MaxSpread             = 0;      // Spread maks (points), 0 = nonaktif
input long   MagicNumber           = 123456; // Magic Number EA
input int    Slippage              = 30;     // Deviasi harga maks (points)

input group "=== Tambahan (opsional) ==="
input double MinMarginLevelWarn    = 300.0;  // Peringatan jika Margin Level (%) di bawah ini
input bool   EnableAlerts          = true;   // Tampilkan Alert untuk peringatan penting

enum ENUM_EA_STATE
  {
   EA_STATE_RUNNING  = 0,
   EA_STATE_RECOVERY = 1,
   EA_STATE_WAITING  = 2
  };

enum ENUM_RECOVERY_SIDE
  {
   RECOVERY_SIDE_NONE = 0,
   RECOVERY_SIDE_BUY  = 1,
   RECOVERY_SIDE_SELL = 2
  };

//--- Logging
void HR_Log(const string msg)
  {
   Print("[", HR_EA_NAME, "] ", msg);
  }

void HR_Alert(const string msg)
  {
   if(EnableAlerts)
      Alert("[", HR_EA_NAME, "] ", msg);
   else
      Print("[", HR_EA_NAME, "] ", msg);
  }

#endif