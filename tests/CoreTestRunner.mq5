// Math-mode Strategy Tester adapter for the exact same test script.
#define OnStart RunCalculationTests
#include "../MQL5/Scripts/XauVwapEma9/CoreTests.mq5"
#undef OnStart

int OnInit() { RunCalculationTests(); return (gFailed==0 ? INIT_SUCCEEDED : INIT_FAILED); }
void OnTick() {}
double OnTester() { return (gFailed==0 ? (double)gPassed : -(double)gFailed); }
