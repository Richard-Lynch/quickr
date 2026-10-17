// JS `String(x)` for a few thousand doubles -> shared/fixtures/jsnumber-vectors.json, the
// reference for the Swift (`JSNumber.string`) and Python (`js_number_string`) ports.
// Deterministic (seeded); run once with `node scripts/gen-jsnumber-vectors.js` and commit.
import { writeFileSync } from 'node:fs';

const OUT = new URL('../../shared/fixtures/jsnumber-vectors.json', import.meta.url);
const RANDOM_BITS = 2500;
const RANDOM_DECIMALS = 1000;

// splitmix64
let state = 0x9e3779b97f4a7c15n;
const MASK = (1n << 64n) - 1n;
function next() {
  state = (state + 0x9e3779b97f4a7c15n) & MASK;
  let z = state;
  z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & MASK;
  z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & MASK;
  return z ^ (z >> 31n);
}

const view = new DataView(new ArrayBuffer(8));
const fromBits = (bits) => (view.setBigUint64(0, bits), view.getFloat64(0));
const toBits = (x) => (view.setFloat64(0, x), view.getBigUint64(0).toString(16).padStart(16, '0'));

const values = [
  0,
  -0,
  1,
  -1,
  7,
  7.5,
  0.1,
  0.2,
  0.1 + 0.2,
  1 / 3,
  2 / 3,
  100,
  123456789.125,
  Number.MAX_SAFE_INTEGER,
  Number.MAX_SAFE_INTEGER + 1,
  Number.MAX_SAFE_INTEGER + 3,
  Number.MAX_VALUE,
  -Number.MAX_VALUE,
  Number.MIN_VALUE,
  2.2250738585072014e-308,
  2.225073858507201e-308,
  Number.EPSILON,
  1e21,
  999999999999999900000,
  1e21 - 65536,
  123456789012345680000,
  1e-6,
  1e-7,
  0.000001234,
  0.0000001234,
  1.5e-7,
  5e-324,
  Infinity,
  -Infinity,
  NaN,
];
for (let e = -330; e <= 310; e++) {
  values.push(Number(`1e${e}`), Number(`1.5e${e}`), Number(`9.999999999999999e${e}`));
}
for (let i = 0; i < RANDOM_BITS; i++) {
  const x = fromBits(next());
  if (!Number.isNaN(x)) values.push(x);
}
for (let i = 0; i < RANDOM_DECIMALS; i++) {
  // Values people type: a few digits scaled by a power of ten.
  const digits = Number(next() % 10000000n);
  const scale = Number(next() % 16n);
  values.push((Number(next() % 2n) ? -1 : 1) * (digits / 10 ** scale));
}

const seen = new Set();
const cases = [];
for (const x of values) {
  const bits = Number.isNaN(x) ? '7ff8000000000000' : toBits(x);
  if (seen.has(bits)) continue;
  seen.add(bits);
  cases.push(`    ${JSON.stringify({ bits, string: String(x) })}`);
}

const doc = `{
  "meta": {
    "generator": "frontend/scripts/gen-jsnumber-vectors.js",
    "node": ${JSON.stringify(process.version)},
    "semantics": "bits: an IEEE 754 double as 16 hex digits (big-endian); string: JS String(x)."
  },
  "cases": [
${cases.join(',\n')}
  ]
}
`;
writeFileSync(OUT, doc);
console.log(`✔ ${String(cases.length)} cases -> shared/fixtures/jsnumber-vectors.json`);
