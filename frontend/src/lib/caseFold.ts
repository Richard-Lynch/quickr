/**
 * Python's `str.casefold()`, as the server compares labels (question and option labels,
 * variable names): full case folding, one code point at a time, no normalisation. So
 * "Straße" and "STRASSE" clash, which `toLocaleLowerCase` misses, but "é" and "é"
 * don't. From the server's own table (`caseFoldTable.ts`, the `casefold` list of
 * shared/fixtures/builder-vectors.json), as iOS does (`BuilderText.casefold`).
 */
import { CASE_FOLD_TABLE } from './caseFoldTable';

let folds: Map<number, string> | null = null;

function table(): Map<number, string> {
  if (folds) return folds;
  folds = new Map();
  for (const entry of CASE_FOLD_TABLE.join(',').split(',')) {
    const [from, to] = entry.split(':');
    if (from === undefined || to === undefined) continue;
    const mapped = to.split(' ').map((h) => Number.parseInt(h, 16));
    folds.set(Number.parseInt(from, 16), String.fromCodePoint(...mapped));
  }
  return folds;
}

export function casefold(s: string): string {
  const t = table();
  let out = '';
  for (const ch of s) {
    const c = ch.codePointAt(0) ?? 0;
    out += t.get(c) ?? ch;
  }
  return out;
}
