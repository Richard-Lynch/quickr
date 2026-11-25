/**
 * Topic appearance (docs/specs/appearance.md §4.2): the twelve-colour palette, the CSS variables a
 * themed element sets, and the glyph that stands in for a topic before its name.
 *
 * The utilities `bg-topic-tint`, `bg-topic-tint-soft`, `text-topic-tint`, `text-topic-on-tint` and
 * `border-topic-tint` (index.css `@theme inline`) read `--topic-tint`, `--topic-tint-soft` and
 * `--topic-on-tint`, and fall back to the brand accent, so untinted markup looks exactly as before.
 * `topicStyle` sets the three variables inline; `data-topic-color="<name>"` (topicColors.css) sets
 * them for static markup. `checkIcon`/`checkTags` land with F3-EDIT.
 */
import type { CSSProperties } from 'react';

export const COLOR_NAMES = [
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
] as const;
export type ColorName = (typeof COLOR_NAMES)[number];

export interface Appearance {
  color: ColorName | null;
  icon: { kind: 'emoji'; value: string } | null;
  tags: string[];
}

/** `tint` is the fill, `tintSoft` the wash, `onTint` the text on `tint` (≥ 4.5:1 on it). */
export interface Swatch {
  tint: string;
  tintSoft: string;
  onTint: string;
}

/**
 * appearance.md §3.1, in palette order. topicColors.css carries the same values as `--topic-<name>-*`
 * root variables (light, with dark overrides); appearance.test.ts asserts the two equal. M3-DB pins
 * both to shared/fixtures/appearance-vectors.json.
 */
export const PALETTE: Record<ColorName, { light: Swatch; dark: Swatch }> = {
  red: {
    light: { tint: '#c2362b', tintSoft: '#f8dcd8', onTint: '#ffffff' },
    dark: { tint: '#ff7b6e', tintSoft: '#3b1714', onTint: '#1b0d04' },
  },
  orange: {
    light: { tint: '#c2470a', tintSoft: '#fde4d4', onTint: '#ffffff' },
    dark: { tint: '#ff7a2e', tintSoft: '#3a2214', onTint: '#1b0d04' },
  },
  amber: {
    light: { tint: '#9e5406', tintSoft: '#fbe7c6', onTint: '#ffffff' },
    dark: { tint: '#f0a63a', tintSoft: '#3a2a0e', onTint: '#1b1204' },
  },
  yellow: {
    light: { tint: '#f2c230', tintSoft: '#fbf0c4', onTint: '#1b1915' },
    dark: { tint: '#f5cf4f', tintSoft: '#3a3110', onTint: '#1b1804' },
  },
  lime: {
    light: { tint: '#4f7a0c', tintSoft: '#e6f2cc', onTint: '#ffffff' },
    dark: { tint: '#a9d64c', tintSoft: '#243410', onTint: '#101a04' },
  },
  green: {
    light: { tint: '#2f7d4f', tintSoft: '#dcefe2', onTint: '#ffffff' },
    dark: { tint: '#5cc28a', tintSoft: '#173323', onTint: '#04170c' },
  },
  teal: {
    light: { tint: '#19786f', tintSoft: '#d4eeea', onTint: '#ffffff' },
    dark: { tint: '#4fc4b7', tintSoft: '#113330', onTint: '#04201c' },
  },
  cyan: {
    light: { tint: '#1c7fa3', tintSoft: '#d6ecf5', onTint: '#ffffff' },
    dark: { tint: '#5cc0e8', tintSoft: '#113040', onTint: '#041a26' },
  },
  blue: {
    light: { tint: '#2f5f8f', tintSoft: '#dce7f2', onTint: '#ffffff' },
    dark: { tint: '#7fb1e3', tintSoft: '#16283a', onTint: '#071624' },
  },
  indigo: {
    light: { tint: '#4a3aa7', tintSoft: '#e3dff6', onTint: '#ffffff' },
    dark: { tint: '#9085e9', tintSoft: '#1f1a3d', onTint: '#0d0a24' },
  },
  violet: {
    light: { tint: '#7a3c9e', tintSoft: '#ecdff4', onTint: '#ffffff' },
    dark: { tint: '#c08ae0', tintSoft: '#2d1a3a', onTint: '#1b0a26' },
  },
  pink: {
    light: { tint: '#b8386e', tintSoft: '#f8dde9', onTint: '#ffffff' },
    dark: { tint: '#ec84b1', tintSoft: '#3a1728', onTint: '#260a18' },
  },
};

/**
 * CSS variables for a themed element; `{}` for null or no colour (the brand accent applies).
 *
 * Each variable references the colour's root variable from topicColors.css, which is what makes
 * dark mode work: an inline hex would win over every stylesheet rule in both modes, while
 * `--topic-red-tint` is redefined on `:root` under `prefers-color-scheme: dark`. The light hex rides
 * along as the `var()` fallback, so the element is still tinted where the stylesheet is absent.
 */
export function topicStyle(a: Appearance | null | undefined): CSSProperties {
  const color = a?.color;
  if (!color) return {};
  const light = PALETTE[color].light;
  // Custom properties are not keys of `CSSProperties`, but a record of them is assignable to it.
  const vars: Record<`--${string}`, string> = {
    '--topic-tint': `var(--topic-${color}-tint, ${light.tint})`,
    '--topic-tint-soft': `var(--topic-${color}-soft, ${light.tintSoft})`,
    '--topic-on-tint': `var(--topic-${color}-on, ${light.onTint})`,
  };
  return vars;
}

export type Glyph = { kind: 'emoji'; value: string } | { kind: 'initial'; value: string };

/** The topic's emoji, or its name's first grapheme (`""` for an empty name) for the tint circle. */
export function glyphOf(a: Appearance | null | undefined, name: string): Glyph {
  if (a?.icon) return { kind: 'emoji', value: a.icon.value };
  return { kind: 'initial', value: firstGrapheme(name.trim()) };
}

// Grapheme, not UTF-16 unit or code point: a flag, a ZWJ family or "é" as e + U+0301 stays whole,
// as `String.first` (a `Character`) does on iOS.
const graphemes = new Intl.Segmenter(undefined, { granularity: 'grapheme' });

function firstGrapheme(s: string): string {
  for (const { segment } of graphemes.segment(s)) return segment;
  return '';
}
