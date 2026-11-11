# XAU VWAP + EMA 9 — MT5 Expert Advisor

Version 1.00 · Built 25 October 2026.

This EA implements the intraday trend-pullback framework researched in this chat. It uses the attached chart's symbol, including suffixes such as `XAUUSDm` or names such as `GOLD#`. The chart timeframe does not change the strategy: entries use M5, confirmation uses M15, and target-room checks use closed H1/D1 data.

**The default is automatic trading on a DEMO account. Real/contest accounts are rejected unless `InpAllowRealAccount` is explicitly enabled. No live account has been activated by building these files. Compilation and unit tests do not establish profitability.**

## Install and start on demo

1. In MT5 choose **File → Open Data Folder**.
2. Copy this package's `MQL5/Experts/XauVwapEma9` folder into that data folder's `MQL5/Experts`. The ready-to-use file is `XauVwapEma9.ex5`; the source and shared header are also included.
3. Optionally copy `MQL5/Scripts/XauVwapEma9` for calendar export and calculation tests. Copying scripts does not run them.
4. Refresh **Navigator → Expert Advisors**, then attach **XauVwapEma9** to your broker's gold chart on a **demo** account. Any chart timeframe works; M5 is easiest to watch.
5. In the EA properties allow algorithmic trading, and enable MT5's **Algo Trading** button. DLL imports and WebRequest URLs are unnecessary.
6. Read the chart status and **Toolbox → Experts/Journal**. The bot waits for a fresh M5 candle, enough M1/M5/M15/H1/D1 history, the New York session, an available USD calendar, and a qualifying setup. It does not force a trade when attached.

Only run one copy on a symbol in a terminal. Do not mix manual trades or other EAs on the same symbol in a netting account. An exclusive terminal file lock rejects a second local copy, and any existing position or pending order on that symbol blocks new entries. Separate terminal installations cannot share this local lock.

## Default behaviour

| Control | Default |
|---|---|
| Symbol | Attached chart; gold-symbol check enabled |
| Session | 08:00–11:00 New York, Monday–Friday; US DST automatic |
| Session-end exit | Close this EA's positions; retry failed closes on later ticks/timer events |
| Entry / direction | M5 / M15 |
| EMA / ATR | EMA 9 close; ATR 14 |
| VWAP | M1 HLC3 weighted by broker **tick volume**, reset 00:00 broker-server time |
| Risk | 0.25% of account equity per entry, including cost reserve |
| Target | 2R from the executable quote used to submit the order |
| Exposure | One position, no averaging/grid/martingale |
| Daily entries | Maximum 3, counting filled position IDs rather than partial fills |
| Daily stop | Two consecutive net losing completed positions, or 0.75% equity loss |
| Weekly stop | 2% equity loss |
| News | MT5 high-impact USD events; block 15 min before / 30 min after |
| FOMC | Wider 60 min before / 120 min after buffers |
| Before news | Close this EA's positions when a known news window begins |
| Calendar failure | Block new entries; unknown calendar status alone does not force an exit |
| Signal expiry | Three subsequent M5 bars, without extending the original expiry |
| RSI | Off; optional M15 RSI 14 above/below 50 |

Broker-day and broker-week limits are separate from the New York trading session. At the current October 2026 US daylight-saving offset, the session is 20:00–23:00 Malaysia time; after the US autumn change it is 21:00–00:00 Malaysia time.

### Check these broker-dependent inputs

- **`InpCommissionPerLot=7.0`** is an estimated **round-trip amount in your account currency per 1.0 lot**. It is not automatically read from a commission schedule. Enter your broker's actual cost estimate, including zero if appropriate. On a non-USD account, 7 means seven units of that account currency.
- **`InpMaxSpreadPrice=0.60`** and **`InpSlippagePrice=0.20`** are gold **price units**, not pips or points. On a USD gold quote, 0.60 means $0.60/oz regardless of quote digits. The slippage allowance is included once in the estimated cash risk and passed as execution deviation where supported.
- **`InpVwapResetServerHour=0`** is the broker chart's midnight. It is not automatically the London open or New York close. Change this only as part of a separately tested anchor convention.
- **`InpVwapVolume=VWAP_TICK_VOLUME`** explicitly uses broker quote activity. Real-volume mode never silently falls back to ticks; missing/zero selected volume blocks signals.
- Live/demo session timing normally uses `TimeGMT()` and the computer's correct clock. Historical tests instead require the correct broker UTC offset and DST inputs. Defaults of UTC+2 standard / European DST are a starting configuration, **not a verified claim about your broker**.

## Exact automated strategy

1. Use completed M15 candles only. The two most recent closes must be on the appropriate side of session VWAP, EMA must be on that side, and VWAP must slope in that direction compared with three completed bars earlier. The VWAP comparisons must share an anchor.
2. Require two confirmed M15 swing highs and two confirmed swing lows, using two closed bars on each side. Higher highs plus higher lows allow buys; lower highs plus lower lows allow sells. Reject a trend whose newest confirmed protective swing has already broken.
3. Find an M5 impulse that closed beyond the preceding six bars' high/low. A pullback may last one to four bars, including the signal candle. It must touch the EMA region, preserve the pre-breakout swing extreme, and keep every pullback close on the correct side of VWAP.
4. By default, the pullback extreme must be within 0.35 ATR of that breakout level, supplying the level/retest confirmation. This is a mechanical approximation of discretionary level analysis.
5. The signal candle must close in the trend direction, beyond EMA, with a body at least 25% of its range and a close within the top/bottom 35%. Its range must not exceed 1.8 ATR.
6. Arm a **virtual trigger** one tick beyond the signal high/low. Both trigger comparisons use Bid, matching ordinary Bid-based gold chart candles. Buy orders execute at Ask, sells at Bid. Triggers are local to the running EA; no broker pending entry is left behind.
7. Cancel if bias changes, a completed M5 candle closes through VWAP, price invalidates the pullback stop, session/news/risk gates fail, or three M5 bars elapse. Reject a trigger overshoot greater than 0.20 ATR. An individual signal gets one order attempt only.
8. Place SL beyond the entire pullback by the greater of 0.10 ATR or 1.5 current spreads. The executable entry-to-stop distance must be 0.8–3.0 ATR. Tick-align prices in the protective direction. Broker stop-distance constraints must also pass.
9. Check room to previous-day high/low and unbroken confirmed H1 swing levels. Skip if an opposing level is before or too close to the 2R target. This does **not** incorporate an Asian-session range, discretionary zones, or DXY/yield feeds.
10. Submit a market order with server-side SL and TP, then manage the session/news/risk exits. There is no trailing stop, partial profit taking, automatic breakeven or EMA-based early exit.

Stops/targets use the submitted quote. Actual fills can change the realised reward/risk. The EA attempts to flatten a fill worse than its slippage reserve, and flattens any owned position missing SL or TP. Stops, deviation limits and risk limits cannot guarantee a maximum realised loss during gaps, disconnections or broker rejection. Local session/news exits require a running, connected terminal; server-side SL/TP remain when the EA is removed.

## Sizing and limits

`OrderCalcProfit` estimates the entry-to-stop loss in the account currency using the broker's actual symbol specification. The EA adds estimated round-trip commission and adverse slippage. Spread is already included in the executable entry-to-stop distance, so sizing does not charge it twice.

The EA also rejects a trade if estimated spread + commission + slippage exceeds 10% of entry-to-stop price risk. It rounds lots **down**, respects symbol min/max/step and the configured lot cap, checks free margin and `OrderCheck`, and refuses a minimum lot that would exceed the risk budget. The risk budget is also capped by the remaining daily and weekly allowance.

Equity thresholds are **account-wide**: other positions and charges can trigger them. Baselines reconstruct the broker-day/week opening balance, adjusted for deposits/withdrawals, from account history; they are not trailing equity high-water marks. Opening floating P&L is not reconstructed as a historical equity snapshot. Cash transfers adjust the reference balance; a previously latched halt remains latched.

Entry counts and completed-trade streaks are specific to this symbol and magic number. They include entry/exit commissions, swaps, fees, partial fills, and manual closing deals for an identified EA position. Halts persist across restarts using terminal global variables for the same account/symbol/magic. Daily entry/streak counts are rebuilt from history. Uncertain execution responses latch a daily halt to avoid repeat submissions. Do not change the magic to bypass a halt; investigate the history first.

## Backtest correctly

1. Open **View → Strategy Tester**, select this EA and the broker's gold symbol. Use **Every tick based on real ticks**; the virtual intrabar trigger cannot be assessed reliably with open-price-only modelling.
2. Set the initial deposit, account currency, realistic execution delay and broker costs. Verify the tester's commission assumptions separately from the EA's sizing reserve.
3. Set `InpServerUTCStandardMinutes` and `InpServerDST` to match the historical broker data. `TimeGMT()` equals simulated server time in the tester and cannot infer the broker's historical timezone.
4. Copy the package's `MQL5/Files/XauVwapEma9_news.csv` into MT5's `MQL5/Files`, then replace that deliberately invalid placeholder with a verified USD news CSV covering the whole test interval **plus at least the larger before/after news buffers at the endpoints**. `NEWS_AUTO` uses the native calendar on demo/live and CSV in the tester. The EA explicitly fails initialisation if the required CSV is absent or malformed.
5. The compiler's `#property tester_file` copies `XauVwapEma9_news.csv` to tester agents. Use that default filename for testing. The example CSV is deliberately invalid and must not be renamed and used as actual history.
6. Alternatively, explicitly select `NEWS_DISABLED` for a **technical-only smoke test**. Its results do not represent news-filtered operation. Do not mistake a zero-trade result caused by missing calendar coverage for a strategy performance result.
7. Use a separate later period for out-of-sample evaluation, then demo forward-test. No backtest performance, win rate or profitability is claimed by this package.

### Export the MT5 USD calendar

Install `ExportUsdNews.ex5` under `MQL5/Scripts/XauVwapEma9` and run it on a connected terminal. Choose the UTC range and the broker's standard UTC offset/DST convention. It writes `MQL5/Files/XauVwapEma9_news.csv`, selecting high-impact USD and FOMC events from the native MT5 calendar. It refuses to overwrite an existing file unless explicitly enabled. Check that all important releases are present and correctly timed; an available calendar is not a guarantee of completeness, and exported data may contain revised event times.

CSV format, with **UTC** timestamps:

```text
#coverage_start=2026.10.01 00:00
#coverage_end=2026.10.31 23:59
2026.10.28 18:00;FOMC;Federal Reserve policy decision
```

That single row illustrates the format, not a complete calendar. `HIGH` uses normal buffers; `FOMC` uses wider buffers. The parser accepts canonical `YYYY.MM.DD HH:MM` or second-resolution timestamps and rejects malformed dates, placeholders, unknown row types, out-of-coverage rows, and missing coverage headers. CSV contents are refreshed once per minute.

## Build and calculation tests

The compiled `.ex5` is supplied. To rebuild on this machine:

```powershell
.\scripts\build.ps1
```

For another MT5 installation, pass `-MetaEditor 'C:\Path\MetaEditor64.exe'`. The script compiles the EA, calculation-test script and calendar exporter and requires **0 errors and 0 warnings**. Logs are stored in `build/`.

Run `CoreTests.ex5` from MT5's Navigator to execute the actual shared MQL5 calculations against synthetic fixtures. It performs no trading and writes `MQL5/Files/XauVwapEma9_core_tests.txt`. Tests cover DST/session boundaries, VWAP weighting and future-data exclusion, volume failures, tick/lot rounding, minimum-lot rejection, 200 cash-risk invariants, confirmed swings, mirrored pullback signals, and trigger expiry/gap rejection. This is calculation verification, not an end-to-end brokerage test.

For local source-adapted regression checks without a connected MT5 account, run `node tests/core-regression.mjs`. This executes extracted calculation bodies with a small syntax/date compatibility adapter. It does not replace a native MT5/broker execution test.

## Reference documentation

- [OrderCalcProfit: account-currency risk](https://www.mql5.com/en/docs/trading/ordercalcprofit)
- [OrderCheck: validation is not execution confirmation](https://www.mql5.com/en/docs/trading/ordercheck)
- [Economic calendar: server-time convention](https://www.mql5.com/en/docs/calendar)
- [TimeGMT: Strategy Tester limitation](https://www.mql5.com/en/docs/dateandtime/timegmt)
- [MT5 installation and EA operation](https://www.metatrader5.com/en/terminal/help/algotrading/trade_robots_indicators)

See `VERIFICATION.md` for the checks actually completed for this build.
