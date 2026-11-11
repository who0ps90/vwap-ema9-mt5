#property strict
#property script_show_inputs
#property version "1.00"
#include "../../Experts/XauVwapEma9/StrategyCore.mqh"

input datetime InpFromUTC=D'2026.10.01 00:00';
input datetime InpToUTC=D'2026.10.25 23:59';
input int InpBrokerUTCStandardMinutes=120;
input ENUM_BROKER_DST InpBrokerDST=BROKER_DST_EU;
input string InpOutputFile="XauVwapEma9_news.csv";
input bool InpOverwriteExisting=false;

void OnStart()
{
   if(MQLInfoInteger(MQL_TESTER)) { Print("Run exporter on a connected terminal, not in the tester."); return; }
   if(InpToUTC<=InpFromUTC || InpBrokerUTCStandardMinutes<-720 || InpBrokerUTCStandardMinutes>840)
   { Print("Invalid date range / broker UTC offset."); return; }
   if(FileIsExist(InpOutputFile) && !InpOverwriteExisting)
   { Print("Output already exists. Rename it or explicitly enable overwrite."); return; }
   datetime from=InpFromUTC+BrokerOffset(InpFromUTC,InpBrokerUTCStandardMinutes,InpBrokerDST)*60;
   datetime to=InpToUTC+BrokerOffset(InpToUTC,InpBrokerUTCStandardMinutes,InpBrokerDST)*60;
   MqlCalendarValue values[];
   int count=CalendarValueHistory(values,from,to,NULL,"USD");
   if(count<0) { Print("Calendar query failed: ",GetLastError()); return; }
   string rows[];
   for(int i=0;i<count;i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id,event)) { Print("Event metadata missing; no file written."); return; }
      bool fomc=IsFomcEvent(event.event_code+" "+event.name);
      if(event.importance!=CALENDAR_IMPORTANCE_HIGH && !fomc) continue;
      if(event.time_mode!=CALENDAR_TIMEMODE_DATETIME)
      { Print("Important USD event has no precise time; verify manually. No file written: ",event.name); return; }
      datetime utc=ServerToUTC(values[i].time,InpBrokerUTCStandardMinutes,InpBrokerDST);
      if(utc<InpFromUTC || utc>InpToUTC) continue;
      string name=event.name;
      StringReplace(name,";",","); StringReplace(name,"\n"," "); StringReplace(name,"\r"," ");
      int n=ArraySize(rows); ArrayResize(rows,n+1);
      rows[n]=TimeToString(utc,TIME_DATE|TIME_MINUTES)+";"+(fomc ? "FOMC" : "HIGH")+";"+name;
   }
   int file=FileOpen(InpOutputFile,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(file==INVALID_HANDLE) { Print("Cannot open output file: ",GetLastError()); return; }
   FileWrite(file,"# High-impact USD calendar and FOMC events returned by MT5. Times are UTC.");
   FileWrite(file,"#coverage_start="+TimeToString(InpFromUTC,TIME_DATE|TIME_MINUTES));
   FileWrite(file,"#coverage_end="+TimeToString(InpToUTC,TIME_DATE|TIME_MINUTES));
   for(int i=0;i<ArraySize(rows);i++) FileWrite(file,rows[i]);
   FileClose(file);
   PrintFormat("Exported %d events to MQL5/Files/%s. Verify broker DST inputs and calendar completeness before testing.",ArraySize(rows),InpOutputFile);
}
