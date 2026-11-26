import { beforeAll, describe, expect, it } from 'vitest';

import { COLOR_NAMES, PALETTE, glyphOf, topicStyle, type Appearance } from './appearance';
// T2-M3: the palette's source of truth (appearance.md §3.2, §3.3)
import vectorsRaw from '../../../shared/fixtures/appearance-vectors.json?raw';

interface VectorSwatch {
  tint: string;
  tint_soft: string;
  on_tint: string;
}
const vectors = JSON.parse(vectorsRaw) as {
  meta: { colors: string[]; min_contrast: number };
  palette: { name: string; light: VectorSwatch; dark: VectorSwatch }[];
};
const swatchOf = (s: VectorSwatch) => ({ tint: s.tint, tintSoft: s.tint_soft, onTint: s.on_tint });
// end T2-M3

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
  // T2-M3: against shared/fixtures/appearance-vectors.json (generated from the server's table)
  it('has the twelve names of appearance-vectors.json, in palette order', () => {
    expect(COLOR_NAMES).toHaveLength(12);
    expect([...COLOR_NAMES]).toEqual(vectors.meta.colors);
    expect(vectors.palette.map((p) => p.name)).toEqual(vectors.meta.colors);
    expect(Object.keys(PALETTE)).toEqual([...COLOR_NAMES]);
  });

  it('equals the palette of appearance-vectors.json, light and dark', () => {
    for (const p of vectors.palette) {
      const name = p.name as (typeof COLOR_NAMES)[number];
      expect(PALETTE[name], name).toEqual({ light: swatchOf(p.light), dark: swatchOf(p.dark) });
    }
  });

  it('keeps onTint on tint at the vectors’ min_contrast (4.5:1) or better, light and dark', () => {
    expect(vectors.meta.min_contrast).toBe(4.5);
    for (const name of COLOR_NAMES) {
      for (const mode of ['light', 'dark'] as const) {
        const s = PALETTE[name][mode];
        expect(contrast(s.onTint, s.tint), `${name} ${mode}`).toBeGreaterThanOrEqual(
          vectors.meta.min_contrast,
        );
      }
    }
  });
  // end T2-M3
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
