#property strict
#property version "1.00"
#property tester_file "XauVwapEma9_news.csv"
#property description "Gold session VWAP / EMA 9 pullback EA. Demo first; no profitability claim."

#include "StrategyCore.mqh"

enum ENUM_NEWS_MODE { NEWS_AUTO=0, NEWS_CSV=1, NEWS_DISABLED=2 };

input group "Trading"
input ulong InpMagic=9261025;
input bool InpAllowRealAccount=false;
input bool InpRequireGoldSymbol=true;
input bool InpAllowBuys=true;
input bool InpAllowSells=true;
input double InpRiskPercent=0.25;
input double InpRewardRisk=2.0;
input double InpMaxLots=1.0;
input double InpCommissionPerLot=7.0; // Estimated round-trip cost, ACCOUNT currency / lot
input double InpSlippagePrice=0.20;  // Price units, not points; included in risk reserve
input double InpMaxSpreadPrice=0.60;
input double InpMaxCostRiskFraction=0.10;

input group "Signal: fixed M5 entry / M15 bias"
input int InpEmaPeriod=9;
input int InpAtrPeriod=14;
input ENUM_VWAP_VOLUME InpVwapVolume=VWAP_TICK_VOLUME;
input int InpVwapResetServerHour=0;
input int InpMinVwapMinutes=30;
input int InpSwingWidth=2;
input int InpStructureLookback=100;
input int InpPullbackBars=4;
input int InpBreakoutLookback=6;
input bool InpRequireLevelRetest=true;
input double InpRetestToleranceATR=0.35;
input double InpMinimumBodyFraction=0.25;
input double InpCloseExtremeFraction=0.35;
input double InpMaxSignalATR=1.8;
input double InpStopBufferATR=0.10;
input double InpMinStopATR=0.8;
input double InpMaxStopATR=3.0;
input double InpMaxTriggerGapATR=0.20;
input int InpSignalExpiryBars=3;
input bool InpUseRsi=false;
input int InpRsiPeriod=14;
input bool InpUseTargetRoomFilter=true;
input int InpHourlyLevelLookback=120;

input group "New York session (automatically follows US daylight saving time)"
input int InpSessionStartHourNY=8;
input int InpSessionStartMinuteNY=0;
input int InpSessionEndHourNY=11;
input int InpSessionEndMinuteNY=0;
input bool InpCloseAtSessionEnd=true;
input bool InpAutoLiveServerOffset=true;
input int InpServerUTCStandardMinutes=120; // MUST match broker when testing
input ENUM_BROKER_DST InpServerDST=BROKER_DST_EU; // MUST match broker when testing

input group "Daily / weekly limits (broker-server calendar)"
input int InpMaxTradesPerDay=3;
input int InpMaxConsecutiveLosses=2;
input double InpDailyLossPercent=0.75;
input double InpWeeklyLossPercent=2.0;

input group "High-impact USD news"
input ENUM_NEWS_MODE InpNewsMode=NEWS_AUTO;
input string InpNewsCSV="XauVwapEma9_news.csv";
input int InpNewsBeforeMinutes=15;
input int InpNewsAfterMinutes=30;
input int InpFomcBeforeMinutes=60;
input int InpFomcAfterMinutes=120;
input bool InpCloseBeforeNews=true;

struct NewsItem { datetime utc; bool fomc; string name; };
struct PositionResult
{
   ulong id;
   datetime opened;
   long closed_msc;
   double net;
   double volume_in;
   double volume_out;
};

int gEma5=INVALID_HANDLE,gEma15=INVALID_HANDLE,gAtr=INVALID_HANDLE,gRsi=INVALID_HANDLE;
int gLock=INVALID_HANDLE;
MqlRates gM5[],gM15[],gHourly[],gMinutes[];
double gMA5[],gMA15[],gVwap5[],gVwap15[],gATR[];
PullbackSetup gSetup;
NewsItem gNews[];
datetime gLastBar=0,gNewsUpdated=0,gHistoryUpdated=0,gDay=0,gWeek=0;
datetime gCoverageStart=0,gCoverageEnd=0;
bool gNewsKnown=false,gStatsKnown=false,gDailyHalt=false,gWeeklyHalt=false;
int gDirection=0,gTradesToday=0,gLossStreak=0;
double gDayBase=0,gWeekBase=0;
string gStatus="Starting",gNewsError="",gPrefix="";
bool gSending=false;
datetime gLastCloseAttempt=0;

bool IsTester() { return (bool)MQLInfoInteger(MQL_TESTER); }

datetime UtcNow()
{
   if(!IsTester() && InpAutoLiveServerOffset) return TimeGMT();
   return ServerToUTC(TimeCurrent(),InpServerUTCStandardMinutes,InpServerDST);
}

datetime ServerStampToUTC(const datetime stamp)
{
   if(!IsTester() && InpAutoLiveServerOffset)
   {
      // Calendar cache only covers nearby days. Refresh every minute and across DST changes.
      long offset=(long)MathRound((double)(TimeTradeServer()-TimeGMT())/900.0)*900;
      return (datetime)((long)stamp-offset);
   }
   return ServerToUTC(stamp,InpServerUTCStandardMinutes,InpServerDST);
}

string PeriodKey(const string kind,const datetime period)
{
   return gPrefix+kind+IntegerToString((long)period);
}

void PersistHalt(const bool weekly)
{
   if(!IsTester()) GlobalVariableSet(PeriodKey(weekly ? "W" : "D",weekly ? gWeek : gDay),1.0);
}

void CancelSetup(const string reason)
{
   if(gSetup.direction!=0) Print("Setup cancelled: ",reason);
   gSetup.direction=0;
}

bool LoadNewsCSV()
{
   int file=FileOpen(InpNewsCSV,FILE_READ|FILE_TXT|FILE_ANSI);
   if(file==INVALID_HANDLE) { gNewsError="News CSV missing in MQL5/Files: "+InpNewsCSV; return false; }
   ArrayResize(gNews,0); gCoverageStart=0; gCoverageEnd=0;
   bool valid=true;
   while(!FileIsEnding(file))
   {
      string line=FileReadString(file); StringTrimLeft(line); StringTrimRight(line);
      if(line=="") continue;
      if(StringFind(line,"#coverage_start=")==0)
      { if(!ParseUtcTimestamp(StringSubstr(line,16),gCoverageStart)) { valid=false; break; } continue; }
      if(StringFind(line,"#coverage_end=")==0)
      { if(!ParseUtcTimestamp(StringSubstr(line,14),gCoverageEnd)) { valid=false; break; } continue; }
      if(StringFind(line,"#")==0) continue;
      string cells[];
      if(StringSplit(line,';',cells)!=3 || (cells[1]!="HIGH" && cells[1]!="FOMC")) { valid=false; break; }
      datetime when=0;
      if(!ParseUtcTimestamp(cells[0],when) || cells[2]=="") { valid=false; break; }
      int n=ArraySize(gNews); ArrayResize(gNews,n+1);
      gNews[n].utc=when; gNews[n].fomc=(cells[1]=="FOMC"); gNews[n].name=cells[2];
   }
   FileClose(file);
   if(!valid || gCoverageStart<=0 || gCoverageEnd<=gCoverageStart)
   { gNewsError="Invalid news CSV or missing UTC coverage headers"; return false; }
   for(int i=0;i<ArraySize(gNews);i++)
      if(gNews[i].utc<gCoverageStart || gNews[i].utc>gCoverageEnd)
      { gNewsError="News event outside declared CSV coverage"; return false; }
   return true;
}

void RefreshNews()
{
   if(InpNewsMode==NEWS_DISABLED) { gNewsKnown=true; return; }
   datetime now=TimeCurrent();
   if(gNewsUpdated>0 && now-gNewsUpdated<60) return;
   gNewsUpdated=now; gNewsKnown=false; gNewsError="";
   if(InpNewsMode==NEWS_CSV || IsTester()) { gNewsKnown=LoadNewsCSV(); return; }
   MqlCalendarValue values[];
   ResetLastError();
   int past=(int)MathMax(InpNewsAfterMinutes,InpFomcAfterMinutes);
   int count=CalendarValueHistory(values,now-(past+5)*60,now+2*86400,NULL,"USD");
   if(count<0) { gNewsError=StringFormat("USD calendar unavailable (%d); entries blocked",GetLastError()); return; }
   ArrayResize(gNews,0);
   for(int i=0;i<count;i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id,event))
      { gNewsError="Calendar event details unavailable; entries blocked"; return; }
      bool fomc=IsFomcEvent(event.event_code+" "+event.name);
      if(event.importance!=CALENDAR_IMPORTANCE_HIGH && !fomc) continue;
      if(event.time_mode!=CALENDAR_TIMEMODE_DATETIME)
      { gNewsError="Important USD event has no precise time; entries blocked"; return; }
      int n=ArraySize(gNews); ArrayResize(gNews,n+1);
      gNews[n].utc=ServerStampToUTC(values[i].time); gNews[n].fomc=fomc; gNews[n].name=event.name;
   }
   gNewsKnown=true;
}

bool NewsBlocked(string &reason,bool &known_window)
{
   known_window=false; reason="";
   if(InpNewsMode==NEWS_DISABLED) return false;
   if(!gNewsKnown) { reason=gNewsError; return true; }
   datetime utc=UtcNow();
   if((InpNewsMode==NEWS_CSV || IsTester()) &&
      (utc-(int)MathMax(InpNewsAfterMinutes,InpFomcAfterMinutes)*60<gCoverageStart ||
       utc+(int)MathMax(InpNewsBeforeMinutes,InpFomcBeforeMinutes)*60>gCoverageEnd))
   { reason="UTC time outside news CSV coverage; entries blocked"; return true; }
   for(int i=0;i<ArraySize(gNews);i++)
   {
      int before=(gNews[i].fomc ? InpFomcBeforeMinutes : InpNewsBeforeMinutes);
      int after=(gNews[i].fomc ? InpFomcAfterMinutes : InpNewsAfterMinutes);
      if(utc>=gNews[i].utc-before*60 && utc<=gNews[i].utc+after*60)
      { reason="News window: "+gNews[i].name; known_window=true; return true; }
   }
   return false;
}

int ResultIndex(PositionResult &results[],const ulong id)
{
   for(int i=0;i<ArraySize(results);i++) if(results[i].id==id) return i;
   return -1;
}

bool RefreshStatistics()
{
   datetime now=TimeCurrent(),day=DayStart(now),week=WeekStart(now);
   bool new_day=(day!=gDay),new_week=(week!=gWeek);
   if(new_day)
   {
      gDay=day;
      gDailyHalt=(!IsTester() && GlobalVariableCheck(PeriodKey("D",day)));
   }
   if(new_week)
   {
      gWeek=week;
      gWeeklyHalt=(!IsTester() && GlobalVariableCheck(PeriodKey("W",week)));
   }
   if(!new_day && !new_week && gStatsKnown && now-gHistoryUpdated<30) return true;
   gStatsKnown=false;
   if(!HistorySelect(0,now)) { gStatus="Account history unavailable; entries blocked"; return false; }
   PositionResult results[];
   double day_net=0,week_net=0;
   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=HistoryDealGetTicket(i); if(ticket==0) return false;
      ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket,DEAL_TYPE);
      // Cash deposits / withdrawals adjust the reference balance, not strategy P&L.
      if(type==DEAL_TYPE_BALANCE || type==DEAL_TYPE_CREDIT) continue;
      datetime t=(datetime)HistoryDealGetInteger(ticket,DEAL_TIME);
      double net=HistoryDealGetDouble(ticket,DEAL_PROFIT)+HistoryDealGetDouble(ticket,DEAL_COMMISSION)+
                 HistoryDealGetDouble(ticket,DEAL_SWAP)+HistoryDealGetDouble(ticket,DEAL_FEE);
      if(t>=day) day_net+=net;
      if(t>=week) week_net+=net;
      if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol ||
         (ulong)HistoryDealGetInteger(ticket,DEAL_MAGIC)!=InpMagic) continue;
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket,DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_IN && entry!=DEAL_ENTRY_INOUT) continue;
      ulong id=(ulong)HistoryDealGetInteger(ticket,DEAL_POSITION_ID);
      if(id==0 || ResultIndex(results,id)>=0) continue;
      int n=ArraySize(results); ArrayResize(results,n+1);
      results[n].id=id; results[n].opened=t; results[n].closed_msc=0;
      results[n].net=0; results[n].volume_in=0; results[n].volume_out=0;
   }
   // Include every deal for an owned position, including manual closes and entry costs.
   for(int i=0;i<total;i++)
   {
      ulong ticket=HistoryDealGetTicket(i);
      int n=ResultIndex(results,(ulong)HistoryDealGetInteger(ticket,DEAL_POSITION_ID));
      if(n<0) continue;
      results[n].net+=HistoryDealGetDouble(ticket,DEAL_PROFIT)+HistoryDealGetDouble(ticket,DEAL_COMMISSION)+
                      HistoryDealGetDouble(ticket,DEAL_SWAP)+HistoryDealGetDouble(ticket,DEAL_FEE);
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket,DEAL_ENTRY);
      double volume=HistoryDealGetDouble(ticket,DEAL_VOLUME);
      if(entry==DEAL_ENTRY_IN) results[n].volume_in+=volume;
      else if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
      {
         results[n].volume_out+=volume;
         results[n].closed_msc=MathMax(results[n].closed_msc,HistoryDealGetInteger(ticket,DEAL_TIME_MSC));
      }
      else if(entry==DEAL_ENTRY_INOUT)
      { gStatus="Netting reversal detected; isolate this EA on its symbol"; return false; }
   }
   gTradesToday=0; gLossStreak=0;
   PositionResult closed[];
   for(int i=0;i<ArraySize(results);i++)
   {
      if(results[i].opened>=day) gTradesToday++;
      if(results[i].volume_in>0 && results[i].volume_out>=results[i].volume_in-1e-8 &&
         results[i].closed_msc>=(long)day*1000)
      { int n=ArraySize(closed); ArrayResize(closed,n+1); closed[n]=results[i]; }
   }
   for(int i=0;i<ArraySize(closed)-1;i++)
      for(int j=i+1;j<ArraySize(closed);j++)
         if(closed[j].closed_msc<closed[i].closed_msc)
         { PositionResult temp=closed[i]; closed[i]=closed[j]; closed[j]=temp; }
   for(int i=0;i<ArraySize(closed);i++)
   {
      if(closed[i].net<-1e-7) gLossStreak++; else gLossStreak=0;
      // Keep the halt even if a later external/manual trade recovers losses.
      if(gLossStreak>=InpMaxConsecutiveLosses) { gDailyHalt=true; PersistHalt(false); }
   }
   double balance=AccountInfoDouble(ACCOUNT_BALANCE)+AccountInfoDouble(ACCOUNT_CREDIT);
   gDayBase=balance-day_net; gWeekBase=balance-week_net;
   if(gDayBase<=0 || gWeekBase<=0) { gStatus="Invalid account risk baseline"; return false; }
   gHistoryUpdated=now; gStatsKnown=true;
   return true;
}

void CheckEquityLimits()
{
   if(!gStatsKnown) return;
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity<=gDayBase*(1-InpDailyLossPercent/100.0)) { gDailyHalt=true; PersistHalt(false); }
   if(equity<=gWeekBase*(1-InpWeeklyLossPercent/100.0)) { gWeeklyHalt=true; PersistHalt(true); }
}

bool HasSymbolExposure()
{
   for(int i=0;i<PositionsTotal();i++)
      if(PositionGetTicket(i)>0 && PositionGetString(POSITION_SYMBOL)==_Symbol) return true;
   for(int i=0;i<OrdersTotal();i++)
      if(OrderGetTicket(i)>0 && OrderGetString(ORDER_SYMBOL)==_Symbol) return true;
   return false;
}

ENUM_ORDER_TYPE_FILLING MarketFilling()
{
   int flags=(int)SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   if((flags&SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((flags&SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN; // OrderCheck rejects unsupported combinations.
}

bool SuccessfulRetcode(const uint code)
{
   return code==TRADE_RETCODE_DONE || code==TRADE_RETCODE_DONE_PARTIAL;
}

bool SendChecked(MqlTradeRequest &request,MqlTradeResult &result)
{
   MqlTradeCheckResult check={};
   if(!OrderCheck(request,check) || (check.retcode!=0 && check.retcode!=TRADE_RETCODE_DONE))
   { PrintFormat("OrderCheck failed: %u %s / error %d",check.retcode,check.comment,GetLastError()); return false; }
   bool sent=OrderSend(request,result);
   PrintFormat("Trade result: sent=%s code=%u order=%I64u deal=%I64u %s",
               (sent ? "true" : "false"),result.retcode,result.order,result.deal,result.comment);
   return sent && SuccessfulRetcode(result.retcode);
}

void CloseOwnedPositions(const string reason)
{
   if(TimeCurrent()==gLastCloseAttempt) return;
   gLastCloseAttempt=TimeCurrent();
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) continue;
      MqlTradeRequest request={}; MqlTradeResult result={};
      request.action=TRADE_ACTION_DEAL; request.position=ticket; request.symbol=_Symbol;
      request.magic=InpMagic; request.volume=PositionGetDouble(POSITION_VOLUME);
      bool buy=((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      request.type=(buy ? ORDER_TYPE_SELL : ORDER_TYPE_BUY); request.price=(buy ? tick.bid : tick.ask);
      request.type_filling=MarketFilling(); request.deviation=(ulong)MathCeil(InpSlippagePrice/_Point);
      request.comment="VX exit";
      Print("Closing own position: ",reason);
      SendChecked(request,result); // Retain actual position and retry on later ticks if rejected.
   }
   gHistoryUpdated=0;
}

void CancelOwnedOrders()
{
   // Normally there are no broker pending entries. An exchange-style market request
   // can nevertheless remain placed/part-filled after an uncertain response.
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || OrderGetString(ORDER_SYMBOL)!=_Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      MqlTradeRequest request={}; MqlTradeResult result={};
      request.action=TRADE_ACTION_REMOVE; request.order=ticket; request.symbol=_Symbol; request.magic=InpMagic;
      SendChecked(request,result); // A rejected cancellation stays visible and is retried.
   }
}

void ManagePositions()
{
   string reason="";
   if(gDailyHalt || gWeeklyHalt) reason="Risk limit reached";
   else if(InpCloseAtSessionEnd && !InNewYorkSession(UtcNow(),InpSessionStartHourNY*60+InpSessionStartMinuteNY,
                                                   InpSessionEndHourNY*60+InpSessionEndMinuteNY)) reason="Outside New York session";
   else
   {
      bool window=false; string news;
      if(InpCloseBeforeNews && NewsBlocked(news,window) && window) reason=news;
   }
   if(reason!="") { CancelSetup(reason); CancelOwnedOrders(); CloseOwnedPositions(reason); return; }
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(PositionGetTicket(i)==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetDouble(POSITION_SL)<=0 || PositionGetDouble(POSITION_TP)<=0)
      { CloseOwnedPositions("Missing protective SL/TP"); return; }
   }
}

bool CopySeries(const ENUM_TIMEFRAMES timeframe,const int count,MqlRates &rates[])
{
   ArraySetAsSeries(rates,true);
   return CopyRates(_Symbol,timeframe,0,count,rates)==count;
}

bool CopyIndicator(const int handle,const int count,double &values[])
{
   ArraySetAsSeries(values,true);
   if(BarsCalculated(handle)<count || CopyBuffer(handle,0,0,count,values)!=count) return false;
   for(int i=1;i<count;i++)
      if(values[i]==EMPTY_VALUE || !MathIsValidNumber(values[i])) return false;
   return true;
}

bool LoadSignalData()
{
   int count=(int)MathMax(250,InpStructureLookback+InpSwingWidth+10);
   if(!CopySeries(PERIOD_M5,count,gM5) || !CopySeries(PERIOD_M15,count,gM15) ||
      !CopyIndicator(gEma5,count,gMA5) || !CopyIndicator(gEma15,count,gMA15) ||
      !CopyIndicator(gAtr,3,gATR))
   { gStatus="Waiting for M5/M15 history and indicators"; return false; }
   datetime end=gM5[0].time;
   datetime earliest=(datetime)MathMin(gM5[InpPullbackBars].time,gM15[4].time);
   datetime anchor=VwapAnchor(earliest,InpVwapResetServerHour);
   ArraySetAsSeries(gMinutes,false);
   int copied=CopyRates(_Symbol,PERIOD_M1,anchor,end-1,gMinutes);
   if(copied<=0 || !SeriesInfoInteger(_Symbol,PERIOD_M1,SERIES_SYNCHRONIZED))
   { gStatus="Waiting for M1 volume history for VWAP"; return false; }
   ArrayResize(gVwap5,count); ArrayInitialize(gVwap5,0);
   ArrayResize(gVwap15,count); ArrayInitialize(gVwap15,0);
   for(int i=1;i<=InpPullbackBars;i++)
   {
      datetime a=VwapAnchor(gM5[i].time,InpVwapResetServerHour);
      if(!SessionVwap(gMinutes,a,gM5[i].time+300,InpVwapVolume,gVwap5[i]))
      { gStatus="Invalid/missing selected volume for VWAP"; return false; }
   }
   for(int i=1;i<=4;i++)
   {
      datetime a=VwapAnchor(gM15[i].time,InpVwapResetServerHour);
      if(!SessionVwap(gMinutes,a,gM15[i].time+900,InpVwapVolume,gVwap15[i]))
      { gStatus="Invalid/missing selected volume for VWAP"; return false; }
   }
   return true;
}

int BiasDirection()
{
   datetime anchor=VwapAnchor(gM15[1].time,InpVwapResetServerHour);
   if(VwapAnchor(gM15[4].time,InpVwapResetServerHour)!=anchor ||
      gM15[1].time+900-anchor<InpMinVwapMinutes*60) return 0;
   int structure=StructureDirection(gM15,InpSwingWidth,InpStructureLookback);
   if(structure==0) return 0;
   if(structure*(gM15[1].close-gVwap15[1])<=0 ||
      structure*(gM15[2].close-gVwap15[2])<=0 ||
      structure*(gMA15[1]-gVwap15[1])<=0 ||
      structure*(gVwap15[1]-gVwap15[4])<=0) return 0;
   // The most recent confirmed swing must still be intact, not just historically rising/falling.
   for(int i=InpSwingWidth+1;i<ArraySize(gM15)-InpSwingWidth;i++)
   {
      if(structure==1 && SwingLow(gM15,i,InpSwingWidth))
      {
         for(int j=1;j<i;j++) if(gM15[j].low<gM15[i].low) return 0;
         break;
      }
      if(structure==-1 && SwingHigh(gM15,i,InpSwingWidth))
      {
         for(int j=1;j<i;j++) if(gM15[j].high>gM15[i].high) return 0;
         break;
      }
   }
   if(InpUseRsi)
   {
      double rsi[];
      if(!CopyIndicator(gRsi,3,rsi) || structure*(rsi[1]-50.0)<=0) return 0;
   }
   return structure;
}

bool EntryGate(string &reason)
{
   reason="";
   if(gSending) reason="Trade request already in flight";
   else if(!gStatsKnown) reason="Account history unavailable";
   else if(gWeeklyHalt) reason="Weekly loss limit: halted";
   else if(gDailyHalt) reason="Daily loss/streak limit: halted";
   else if(gTradesToday>=InpMaxTradesPerDay) reason="Daily entry limit reached";
   else if(!InNewYorkSession(UtcNow(),InpSessionStartHourNY*60+InpSessionStartMinuteNY,
                            InpSessionEndHourNY*60+InpSessionEndMinuteNY)) reason="Outside New York session";
   else if(HasSymbolExposure()) reason="A position/order already exists on this symbol";
   else if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
           !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) reason="Algo trading permission disabled";
   else
   {
      bool known=false;
      if(NewsBlocked(reason,known)) return false;
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol,tick) || tick.ask<=tick.bid || tick.bid<=0) reason="Invalid bid/ask quote";
      else if(!IsTester() && MathAbs((double)(TimeTradeServer()-tick.time))>15) reason="Stale quote";
      else if(tick.ask-tick.bid>InpMaxSpreadPrice) reason="Spread exceeds price-unit limit";
   }
   return reason=="";
}

void EvaluateNewBar(const bool data_ready=false)
{
   if(!data_ready && !LoadSignalData()) { gDirection=0; CancelSetup(gStatus); return; }
   gDirection=BiasDirection();
   if(gSetup.direction!=0)
   {
      if(TimeCurrent()>=gSetup.expires || gDirection!=gSetup.direction ||
         gSetup.direction*(gM5[1].close-gVwap5[1])<=0)
         CancelSetup("Expired or closed-bar bias invalidated");
      else return; // Keep original trigger, stop and expiry; never extend an existing setup.
   }
   string reason;
   if(!EntryGate(reason)) { gStatus=reason; return; }
   if(gDirection==0) { gStatus="No aligned M15 structure / VWAP bias"; return; }
   if((gDirection==1 && !InpAllowBuys) || (gDirection==-1 && !InpAllowSells))
   { gStatus="Direction disabled in inputs"; return; }
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   double buffer=MathMax(InpStopBufferATR*gATR[1],1.5*(tick.ask-tick.bid));
   double size=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(!FindPullback(gM5,gMA5,gVwap5,gATR[1],gDirection,InpPullbackBars,InpBreakoutLookback,
                    InpRequireLevelRetest,InpRetestToleranceATR,InpMinimumBodyFraction,
                    InpCloseExtremeFraction,InpMaxSignalATR,buffer,size,_Digits,InpSignalExpiryBars,gSetup))
   { gStatus="Waiting for breakout pullback and strong M5 candle"; return; }
   gStatus="Armed: waiting for signal candle break";
   PrintFormat("Setup %s: trigger=%.*f SL=%.*f expires=%s level=%.*f",
               (gDirection==1 ? "BUY" : "SELL"),_Digits,gSetup.trigger,_Digits,gSetup.stop,
               TimeToString(gSetup.expires),_Digits,gSetup.level);
}

bool HasTargetRoom(const int direction,const double entry,const double target,const double padding)
{
   if(!InpUseTargetRoomFilter) return true;
   // Opposing levels are all known before entry; never use a forming H1/D1 candle.
   MqlRates daily[];
   if(!CopySeries(PERIOD_D1,2,daily) ||
      !CopySeries(PERIOD_H1,InpHourlyLevelLookback+InpSwingWidth+2,gHourly))
   { gStatus="Waiting for H1/D1 levels"; return false; }
   double previous=(direction==1 ? daily[1].high : daily[1].low);
   if(direction*(previous-entry)>0 && direction*(previous-target)<padding)
   { gStatus="Previous-day level leaves insufficient target room"; return false; }
   for(int i=InpSwingWidth+1;i<=InpHourlyLevelLookback;i++)
   {
      bool is_level=(direction==1 ? SwingHigh(gHourly,i,InpSwingWidth) : SwingLow(gHourly,i,InpSwingWidth));
      if(!is_level) continue;
      double level=(direction==1 ? gHourly[i].high : gHourly[i].low);
      // A level already decisively broken by a completed H1 candle is no longer opposing.
      bool broken=false;
      for(int j=1;j<i;j++) if(direction*(gHourly[j].close-level)>padding) { broken=true; break; }
      if(!broken && direction*(level-entry)>0 && direction*(level-target)<padding)
      { gStatus="Unbroken hourly level leaves insufficient target room"; return false; }
   }
   return true;
}

void TryEntry()
{
   if(gSetup.direction==0) return;
   string reason;
   if(!EntryGate(reason)) { gStatus=reason; CancelSetup(reason); return; }
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   int direction=gSetup.direction;
   if(TimeCurrent()>=gSetup.expires || direction*(tick.bid-gSetup.stop)<=0)
   { CancelSetup("Expired or pullback stop invalidated before entry"); return; }
   if(direction*(tick.bid-gSetup.trigger)<0) return;
   if(!TriggerValid(gSetup,tick.bid,TimeCurrent(),InpMaxTriggerGapATR))
   { CancelSetup("Price jumped too far through trigger"); return; }
   // Consume before any request. A rejection is never retried from the same signal.
   PullbackSetup setup=gSetup; gSetup.direction=0;
   double entry=(direction==1 ? tick.ask : tick.bid),stop=setup.stop;
   double distance=direction*(entry-stop);
   if(distance<InpMinStopATR*setup.atr || distance>InpMaxStopATR*setup.atr)
   { gStatus="Stop outside configured ATR range"; return; }
   double size=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double target=(direction==1 ? TickCeil(entry+InpRewardRisk*distance,size,_Digits) :
                                TickFloor(entry-InpRewardRisk*distance,size,_Digits));
   double minimum=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point+size;
   // Stops for buys are checked against Bid; sell stops against Ask.
   if((direction==1 && (tick.bid-stop<minimum || target-tick.bid<minimum)) ||
      (direction==-1 && (stop-tick.ask<minimum || tick.ask-target<minimum)))
   { gStatus="Broker minimum stop distance not met"; return; }
   if(!HasTargetRoom(direction,entry,target,MathMax(tick.ask-tick.bid,0.1*setup.atr))) return;
   ENUM_SYMBOL_TRADE_MODE mode=(ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
   if(mode==SYMBOL_TRADE_MODE_DISABLED || mode==SYMBOL_TRADE_MODE_CLOSEONLY ||
      (direction==1 && mode==SYMBOL_TRADE_MODE_SHORTONLY) ||
      (direction==-1 && mode==SYMBOL_TRADE_MODE_LONGONLY)) { gStatus="Symbol direction not tradable"; return; }
   int order_modes=(int)SymbolInfoInteger(_Symbol,SYMBOL_ORDER_MODE);
   if((order_modes&SYMBOL_ORDER_MARKET)==0 || (order_modes&SYMBOL_ORDER_SL)==0 || (order_modes&SYMBOL_ORDER_TP)==0)
   { gStatus="Symbol does not support market orders with SL and TP"; return; }

   ENUM_ORDER_TYPE type=(direction==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double reference=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double stop_loss=0,extra_loss=0,spread_loss=0;
   // OrderCalcProfit handles contract sizes and conversion to the account currency.
   if(!OrderCalcProfit(type,_Symbol,reference,entry,stop,stop_loss) || stop_loss>=0 ||
      !OrderCalcProfit(type,_Symbol,reference,entry,entry-direction*InpSlippagePrice,extra_loss) ||
      !OrderCalcProfit(type,_Symbol,reference,entry,entry-direction*(tick.ask-tick.bid),spread_loss))
   { gStatus="Cannot calculate symbol risk in account currency"; return; }
   double base_loss=MathAbs(stop_loss)/reference;
   double costs=(MathAbs(extra_loss)+MathAbs(spread_loss))/reference+InpCommissionPerLot;
   if(costs>base_loss*InpMaxCostRiskFraction) { gStatus="Estimated costs exceed risk fraction limit"; return; }
   // Spread is already in executable entry-to-stop distance. Do not charge it twice in sizing.
   double loss_per_lot=base_loss+MathAbs(extra_loss)/reference+InpCommissionPerLot;
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double budget=equity*InpRiskPercent/100.0;
   budget=MathMin(budget,equity-gDayBase*(1-InpDailyLossPercent/100.0));
   budget=MathMin(budget,equity-gWeekBase*(1-InpWeeklyLossPercent/100.0));
   double lots=RiskVolume(budget,loss_per_lot,reference,
                          MathMin(InpMaxLots,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX)),
                          SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP));
   if(lots<=0) { gStatus="Minimum broker lot exceeds remaining risk budget"; return; }
   double margin=0;
   if(!OrderCalcMargin(type,_Symbol,lots,entry,margin) || margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   { gStatus="Insufficient free margin"; return; }

   MqlTradeRequest request={}; MqlTradeResult result={};
   request.action=TRADE_ACTION_DEAL; request.symbol=_Symbol; request.magic=InpMagic;
   request.type=type; request.volume=lots; request.price=entry; request.sl=stop; request.tp=target;
   request.type_filling=MarketFilling(); request.deviation=(ulong)MathCeil(InpSlippagePrice/_Point);
   request.comment="VWAP EMA9";
   gSending=true;
   bool done=SendChecked(request,result);
   // A placed/timeout response might still execute. No repeat request; exposure is checked next tick.
   gSending=false;
   if(result.retcode==TRADE_RETCODE_PLACED || result.retcode==TRADE_RETCODE_TIMEOUT ||
      result.retcode==TRADE_RETCODE_CONNECTION)
   {
      gDailyHalt=true; PersistHalt(false);
      Print("Uncertain execution response: daily halt latched; reconcile terminal trade history.");
   }
   gStatus=(done ? "Entry executed; protective SL and TP submitted" : "Entry rejected/uncertain; signal consumed");
   gHistoryUpdated=0;
   if(done)
   {
      PrintFormat("Entry budget=%.2f %s estimated loss=%.2f lots=%.8f",budget,
                  AccountInfoString(ACCOUNT_CURRENCY),lots*loss_per_lot,lots);
      // A worse fill changes risk/reward; flatten if it exceeds the submitted risk allowance.
      if(result.price>0 && direction*(result.price-entry)>InpSlippagePrice+size)
         CloseOwnedPositions("Fill exceeded slippage reserve");
      ManagePositions();
   }
}

void ShowStatus()
{
   string reason; bool window=false;
   bool news=NewsBlocked(reason,window);
   Comment("XAU VWAP + EMA9 | v1.00\n",_Symbol," | M5 entry / M15 bias | ",
           (IsTester() ? "TESTER" : (AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_DEMO ? "DEMO" : "REAL")),
           "\n",gStatus,"\nBias: ",gDirection," | Armed: ",gSetup.direction,
           " | Entries today: ",gTradesToday,"/",InpMaxTradesPerDay," | Loss streak: ",gLossStreak,
           "\nDaily halt: ",gDailyHalt," | Weekly halt: ",gWeeklyHalt,
           "\nNews: ",(InpNewsMode==NEWS_DISABLED ? "DISABLED" : (news ? reason : "clear")),
           "\nNY time: ",TimeToString(NewYorkTime(UtcNow()),TIME_DATE|TIME_MINUTES),
           "\nRisk/trade: ",DoubleToString(InpRiskPercent,2),"% | Target: ",DoubleToString(InpRewardRisk,1),"R",
           "\nVWAP volume: ",(InpVwapVolume==VWAP_TICK_VOLUME ? "broker tick volume" : "real volume"));
}

void Process(const bool entries)
{
   RefreshStatistics(); CheckEquityLimits(); RefreshNews(); ManagePositions();
   if(entries)
   {
      datetime bar=iTime(_Symbol,PERIOD_M5,0);
      if(bar>0 && gLastBar==0) gLastBar=bar; // Never enter an old signal immediately after attachment.
      else if(bar>0 && bar!=gLastBar)
      {
         if(LoadSignalData()) { gLastBar=bar; EvaluateNewBar(true); }
         else { CancelSetup("History not ready"); gDirection=0; }
      }
      TryEntry();
   }
   string blocked;
   if(!EntryGate(blocked)) gStatus=blocked;
   ShowStatus();
}

bool ValidInputs()
{
   int start=InpSessionStartHourNY*60+InpSessionStartMinuteNY,end=InpSessionEndHourNY*60+InpSessionEndMinuteNY;
   return InpMagic>0 && InpRiskPercent>0 && InpRiskPercent<=2 && InpRewardRisk>=1 && InpMaxLots>0 &&
          InpCommissionPerLot>=0 && InpSlippagePrice>0 && InpMaxSpreadPrice>0 &&
          InpMaxCostRiskFraction>0 && InpMaxCostRiskFraction<=1 &&
          InpEmaPeriod>=2 && InpEmaPeriod<=100 && InpAtrPeriod>=2 && InpAtrPeriod<=100 &&
          InpVwapResetServerHour>=0 && InpVwapResetServerHour<=23 && InpMinVwapMinutes>=1 &&
          InpSwingWidth>=1 && InpSwingWidth<=10 && InpStructureLookback>=20 && InpStructureLookback<=500 &&
          InpPullbackBars>=1 && InpPullbackBars<=12 && InpBreakoutLookback>=2 && InpBreakoutLookback<=50 &&
          InpRetestToleranceATR>=0 && InpMinimumBodyFraction>0 && InpMinimumBodyFraction<=1 &&
          InpCloseExtremeFraction>0 && InpCloseExtremeFraction<=0.5 && InpMaxSignalATR>0 &&
          InpStopBufferATR>=0 && InpMinStopATR>0 && InpMaxStopATR>=InpMinStopATR &&
          InpMaxTriggerGapATR>=0 && InpSignalExpiryBars>=1 && InpSignalExpiryBars<=12 &&
          InpRsiPeriod>=2 && InpRsiPeriod<=100 && InpHourlyLevelLookback>=10 && InpHourlyLevelLookback<=500 &&
          InpSessionStartHourNY>=0 && InpSessionEndHourNY<=23 && InpSessionStartMinuteNY>=0 &&
          InpSessionStartMinuteNY<=59 && InpSessionEndMinuteNY>=0 && InpSessionEndMinuteNY<=59 &&
          start>=0 && end<=1440 && start<end &&
          InpServerUTCStandardMinutes>=-720 && InpServerUTCStandardMinutes<=840 &&
          InpMaxTradesPerDay>=1 && InpMaxTradesPerDay<=20 && InpMaxConsecutiveLosses>=1 &&
          InpDailyLossPercent>0 && InpWeeklyLossPercent>=InpDailyLossPercent && InpWeeklyLossPercent<=20 &&
          InpNewsBeforeMinutes>=0 && InpNewsAfterMinutes>=0 &&
          InpFomcBeforeMinutes>=InpNewsBeforeMinutes && InpFomcAfterMinutes>=InpNewsAfterMinutes;
}

int OnInit()
{
   if(!ValidInputs()) { Print("Invalid EA inputs; consult README."); return INIT_PARAMETERS_INCORRECT; }
   if(!IsTester() && AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO && !InpAllowRealAccount)
   { Print("Real/contest account trading is disabled. Use a demo account first."); return INIT_PARAMETERS_INCORRECT; }
   string name=_Symbol; StringToUpper(name);
   if(InpRequireGoldSymbol && StringFind(name,"XAU")==-1 && StringFind(name,"GOLD")==-1 &&
      SymbolInfoString(_Symbol,SYMBOL_CURRENCY_BASE)!="XAU")
   { Print("Attach to your broker's gold chart (XAU/GOLD), or explicitly change the gold-only input."); return INIT_PARAMETERS_INCORRECT; }
   if(SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE)<=0 || SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN)<=0)
      return INIT_FAILED;
   gPrefix=StringFormat("VX.%I64d.%I64u.%s.",AccountInfoInteger(ACCOUNT_LOGIN),InpMagic,_Symbol);
   if(StringLen(gPrefix)>43) gPrefix=StringSubstr(gPrefix,0,43);
   // Exclusive handle prevents duplicate copies on different charts in this terminal.
   string lock=StringFormat("VX_%I64d_%s.lock",AccountInfoInteger(ACCOUNT_LOGIN),_Symbol);
   gLock=FileOpen(lock,FILE_READ|FILE_WRITE|FILE_BIN);
   if(gLock==INVALID_HANDLE) { Print("Another copy owns this symbol, or lock file cannot be opened."); return INIT_FAILED; }
   gEma5=iMA(_Symbol,PERIOD_M5,InpEmaPeriod,0,MODE_EMA,PRICE_CLOSE);
   gEma15=iMA(_Symbol,PERIOD_M15,InpEmaPeriod,0,MODE_EMA,PRICE_CLOSE);
   gAtr=iATR(_Symbol,PERIOD_M5,InpAtrPeriod);
   if(InpUseRsi) gRsi=iRSI(_Symbol,PERIOD_M15,InpRsiPeriod,PRICE_CLOSE);
   if(gEma5==INVALID_HANDLE || gEma15==INVALID_HANDLE || gAtr==INVALID_HANDLE ||
      (InpUseRsi && gRsi==INVALID_HANDLE)) return INIT_FAILED;
   if((IsTester() && InpNewsMode!=NEWS_DISABLED) || InpNewsMode==NEWS_CSV)
   {
      if(!LoadNewsCSV()) { Print(gNewsError,". Export a complete calendar CSV, or explicitly disable news for a technical-only test."); return INIT_PARAMETERS_INCORRECT; }
   }
   gLastBar=iTime(_Symbol,PERIOD_M5,0); gSetup.direction=0;
   if(!IsTester()) EventSetTimer(2);
   Print("EA initialized for chart symbol ",_Symbol,". Entry timeframe M5; confirmation M15.");
   Print("Commission reserve is ACCOUNT currency per lot. Verify broker costs and VWAP reset.");
   if(IsTester()) Print("TESTER: verify server UTC standard offset and DST rule; TimeGMT cannot auto-detect these in tests.");
   if(InpNewsMode==NEWS_DISABLED) Print("NEWS FILTER DISABLED: technical test only; this does not match protected demo operation.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer(); Comment("");
   if(gEma5!=INVALID_HANDLE) IndicatorRelease(gEma5);
   if(gEma15!=INVALID_HANDLE) IndicatorRelease(gEma15);
   if(gAtr!=INVALID_HANDLE) IndicatorRelease(gAtr);
   if(gRsi!=INVALID_HANDLE) IndicatorRelease(gRsi);
   if(gLock!=INVALID_HANDLE) FileClose(gLock);
   // Existing positions retain server-side SL/TP; virtual unfilled setups are discarded.
}

void OnTick() { Process(true); }
void OnTimer() { Process(false); }
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
{
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD || trans.type==TRADE_TRANSACTION_HISTORY_ADD) gHistoryUpdated=0;
}
