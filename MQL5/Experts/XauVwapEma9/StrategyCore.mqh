#ifndef XAU_VWAP_EMA9_CORE
#define XAU_VWAP_EMA9_CORE

// Pure calculations shared by the EA and the executable MQL5 test harness.
enum ENUM_BROKER_DST { BROKER_DST_NONE=0, BROKER_DST_EU=1, BROKER_DST_US=2 };
enum ENUM_VWAP_VOLUME { VWAP_TICK_VOLUME=0, VWAP_REAL_VOLUME=1 };

bool ParseUtcTimestamp(const string text,datetime &value)
{
   value=0;
   if(StringLen(text)!=16 && StringLen(text)!=19) return false;
   datetime parsed=StringToTime(text);
   int flags=TIME_DATE|TIME_MINUTES;
   if(StringLen(text)==19) flags|=TIME_SECONDS;
   if(parsed<=0 || TimeToString(parsed,flags)!=text) return false;
   value=parsed;
   return true;
}

bool IsFomcEvent(string name)
{
   StringToLower(name);
   return StringFind(name,"fomc")>=0 || StringFind(name,"fed-interest")>=0 ||
          StringFind(name,"fed interest")>=0 || StringFind(name,"fed-press")>=0 ||
          StringFind(name,"fed press")>=0 || StringFind(name,"federal funds")>=0 ||
          StringFind(name,"interest-rate-decision")>=0;
}

datetime MakeDate(const int year,const int month,const int day,const int hour=0,const int minute=0)
{
   MqlDateTime d={};
   d.year=year; d.mon=month; d.day=day; d.hour=hour; d.min=minute;
   return StructToTime(d);
}

datetime DayStart(const datetime t)
{
   MqlDateTime d; TimeToStruct(t,d); d.hour=0; d.min=0; d.sec=0;
   return StructToTime(d);
}

datetime WeekStart(const datetime t)
{
   MqlDateTime d; TimeToStruct(t,d);
   return DayStart(t)-((d.day_of_week+6)%7)*86400;
}

int NthSunday(const int year,const int month,const int n)
{
   MqlDateTime d; TimeToStruct(MakeDate(year,month,1),d);
   return 1+(7-d.day_of_week)%7+(n-1)*7;
}

int LastSunday(const int year,const int month)
{
   datetime next=(month==12 ? MakeDate(year+1,1,1) : MakeDate(year,month+1,1));
   MqlDateTime d; TimeToStruct(next-86400,d);
   return d.day-d.day_of_week;
}

bool UsDST(const datetime utc)
{
   MqlDateTime d; TimeToStruct(utc,d);
   return utc>=MakeDate(d.year,3,NthSunday(d.year,3,2),7) &&
          utc<MakeDate(d.year,11,NthSunday(d.year,11,1),6);
}

bool EuDST(const datetime utc)
{
   MqlDateTime d; TimeToStruct(utc,d);
   return utc>=MakeDate(d.year,3,LastSunday(d.year,3),1) &&
          utc<MakeDate(d.year,10,LastSunday(d.year,10),1);
}

int BrokerOffset(const datetime utc,const int standard_minutes,const ENUM_BROKER_DST rule)
{
   bool summer=(rule==BROKER_DST_US ? UsDST(utc) : (rule==BROKER_DST_EU && EuDST(utc)));
   return standard_minutes+(summer ? 60 : 0);
}

datetime ServerToUTC(const datetime server,const int standard_minutes,const ENUM_BROKER_DST rule)
{
   // New York trading hours are far from the ambiguous DST transition hour.
   datetime utc=server-standard_minutes*60;
   return server-BrokerOffset(utc,standard_minutes,rule)*60;
}

datetime NewYorkTime(const datetime utc)
{
   return utc+(UsDST(utc) ? -4 : -5)*3600;
}

bool InNewYorkSession(const datetime utc,const int start_minute,const int end_minute)
{
   MqlDateTime d; TimeToStruct(NewYorkTime(utc),d);
   if(d.day_of_week==0 || d.day_of_week==6) return false;
   int m=d.hour*60+d.min;
   return m>=start_minute && m<end_minute;
}

datetime VwapAnchor(const datetime server_time,const int reset_hour)
{
   datetime anchor=DayStart(server_time)+reset_hour*3600;
   return (server_time<anchor ? anchor-86400 : anchor);
}

bool SessionVwap(const MqlRates &minutes[],const datetime anchor,const datetime exclusive_end,
                 const ENUM_VWAP_VOLUME mode,double &value)
{
   double weighted=0.0,weight=0.0;
   value=0.0;
   for(int i=0;i<ArraySize(minutes);i++)
   {
      // Only completed M1 bars wholly before the requested candle close.
      if(minutes[i].time<anchor || minutes[i].time+60>exclusive_end) continue;
      double volume=(double)(mode==VWAP_REAL_VOLUME ? minutes[i].real_volume : minutes[i].tick_volume);
      if(volume<=0.0) return false; // Do not silently substitute a different volume type.
      weighted+=(minutes[i].high+minutes[i].low+minutes[i].close)/3.0*volume;
      weight+=volume;
   }
   if(weight<=0.0) return false;
   value=weighted/weight;
   return MathIsValidNumber(value) && value>0.0;
}

double TickFloor(const double price,const double tick_size,const int digits)
{
   if(tick_size<=0.0) return 0.0;
   return NormalizeDouble(MathFloor(price/tick_size+1e-8)*tick_size,digits);
}

double TickCeil(const double price,const double tick_size,const int digits)
{
   if(tick_size<=0.0) return 0.0;
   return NormalizeDouble(MathCeil(price/tick_size-1e-8)*tick_size,digits);
}

double RiskVolume(const double budget,const double loss_per_lot,const double min_volume,
                  const double max_volume,const double step)
{
   if(budget<=0 || loss_per_lot<=0 || min_volume<=0 || max_volume<min_volume || step<=0) return 0;
   double lots=NormalizeDouble(MathFloor(MathMin(budget/loss_per_lot,max_volume)/step+1e-9)*step,8);
   if(lots<min_volume-1e-9 || lots*loss_per_lot>budget+1e-7) return 0;
   return lots;
}

bool SwingHigh(const MqlRates &bars[],const int i,const int width)
{
   // Arrays are series: 0 is unfinished. Right-hand confirmation must be closed.
   if(i-width<1 || i+width>=ArraySize(bars)) return false;
   for(int j=1;j<=width;j++)
      if(bars[i].high<=bars[i-j].high || bars[i].high<=bars[i+j].high) return false;
   return true;
}

bool SwingLow(const MqlRates &bars[],const int i,const int width)
{
   if(i-width<1 || i+width>=ArraySize(bars)) return false;
   for(int j=1;j<=width;j++)
      if(bars[i].low>=bars[i-j].low || bars[i].low>=bars[i+j].low) return false;
   return true;
}

int StructureDirection(const MqlRates &bars[],const int width,const int lookback)
{
   double h1=0,h2=0,l1=0,l2=0;
   int limit=(int)MathMin(lookback,ArraySize(bars)-width-1);
   for(int i=width+1;i<=limit;i++)
   {
      if(h2==0 && SwingHigh(bars,i,width)) { if(h1==0) h1=bars[i].high; else h2=bars[i].high; }
      if(l2==0 && SwingLow(bars,i,width)) { if(l1==0) l1=bars[i].low; else l2=bars[i].low; }
      if(h2>0 && l2>0) break;
   }
   if(h2==0 || l2==0) return 0;
   if(h1>h2 && l1>l2) return 1;
   if(h1<h2 && l1<l2) return -1;
   return 0;
}

struct PullbackSetup
{
   int direction;
   datetime signal_time;
   datetime expires;
   double trigger;
   double stop;
   double atr;
   double level;
};

bool FindPullback(const MqlRates &bars[],const double &ema[],const double &vwap[],
                  const double atr,const int direction,const int max_pullback,
                  const int breakout_lookback,const bool require_retest,
                  const double retest_atr,const double min_body,const double close_fraction,
                  const double max_signal_atr,const double buffer,const double tick_size,
                  const int digits,const int expiry_bars,PullbackSetup &setup)
{
   if(direction!=1 && direction!=-1) return false;
   int needed=max_pullback+breakout_lookback+3;
   if(ArraySize(bars)<needed || ArraySize(ema)<needed || ArraySize(vwap)<=max_pullback || atr<=0) return false;
   double range=bars[1].high-bars[1].low;
   if(range<=0 || range>atr*max_signal_atr || MathAbs(bars[1].close-bars[1].open)<range*min_body) return false;
   if(direction==1 && (bars[1].close<=bars[1].open || bars[1].close<=ema[1] ||
      bars[1].close<bars[1].high-range*close_fraction)) return false;
   if(direction==-1 && (bars[1].close>=bars[1].open || bars[1].close>=ema[1] ||
      bars[1].close>bars[1].low+range*close_fraction)) return false;

   for(int length=1;length<=max_pullback;length++)
   {
      int impulse=length+1;
      double prior_high=bars[impulse+1].high,prior_low=bars[impulse+1].low;
      for(int j=impulse+1;j<=impulse+breakout_lookback;j++)
      { prior_high=MathMax(prior_high,bars[j].high); prior_low=MathMin(prior_low,bars[j].low); }
      if(direction==1 && (bars[impulse].close<=prior_high || bars[impulse].close<=ema[impulse] ||
         bars[impulse].close<=bars[impulse].open)) continue;
      if(direction==-1 && (bars[impulse].close>=prior_low || bars[impulse].close>=ema[impulse] ||
         bars[impulse].close>=bars[impulse].open)) continue;
      double low=bars[1].low,high=bars[1].high;
      bool touched=false,valid=true;
      for(int j=1;j<=length;j++)
      {
         low=MathMin(low,bars[j].low); high=MathMax(high,bars[j].high);
         if(vwap[j]<=0 || direction*(bars[j].close-vwap[j])<=0) valid=false;
         if(bars[j].low<=ema[j]+0.1*atr && bars[j].high>=ema[j]-0.1*atr) touched=true;
      }
      if(!valid || !touched) continue;
      double level=(direction==1 ? prior_high : prior_low);
      double extreme=(direction==1 ? low : high);
      if(direction==1 && low<=prior_low) continue;
      if(direction==-1 && high>=prior_high) continue;
      if(require_retest && MathAbs(extreme-level)>retest_atr*atr) continue;
      setup.direction=direction; setup.signal_time=bars[1].time;
      setup.expires=bars[0].time+expiry_bars*300;
      setup.trigger=(direction==1 ? TickCeil(bars[1].high+tick_size,tick_size,digits) :
                                   TickFloor(bars[1].low-tick_size,tick_size,digits));
      setup.stop=(direction==1 ? TickFloor(low-buffer,tick_size,digits) : TickCeil(high+buffer,tick_size,digits));
      setup.atr=atr; setup.level=level;
      return setup.stop>0 && direction*(setup.trigger-setup.stop)>0;
   }
   return false;
}

bool TriggerValid(const PullbackSetup &setup,const double bid,const datetime now,const double max_gap_atr)
{
   if(setup.direction==0 || now>=setup.expires || setup.atr<=0) return false;
   double distance=setup.direction*(bid-setup.trigger);
   return distance>=-1e-8 && distance<=setup.atr*max_gap_atr+1e-8;
}

#endif
