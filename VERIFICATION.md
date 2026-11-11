# Verification — XauVwapEma9 1.00

Build date: 25 October 2026 (Malaysia time).

## Completed

- Native MetaEditor compilation of the EA, the MQL5 calculation-test script and the USD calendar exporter: **0 errors, 0 warnings** for each. Logs: `build/XauVwapEma9.log`, `build/CoreTests.log`, `build/ExportUsdNews.log`.
- **253 source-adapted calculation regression checks passed**, using Node.js to execute calculation bodies extracted directly from `StrategyCore.mqh`. The adapter changes MQL type declarations and reference-output syntax and supplies date/array/math compatibility helpers. It does not independently reimplement the trading calculations. Command: `node tests/core-regression.mjs`. Summary: `build/core-regression.txt`.
- Checks cover UTC parsing, US/EU DST boundaries, New York session edges and weekends, broker offset conversion, VWAP anchors/weighting, exclusion of later M1 data, rejection of missing selected volume, tick rounding, downward lot rounding, minimum lot rejection, lot caps, 200 risk-budget invariants, completed swing confirmation, bullish/bearish structure, mirrored pullback setups, rejection candles, trigger breaks, excessive entry gaps, signal expiry, and FOMC classification.
- Source inspection of broker minimum stops, account-currency loss calculation, margin/preflight checks, trade response handling, partial-fill accounting, restart-persistent halts, and symbol/account ownership checks.

## Not completed / not claimed

- The native MQL5 test script compiled successfully, but an isolated MT5 terminal with no copied account credentials did not produce a completed native test result. A math-mode tester attempt also did not complete successfully. **The 253 passed checks are the source-adapted regression suite, not a claimed native MT5 runtime pass.**
- No authenticated broker Strategy Tester run, real-tick backtest, order-execution integration test, profitability measurement, optimisation, forward test, or live trade was performed.
- No claim is made that these settings are optimal or profitable. Actual symbol specifications, commission, spreads, history, calendar coverage, clock/DST settings and execution must be verified on the target broker.

An isolated terminal was used only to attempt non-trading calculation tests. No user account credentials were copied, and automated account trading was disabled in that terminal. The deliverable has real-account trading disabled by default.
