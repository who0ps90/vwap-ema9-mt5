#property strict
#property version "1.00"
#include "../../Experts/XauVwapEma9/StrategyCore.mqh"

int gPassed=0,gFailed=0;

void Check(const bool condition,const string name)
{
   if(condition) { gPassed++; Print("PASS: ",name); }
   else { gFailed++; Print("FAIL: ",name); }
}

void TestTimes()
{
   datetime stamp=0;
   Check(ParseUtcTimestamp("2026.10.28 18:00",stamp) && stamp==D'2026.10.28 18:00',"Canonical UTC timestamp accepted");
   Check(!ParseUtcTimestamp("REPLACE_WITH_DATE",stamp),"CSV placeholders rejected");
   Check(!ParseUtcTimestamp("2026.99.99 18:00",stamp),"Malformed calendar date rejected");
   Check(!ParseUtcTimestamp("2026.10.28 25:00",stamp),"Malformed clock time rejected");
   Check(!UsDST(D'2026.03.08 06:59:59'),"US spring: standard time before transition");
   Check(UsDST(D'2026.03.08 07:00:00'),"US spring: DST begins at 07 UTC");
   Check(UsDST(D'2026.11.01 05:59:59'),"US autumn: DST before transition");
   Check(!UsDST(D'2026.11.01 06:00:00'),"US autumn: standard time begins at 06 UTC");
   Check(EuDST(D'2026.10.25 00:59:59'),"EU autumn: DST before transition");
   Check(!EuDST(D'2026.10.25 01:00:00'),"EU autumn: standard time begins");
   Check(NewYorkTime(D'2026.10.26 12:00')==D'2026.10.26 08:00',"NY conversion before US autumn change");
   Check(NewYorkTime(D'2026.11.02 13:00')==D'2026.11.02 08:00',"NY conversion after US autumn change");
   Check(InNewYorkSession(D'2026.10.26 12:00',480,660),"Session includes opening minute");
   Check(!InNewYorkSession(D'2026.10.26 15:00',480,660),"Session excludes closing minute");
   Check(!InNewYorkSession(D'2026.10.25 12:00',480,660),"Weekend blocked");
   Check(ServerToUTC(D'2026.07.01 15:00',120,BROKER_DST_EU)==D'2026.07.01 12:00',"Summer broker UTC conversion");
   Check(ServerToUTC(D'2026.12.01 15:00',120,BROKER_DST_EU)==D'2026.12.01 13:00',"Winter broker UTC conversion");
   Check(WeekStart(D'2026.10.25 10:00')==D'2026.10.19',"Sunday belongs to previous Monday week");
   Check(VwapAnchor(D'2026.10.26 02:00',3)==D'2026.10.25 03:00',"VWAP anchor before configured reset");
}

void TestVwapAndRisk()
{
   MqlRates minutes[]; ArrayResize(minutes,4); ZeroMemory(minutes);
   for(int i=0;i<4;i++)
   {
      minutes[i].time=D'2026.10.26 00:00'+i*60;
      minutes[i].high=100+i*10; minutes[i].low=100+i*10; minutes[i].close=100+i*10;
      minutes[i].tick_volume=i+1;
   }
   double value=0;
   Check(SessionVwap(minutes,D'2026.10.26',D'2026.10.26 00:02',VWAP_TICK_VOLUME,value) &&
         MathAbs(value-106.6666666667)<1e-7,"VWAP uses actual tick-volume weights");
   minutes[2].high=999999; minutes[3].close=999999;
   Check(SessionVwap(minutes,D'2026.10.26',D'2026.10.26 00:02',VWAP_TICK_VOLUME,value) &&
         MathAbs(value-106.6666666667)<1e-7,"Future/current M1 prices cannot alter earlier VWAP");
   Check(!SessionVwap(minutes,D'2026.10.26',D'2026.10.26 00:02',VWAP_REAL_VOLUME,value),"Real volume never silently falls back to ticks");
   minutes[1].tick_volume=0;
   Check(!SessionVwap(minutes,D'2026.10.26',D'2026.10.26 00:02',VWAP_TICK_VOLUME,value),"Zero selected volume rejected");
   Check(!SessionVwap(minutes,D'2026.10.27',D'2026.10.27 00:02',VWAP_TICK_VOLUME,value),"Empty VWAP session rejected");
   Check(MathAbs(TickFloor(4000.13,0.25,2)-4000.0)<1e-8,"Prices align down to tick size");
   Check(MathAbs(TickCeil(4000.13,0.25,2)-4000.25)<1e-8,"Prices align up to tick size");
   Check(MathAbs(RiskVolume(25,1050,0.01,10,0.01)-0.02)<1e-8,"Lot sizing rounds DOWN under cash budget");
   Check(RiskVolume(5,1050,0.01,10,0.01)==0,"Minimum lot exceeding budget is rejected");
   Check(MathAbs(RiskVolume(1000,100,0.1,0.3,0.1)-0.3)<1e-8,"Maximum lot cap honoured");
   Check(RiskVolume(25,1050,0.01,10,0)==0,"Invalid volume step rejected");
   for(int i=1;i<=200;i++)
   {
      double budget=i*0.73,loss=997.0+i*3,lot=RiskVolume(budget,loss,0.01,2.0,0.01);
      Check(lot*loss<=budget+1e-7,"Sizing invariant: cash risk never rounds up #"+IntegerToString(i));
   }
}

void MakeBuyFixture(MqlRates &bars[],double &ema[],double &vwap[])
{
   ArrayResize(bars,15); ArrayResize(ema,15); ArrayResize(vwap,15); ZeroMemory(bars);
   for(int i=0;i<15;i++)
   {
      bars[i].time=D'2026.10.26 14:00'-i*300;
      bars[i].open=98; bars[i].high=100; bars[i].low=96; bars[i].close=99;
      ema[i]=100.5; vwap[i]=99;
   }
   bars[2].open=99; bars[2].high=103; bars[2].low=98; bars[2].close=102;
   bars[1].open=100.4; bars[1].high=102; bars[1].low=100.2; bars[1].close=101.8;
}

bool EvaluateFixture(MqlRates &bars[],double &ema[],double &vwap[],const int direction,PullbackSetup &setup)
{
   return FindPullback(bars,ema,vwap,2,direction,2,6,true,0.35,0.25,0.35,1.8,0.2,0.01,2,3,setup);
}

void TestSignals()
{
   MqlRates bars[]; double ema[],vwap[]; PullbackSetup setup;
   MakeBuyFixture(bars,ema,vwap);
   Check(EvaluateFixture(bars,ema,vwap,1,setup),"Bullish breakout/retest/rejection setup accepted");
   Check(MathAbs(setup.trigger-102.01)<1e-8 && MathAbs(setup.stop-100.0)<1e-8,"Buy trigger and complete pullback stop");
   Check(setup.expires==bars[0].time+900,"Three-bar expiry from first eligible M5 bar");
   Check(!TriggerValid(setup,102.0,bars[0].time,0.2),"Unbroken trigger cannot enter");
   Check(TriggerValid(setup,102.02,bars[0].time,0.2),"Timely trigger break accepted");
   Check(!TriggerValid(setup,103,bars[0].time,0.2),"Gap through trigger rejected");
   Check(!TriggerValid(setup,102.02,setup.expires,0.2),"Expiry boundary cannot enter");
   bars[0].high=9999; bars[0].low=1; bars[0].close=1;
   Check(EvaluateFixture(bars,ema,vwap,1,setup),"Unfinished candle OHLC cannot create/remove signal");
   bars[1].close=100.45;
   Check(!EvaluateFixture(bars,ema,vwap,1,setup),"Weak/doji signal rejected");
   MakeBuyFixture(bars,ema,vwap); bars[1].low=97;
   Check(!EvaluateFixture(bars,ema,vwap,1,setup),"Oversized rejection candle rejected");
   MakeBuyFixture(bars,ema,vwap); vwap[1]=102;
   Check(!EvaluateFixture(bars,ema,vwap,1,setup),"Pullback close across VWAP rejected");
   MakeBuyFixture(bars,ema,vwap); bars[2].close=99.9;
   Check(!EvaluateFixture(bars,ema,vwap,1,setup),"No prior breakout means no continuation setup");
   MakeBuyFixture(bars,ema,vwap);
   for(int i=0;i<ArraySize(bars);i++)
   {
      double high=bars[i].high;
      bars[i].high=200-bars[i].low; bars[i].low=200-high;
      bars[i].open=200-bars[i].open; bars[i].close=200-bars[i].close;
      ema[i]=200-ema[i]; vwap[i]=200-vwap[i];
   }
   Check(EvaluateFixture(bars,ema,vwap,-1,setup),"Mirrored bearish setup accepted");
   Check(MathAbs(setup.trigger-97.99)<1e-8 && MathAbs(setup.stop-100)<1e-8,"Sell trigger and stop are mirrored");
   Check(TriggerValid(setup,97.98,bars[0].time,0.2),"Sell trigger uses correct direction");

   ArrayResize(bars,12);
   for(int i=0;i<12;i++) { bars[i].high=100; bars[i].low=90; }
   bars[1].high=110;
   Check(!SwingHigh(bars,1,2),"Unconfirmed swing cannot be used");
   bars[3].high=110; bars[1].high=100;
   Check(SwingHigh(bars,3,2),"Two closed right-hand bars confirm swing");
   bars[0].high=1000;
   Check(SwingHigh(bars,3,2),"Forming bar cannot affect confirmed swing");
   Check(StructureDirection(bars,2,10)==0,"Insufficient confirmed swing pairs reject direction");
   ArrayResize(bars,20);
   for(int i=0;i<20;i++) { bars[i].high=110; bars[i].low=100; }
   bars[3].high=120; bars[9].high=115; bars[6].low=95; bars[12].low=90;
   Check(StructureDirection(bars,2,16)==1,"Higher confirmed highs and lows establish bullish structure");
   for(int i=0;i<20;i++) { double high=bars[i].high; bars[i].high=220-bars[i].low; bars[i].low=220-high; }
   Check(StructureDirection(bars,2,16)==-1,"Lower confirmed highs and lows establish bearish structure");
   Check(IsFomcEvent("FOMC Press Conference"),"FOMC receives extended buffers");
   Check(!IsFomcEvent("Consumer Price Index"),"Ordinary inflation release uses normal buffers");
}

void OnStart()
{
   TestTimes(); TestVwapAndRisk(); TestSignals();
   string summary=StringFormat("CORE TESTS: %d passed; %d failed",gPassed,gFailed);
   Print(summary);
   int out=FileOpen("XauVwapEma9_core_tests.txt",FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(out!=INVALID_HANDLE) { FileWrite(out,summary); FileClose(out); }
}
