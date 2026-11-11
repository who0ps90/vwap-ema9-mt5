// Execute the calculation bodies extracted from the actual MQL5 header.
// Only syntax/type/reference adaptations are made. This is not an MT5 runtime emulator.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = fs.readFileSync(path.join(root, 'MQL5/Experts/XauVwapEma9/StrategyCore.mqh'), 'utf8');
const names = ['ParseUtcTimestamp', 'IsFomcEvent', 'MakeDate', 'DayStart', 'WeekStart', 'NthSunday',
  'LastSunday', 'UsDST', 'EuDST', 'BrokerOffset', 'ServerToUTC', 'NewYorkTime', 'InNewYorkSession',
  'VwapAnchor', 'SessionVwap', 'TickFloor', 'TickCeil', 'RiskVolume', 'SwingHigh', 'SwingLow',
  'StructureDirection', 'FindPullback', 'TriggerValid'];
const scalar = '(?:int|double|long|datetime|bool|string|ENUM_BROKER_DST|ENUM_VWAP_VOLUME)';
let adapted = '';
for (const name of names) {
  const signature = new RegExp(`\\b${scalar}\\s+${name}\\s*\\(([^)]*)\\)\\s*\\{`, 'm');
  const match = source.match(signature);
  assert.ok(match, `Cannot locate source function ${name}`);
  let offset = match.index + match[0].length;
  const start = offset;
  let depth = 1;
  // Current source has no brace characters in literals or block comments in these functions.
  while (depth && offset < source.length) {
    if (source[offset] === '{') depth++;
    if (source[offset] === '}') depth--;
    offset++;
  }
  assert.equal(depth, 0, `Unbalanced function ${name}`);
  let parameters = match[1]
    .replace(/\bconst\s+/g, '')
    .replace(new RegExp(`\\b(?:${scalar}|MqlRates|PullbackSetup)\\s+`, 'g'), '')
    .replace(/&/g, '').replace(/\[\]/g, '');
  let body = source.slice(start, offset - 1)
    .replace(/\bMqlDateTime\s+(\w+)\s*;/g, 'let $1={};')
    .replace(/\bMqlDateTime\s+/g, 'let ')
    .replace(new RegExp(`\\b${scalar}\\s+(\\w+)`, 'g'), 'let $1')
    .replace(new RegExp(`\\(${scalar}\\)`, 'g'), '');
  if (name === 'SessionVwap' || name === 'ParseUtcTimestamp') {
    parameters = parameters.replace(/\bvalue\b/g, 'output');
    body = body.replace(/\bvalue\b/g, 'output.value');
  }
  adapted += `function ${name}(${parameters}) {${body}}\n`;
}

const epoch = value => Date.parse(value.replace(' ', 'T') + 'Z') / 1000;
const sandbox = {
  BROKER_DST_NONE: 0, BROKER_DST_EU: 1, BROKER_DST_US: 2,
  VWAP_TICK_VOLUME: 0, VWAP_REAL_VOLUME: 1,
  TIME_DATE: 1, TIME_MINUTES: 2, TIME_SECONDS: 4,
  ArraySize: x => x.length,
  MathMin: Math.min, MathMax: Math.max, MathAbs: Math.abs,
  MathFloor: Math.floor, MathCeil: Math.ceil, MathIsValidNumber: Number.isFinite,
  NormalizeDouble: (x, digits) => Number(x.toFixed(digits)),
  StringLen: x => x.length, StringFind: (s, part) => s.indexOf(part),
  StringToTime: text => epoch(text.replaceAll('.', '-')),
  TimeToString: (seconds, flags) => {
    if (!Number.isFinite(seconds)) return '';
    const text = new Date(seconds * 1000).toISOString();
    return (text.slice(0, 10).replaceAll('-', '.') + ' ' + text.slice(11, flags & 4 ? 19 : 16));
  },
  StructToTime: d => Date.UTC(d.year, d.mon - 1, d.day, d.hour || 0, d.min || 0, d.sec || 0) / 1000,
  TimeToStruct: (seconds, out) => {
    const d = new Date(seconds * 1000);
    Object.assign(out, { year: d.getUTCFullYear(), mon: d.getUTCMonth() + 1, day: d.getUTCDate(),
      hour: d.getUTCHours(), min: d.getUTCMinutes(), sec: d.getUTCSeconds(), day_of_week: d.getUTCDay() });
  },
  // MQL StringToLower mutates its reference argument. Adapt just that statement below.
};
adapted = adapted.replace('StringToLower(name);', 'name=name.toLowerCase();');
vm.createContext(sandbox);
vm.runInContext(adapted, sandbox, { filename: 'source-adapted-StrategyCore.mqh' });
let passed = 0;
function check(condition, label) { assert.ok(condition, label); passed++; }
const c = sandbox;

check(!c.UsDST(epoch('2026-03-08 06:59:59')), 'US DST before spring switch');
check(c.UsDST(epoch('2026-03-08 07:00:00')), 'US DST at spring switch');
check(c.UsDST(epoch('2026-11-01 05:59:59')), 'US DST before autumn switch');
check(!c.UsDST(epoch('2026-11-01 06:00:00')), 'US DST at autumn switch');
check(c.EuDST(epoch('2026-10-25 00:59:59')), 'EU DST before autumn switch');
check(!c.EuDST(epoch('2026-10-25 01:00:00')), 'EU DST at autumn switch');
check(c.NewYorkTime(epoch('2026-10-26 12:00')) === epoch('2026-10-26 08:00'), 'NY summer session conversion');
check(c.NewYorkTime(epoch('2026-11-02 13:00')) === epoch('2026-11-02 08:00'), 'NY winter session conversion');
check(c.InNewYorkSession(epoch('2026-10-26 12:00'), 480, 660), 'Opening minute included');
check(!c.InNewYorkSession(epoch('2026-10-26 15:00'), 480, 660), 'Closing minute excluded');
check(!c.InNewYorkSession(epoch('2026-10-25 12:00'), 480, 660), 'Weekend excluded');
check(c.ServerToUTC(epoch('2026-07-01 15:00'), 120, 1) === epoch('2026-07-01 12:00'), 'Broker summer offset');
check(c.ServerToUTC(epoch('2026-12-01 15:00'), 120, 1) === epoch('2026-12-01 13:00'), 'Broker winter offset');
check(c.WeekStart(epoch('2026-10-25 10:00')) === epoch('2026-10-19 00:00'), 'Broker week begins Monday');
check(c.VwapAnchor(epoch('2026-10-26 02:00'), 3) === epoch('2026-10-25 03:00'), 'Anchor preceding reset');
let out = {};
check(c.ParseUtcTimestamp('2026.10.28 18:00', out) && out.value === epoch('2026-10-28 18:00'), 'Canonical CSV date');
check(!c.ParseUtcTimestamp('REPLACE_WITH_DATE', out), 'Placeholder rejected');
check(!c.ParseUtcTimestamp('2026.99.99 18:00', out), 'Malformed date rejected');
check(!c.ParseUtcTimestamp('2026.10.28 25:00', out), 'Malformed time rejected');

const base = epoch('2026-10-26 00:00');
const minutes = Array.from({ length: 4 }, (_, i) => ({ time: base + i * 60, high: 100 + i * 10,
  low: 100 + i * 10, close: 100 + i * 10, tick_volume: i + 1, real_volume: 0 }));
check(c.SessionVwap(minutes, base, base + 120, 0, out) && Math.abs(out.value - 106.6666666667) < 1e-7, 'Weighted VWAP');
minutes[2].high = 999999; minutes[3].close = 999999;
check(c.SessionVwap(minutes, base, base + 120, 0, out) && Math.abs(out.value - 106.6666666667) < 1e-7, 'Future M1 bars excluded');
check(!c.SessionVwap(minutes, base, base + 120, 1, out), 'Real volume does not substitute ticks');
minutes[1].tick_volume = 0;
check(!c.SessionVwap(minutes, base, base + 120, 0, out), 'Zero volume rejected');
check(!c.SessionVwap(minutes, base + 86400, base + 86520, 0, out), 'Empty session rejected');
check(c.TickFloor(4000.13, 0.25, 2) === 4000, 'Tick floor');
check(c.TickCeil(4000.13, 0.25, 2) === 4000.25, 'Tick ceiling');
check(c.RiskVolume(25, 1050, 0.01, 10, 0.01) === 0.02, 'Lots round down');
check(c.RiskVolume(5, 1050, 0.01, 10, 0.01) === 0, 'Minimum lot cannot exceed risk');
check(c.RiskVolume(1000, 100, 0.1, 0.3, 0.1) === 0.3, 'Maximum lot honoured');
check(c.RiskVolume(25, 1050, 0.01, 10, 0) === 0, 'Invalid step rejected');
for (let i = 1; i <= 200; i++) {
  const budget = i * 0.73, loss = 997 + i * 3;
  const lot = c.RiskVolume(budget, loss, 0.01, 2, 0.01);
  check(lot * loss <= budget + 1e-7 && (lot === 0 || lot >= 0.01), `Risk invariant ${i}`);
}

function fixture() {
  const bars = Array.from({ length: 15 }, (_, i) => ({ time: epoch('2026-10-26 14:00') - i * 300,
    open: 98, high: 100, low: 96, close: 99 }));
  Object.assign(bars[2], { open: 99, high: 103, low: 98, close: 102 });
  Object.assign(bars[1], { open: 100.4, high: 102, low: 100.2, close: 101.8 });
  return { bars, ema: Array(15).fill(100.5), vwap: Array(15).fill(99) };
}
function evaluate(f, direction, setup) {
  return c.FindPullback(f.bars, f.ema, f.vwap, 2, direction, 2, 6, true, 0.35,
    0.25, 0.35, 1.8, 0.2, 0.01, 2, 3, setup);
}
let f = fixture(), setup = {};
check(evaluate(f, 1, setup), 'Bullish setup');
check(Math.abs(setup.trigger - 102.01) < 1e-8 && setup.stop === 100, 'Buy trigger and pullback stop');
check(setup.expires === f.bars[0].time + 900, 'Expiry fixed at three bars');
check(!c.TriggerValid(setup, 102, f.bars[0].time, 0.2), 'Unbroken trigger rejected');
check(c.TriggerValid(setup, 102.02, f.bars[0].time, 0.2), 'Timely break accepted');
check(!c.TriggerValid(setup, 103, f.bars[0].time, 0.2), 'Gap rejected');
check(!c.TriggerValid(setup, 102.02, setup.expires, 0.2), 'Expired trigger rejected');
Object.assign(f.bars[0], { high: 9999, low: 1, close: 1 });
check(evaluate(f, 1, setup), 'Forming candle cannot change signal');
f.bars[1].close = 100.45;
check(!evaluate(f, 1, setup), 'Doji rejected');
f = fixture(); f.bars[1].low = 97;
check(!evaluate(f, 1, setup), 'Oversized candle rejected');
f = fixture(); f.vwap[1] = 102;
check(!evaluate(f, 1, setup), 'VWAP invalidation');
f = fixture(); f.bars[2].close = 99.9;
check(!evaluate(f, 1, setup), 'Breakout required');
f = fixture();
for (let i = 0; i < f.bars.length; i++) {
  const b = f.bars[i], high = b.high;
  b.high = 200 - b.low; b.low = 200 - high;
  b.open = 200 - b.open; b.close = 200 - b.close;
  f.ema[i] = 200 - f.ema[i]; f.vwap[i] = 200 - f.vwap[i];
}
check(evaluate(f, -1, setup), 'Mirrored bearish setup');
check(Math.abs(setup.trigger - 97.99) < 1e-8 && setup.stop === 100, 'Sell trigger and stop');
check(c.TriggerValid(setup, 97.98, f.bars[0].time, 0.2), 'Sell direction trigger');
let bars = Array.from({ length: 20 }, () => ({ high: 100, low: 90 }));
bars[1].high = 110;
check(!c.SwingHigh(bars, 1, 2), 'Unconfirmed swing rejected');
bars[3].high = 110; bars[1].high = 100;
check(c.SwingHigh(bars, 3, 2), 'Confirmed swing accepted');
bars[0].high = 1000;
check(c.SwingHigh(bars, 3, 2), 'Swing ignores forming bar');
check(c.StructureDirection(bars, 2, 10) === 0, 'Two swing pairs required');
bars = Array.from({ length: 20 }, () => ({ high: 110, low: 100 }));
bars[3].high = 120; bars[9].high = 115; bars[6].low = 95; bars[12].low = 90;
check(c.StructureDirection(bars, 2, 16) === 1, 'Bullish structure');
bars = bars.map(b => ({ high: 220 - b.low, low: 220 - b.high }));
check(c.StructureDirection(bars, 2, 16) === -1, 'Bearish structure');
check(c.IsFomcEvent('FOMC Press Conference'), 'FOMC classification');
check(!c.IsFomcEvent('Consumer Price Index'), 'CPI ordinary buffer classification');

const summary = `SOURCE-ADAPTED CORE REGRESSION: ${passed} passed; 0 failed`;
fs.mkdirSync(path.join(root, 'build'), { recursive: true });
fs.writeFileSync(path.join(root, 'build/core-regression.txt'), summary + '\n');
console.log(summary);
