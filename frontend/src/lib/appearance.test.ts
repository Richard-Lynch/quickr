import { beforeAll, describe, expect, it } from 'vitest';

import {
  COLOR_NAMES,
  PALETTE,
  checkIcon,
  checkTags,
  glyphOf,
  topicStyle,
  type Appearance,
} from './appearance';

const red: Appearance = { color: 'red', icon: null, tags: [] };
const smoking: Appearance = { color: null, icon: { kind: 'emoji', value: '🚬' }, tags: ['habit'] };

// No @types/node in the app's tsconfig: reach Node through narrow local types. (A `?raw` import
// of a .css file is the empty string under vitest, which stubs CSS modules.)
interface NodeFs {
  readFileSync(p: string, enc: 'utf8'): string;
}
// A plain path: node:fs rejects jsdom's `URL`, and Vite rewrites
// `new URL('…', import.meta.url)` to a dev-server `/@fs/` path.
const SRC = `${decodeURIComponent(new URL(import.meta.url).pathname).replace(/\/[^/]*$/, '')}/..`;

async function readSource(name: string): Promise<string> {
  const fsName = 'node:fs';
  const fs = (await import(/* @vite-ignore */ fsName)) as NodeFs;
  return fs.readFileSync(`${SRC}/${name}`, 'utf8');
}

/** `--name: #hex;` pairs in a CSS block. */
function vars(css: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const m of css.matchAll(/--([a-z0-9-]+):\s*(#[0-9a-f]{6});/g)) {
    out[m[1] ?? ''] = m[2] ?? '';
  }
  return out;
}

describe('PALETTE', () => {
  it('has the twelve names of appearance.md §3.1, in palette order', () => {
    expect(COLOR_NAMES).toEqual([
      'red',
      'orange',
      'amber',
      'yellow',
      'lime',
      'green',
      'teal',
      'cyan',
      'blue',
      'indigo',
      'violet',
      'pink',
    ]);
    expect(Object.keys(PALETTE)).toEqual([...COLOR_NAMES]);
  });

  it('keeps onTint on tint at 4.5:1 or better, light and dark', () => {
    for (const name of COLOR_NAMES) {
      for (const mode of ['light', 'dark'] as const) {
        const s = PALETTE[name][mode];
        expect(contrast(s.onTint, s.tint), `${name} ${mode}`).toBeGreaterThanOrEqual(4.5);
      }
    }
  });
});

describe('topicStyle', () => {
  it('is empty for null, undefined and a colourless appearance', () => {
    expect(topicStyle(null)).toEqual({});
    expect(topicStyle(undefined)).toEqual({});
    expect(topicStyle(smoking)).toEqual({});
  });

  it('sets the three variables from the colour, with the light hex as the fallback', () => {
    // Dark is CSS-driven: each value points at the root variable topicColors.css redefines under
    // prefers-color-scheme: dark, so an inline style never pins a themed element to light.
    expect(topicStyle(red)).toEqual({
      '--topic-tint': 'var(--topic-red-tint, #c2362b)',
      '--topic-tint-soft': 'var(--topic-red-soft, #f8dcd8)',
      '--topic-on-tint': 'var(--topic-red-on, #ffffff)',
    });
    for (const name of COLOR_NAMES) {
      const style = topicStyle({ color: name, icon: null, tags: [] }) as Record<string, string>;
      expect(Object.keys(style)).toEqual(['--topic-tint', '--topic-tint-soft', '--topic-on-tint']);
      expect(style['--topic-tint']).toContain(PALETTE[name].light.tint);
      expect(style['--topic-tint-soft']).toContain(PALETTE[name].light.tintSoft);
      expect(style['--topic-on-tint']).toContain(PALETTE[name].light.onTint);
    }
  });
});

describe('glyphOf', () => {
  it('prefers the emoji', () => {
    expect(glyphOf(smoking, 'Smoking')).toEqual({ kind: 'emoji', value: '🚬' });
    expect(glyphOf({ ...red, icon: { kind: 'emoji', value: '💧' } }, 'Water')).toEqual({
      kind: 'emoji',
      value: '💧',
    });
  });

  it('falls back to the first grapheme of the name, not the first UTF-16 unit', () => {
    expect(glyphOf(red, 'Water')).toEqual({ kind: 'initial', value: 'W' });
    expect(glyphOf(null, 'Water')).toEqual({ kind: 'initial', value: 'W' });
    expect(glyphOf(undefined, '  padded')).toEqual({ kind: 'initial', value: 'p' });
    expect(glyphOf(null, '👨‍👩‍👧 Family')).toEqual({ kind: 'initial', value: '👨‍👩‍👧' });
    expect(glyphOf(null, '🇮🇪 Trip')).toEqual({ kind: 'initial', value: '🇮🇪' });
    expect(glyphOf(null, 'étude')).toEqual({ kind: 'initial', value: 'é' });
    expect(glyphOf(null, '')).toEqual({ kind: 'initial', value: '' });
  });
});

describe('topicColors.css', () => {
  let topicColorsCss = '';
  let indexCss = '';
  beforeAll(async () => {
    topicColorsCss = await readSource('topicColors.css');
    indexCss = await readSource('index.css');
  });

  it('carries PALETTE as --topic-<name>-tint|soft|on, light and dark', () => {
    const darkAt = topicColorsCss.indexOf('@media (prefers-color-scheme: dark)');
    expect(darkAt).toBeGreaterThan(0);
    const light = vars(topicColorsCss.slice(0, darkAt));
    const dark = vars(topicColorsCss.slice(darkAt));
    expect(Object.keys(light)).toHaveLength(36);
    expect(Object.keys(dark)).toEqual(Object.keys(light));
    for (const name of COLOR_NAMES) {
      expect(light[`topic-${name}-tint`], `${name} light tint`).toBe(PALETTE[name].light.tint);
      expect(light[`topic-${name}-soft`], `${name} light soft`).toBe(PALETTE[name].light.tintSoft);
      expect(light[`topic-${name}-on`], `${name} light on`).toBe(PALETTE[name].light.onTint);
      expect(dark[`topic-${name}-tint`], `${name} dark tint`).toBe(PALETTE[name].dark.tint);
      expect(dark[`topic-${name}-soft`], `${name} dark soft`).toBe(PALETTE[name].dark.tintSoft);
      expect(dark[`topic-${name}-on`], `${name} dark on`).toBe(PALETTE[name].dark.onTint);
    }
  });

  it('has one [data-topic-color] block per name, pointing at that name', () => {
    const blocks = [...topicColorsCss.matchAll(/\[data-topic-color='([a-z]+)'\]\s*\{([^}]*)\}/g)];
    expect(blocks.map((m) => m[1])).toEqual([...COLOR_NAMES]);
    for (const [, name, body] of blocks) {
      expect(body).toContain(`--topic-tint: var(--topic-${name}-tint);`);
      expect(body).toContain(`--topic-tint-soft: var(--topic-${name}-soft);`);
      expect(body).toContain(`--topic-on-tint: var(--topic-${name}-on);`);
    }
  });

  it('is what the topic-* utilities read, defaulting to the accent', () => {
    expect(indexCss).toContain("@import './topicColors.css';");
    expect(indexCss).toContain('--color-topic-tint: var(--topic-tint, var(--color-accent));');
    expect(indexCss).toContain(
      '--color-topic-tint-soft: var(--topic-tint-soft, var(--color-accent-soft));',
    );
    expect(indexCss).toContain(
      '--color-topic-on-tint: var(--topic-on-tint, var(--color-on-accent));',
    );
    // No `--color-*: #hex` topic token: the iOS TokenDriftTests parses those as brand tokens.
    expect(indexCss).not.toMatch(/--color-topic[a-z-]*:\s*#/);
  });
});

/** WCAG 2 contrast ratio of two `#rrggbb` colours. */
function contrast(a: string, b: string): number {
  const la = luminance(a);
  const lb = luminance(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

function luminance(hex: string): number {
  const [r, g, b] = [1, 3, 5].map((i) => {
    const v = parseInt(hex.slice(i, i + 2), 16) / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * (r ?? 0) + 0.7152 * (g ?? 0) + 0.0722 * (b ?? 0);
}

// T2-M3 (F3-EDIT): checkIcon / checkTags.
// T2-M3: repoint at appearance-vectors.json `icons[]`/`tags[]` (cases copied from spec §2, §3.2).
const VS = '\u{FE0F}';
const ICONS: { name: string; value: string; stored: string | null }[] = [
  { name: 'plain', value: '🚬', stored: '🚬' },
  { name: 'vs16_added', value: '\u{263A}', stored: `\u{263A}${VS}` },
  { name: 'vs16_present', value: `\u{263A}${VS}`, stored: `\u{263A}${VS}` },
  { name: 'copyright_vs16', value: `\u{A9}${VS}`, stored: `\u{A9}${VS}` },
  { name: 'zwj_family', value: '👨\u{200D}👩\u{200D}👧', stored: '👨\u{200D}👩\u{200D}👧' },
  { name: 'skin_tone', value: '👍\u{1F3FD}', stored: '👍\u{1F3FD}' },
  { name: 'flag', value: '\u{1F1EC}\u{1F1E7}', stored: '\u{1F1EC}\u{1F1E7}' },
  { name: 'keycap', value: `1${VS}\u{20E3}`, stored: `1${VS}\u{20E3}` },
  { name: 'letter', value: 'a', stored: null },
  { name: 'digit', value: '5', stored: null },
  { name: 'digit_vs16', value: `5${VS}`, stored: null },
  { name: 'hash_vs16_no_keycap', value: `#${VS}`, stored: null },
  { name: 'two_emoji', value: '🚬🚬', stored: null },
  { name: 'emoji_plus_letter', value: '🚬a', stored: null },
  { name: 'empty', value: '', stored: null },
  // A black flag and 16 tag characters: one grapheme cluster, 17 code points.
  { name: 'too_long', value: '\u{1F3F4}' + '\u{E0067}'.repeat(16), stored: null },
  { name: 'text_symbol_no_vs16_unfixable', value: '\u{2192}', stored: null },
];

describe('checkIcon', () => {
  it.each(ICONS)('$name', ({ value, stored }) => {
    const r = checkIcon(value);
    if (stored === null) expect(r.ok).toBe(false);
    else expect(r).toEqual({ ok: true, value: stored });
  });

  it('normalises to NFC before counting', () => {
    expect(checkIcon('\u{263A}'.normalize('NFD'))).toEqual({ ok: true, value: `\u{263A}${VS}` });
  });

  it('takes the length limit from the caller', () => {
    expect(checkIcon('👨\u{200D}👩\u{200D}👧', 4).ok).toBe(false);
    expect(checkIcon('👨\u{200D}👩\u{200D}👧', 5).ok).toBe(true);
  });
});

describe('checkTags', () => {
  const ok = (value: string[]) => ({ ok: true, value });
  it('trims, collapses inner whitespace and keeps order', () => {
    expect(checkTags(['  gym ', 'early\t  morning', 'Alpha'])).toEqual(
      ok(['gym', 'early morning', 'Alpha']),
    );
  });

  it('refuses a casefold duplicate at its index, not dropping it', () => {
    expect(checkTags(['Gym', 'run', 'gym'])).toMatchObject({ ok: false, index: 2 });
    expect(checkTags(['Straße', 'STRASSE'])).toMatchObject({ ok: false, index: 1 });
    // Python: 'ı'.casefold() == 'ı' != 'i'.
    expect(checkTags(['ı', 'i'])).toEqual({ ok: true, value: ['ı', 'i'] });
  });

  it('refuses an eleventh tag on the list, not a tag', () => {
    const ten = Array.from({ length: 10 }, (_, i) => `t${String(i)}`);
    expect(checkTags(ten).ok).toBe(true);
    expect(checkTags([...ten, 'eleven'])).toMatchObject({ ok: false, index: -1 });
  });

  it('counts code points: 24 is fine, 25 is not', () => {
    expect(checkTags(['🏃'.repeat(24)]).ok).toBe(true);
    expect(checkTags(['ok', 'x'.repeat(25)])).toMatchObject({ ok: false, index: 1 });
  });

  it('refuses a tag that is empty after trimming, and a control character', () => {
    expect(checkTags(['a', '   '])).toMatchObject({ ok: false, index: 1 });
    expect(checkTags(['bell\u{7}'])).toMatchObject({ ok: false, index: 0 });
  });

  it('takes the limits from the caller', () => {
    expect(checkTags(['a', 'b'], { maxTags: 1 })).toMatchObject({ ok: false, index: -1 });
    expect(checkTags(['abc'], { maxLength: 2 })).toMatchObject({ ok: false, index: 0 });
  });
});
// end T2-M3
