/**
 * T2-M3 seam: replaced by the generated `Appearance`/`AppearanceUpdate`/`TopicSummary.appearance`/
 * `TopicUpdate.appearance`/`TopicCreate.appearance` and the `Limits` appearance fields when M3-DB
 * lands. Everything the PWA needs from the appearance wire shape (docs/specs/appearance.md §1.1,
 * §1.3) goes through this file, so the phase-2 swap touches only it and its tests.
 *
 * The generated request validators (`client/sdk.gen.ts`) only check the body and discard the
 * parsed copy, so an `appearance` key on a body typed here reaches the server unchanged; the
 * response keeps it the same way.
 */
import type { Limits, TopicCreate, TopicSummary, TopicUpdate } from '../client';
import { COLOR_NAMES, type Appearance, type ColorName } from './appearance';

/** §1.1 `Appearance` as the server sends it (always normalised: the three keys are present). */
export type AppearanceWire = Appearance;

/** §1.1 PATCH shape: an omitted field is unchanged; `color: null`/`icon: null`/`tags: []` clear. */
export interface AppearanceUpdate {
  color?: ColorName | null;
  icon?: Appearance['icon'];
  tags?: string[];
}

export type TopicUpdateBody = TopicUpdate & { appearance?: AppearanceUpdate };
export type TopicCreateBody = TopicCreate & { appearance?: AppearanceWire | null };

/** A topic's appearance, or `null` when the server (pre-M3-DB) sent none. */
export function appearanceOf(topic: object): Appearance | null {
  const a = (topic as { appearance?: Partial<AppearanceWire> | null }).appearance;
  if (!a || typeof a !== 'object') return null;
  return { color: a.color ?? null, icon: a.icon ?? null, tags: a.tags ?? [] };
}

/** The `appearance` of a PATCH body (not a `TopicUpdate` key until M3-DB). */
export function appearanceUpdateOf(body: TopicUpdate): AppearanceUpdate | undefined {
  return (body as TopicUpdateBody).appearance;
}

/** A `patchTopics` patch that sets `appearance` (not a `TopicSummary` key until M3-DB). */
export function appearancePatch(a: Appearance): Partial<TopicSummary> {
  return { appearance: a } as Partial<TopicSummary>;
}

export interface AppearanceLimits {
  max_tags: number;
  max_tag_length: number;
  max_icon_length: number;
  color_names: readonly string[];
}

/** §1.3 defaults, used until `GET /limits` carries the fields. */
export const APPEARANCE_LIMIT_DEFAULTS: AppearanceLimits = {
  max_tags: 10,
  max_tag_length: 24,
  max_icon_length: 16,
  color_names: COLOR_NAMES,
};

/** The appearance limits from `GET /limits`, each falling back to the §1.3 default. */
export function appearanceLimitsOf(limits: Limits): AppearanceLimits {
  const l = limits as Limits & Partial<AppearanceLimits>;
  return {
    max_tags: l.max_tags ?? APPEARANCE_LIMIT_DEFAULTS.max_tags,
    max_tag_length: l.max_tag_length ?? APPEARANCE_LIMIT_DEFAULTS.max_tag_length,
    max_icon_length: l.max_icon_length ?? APPEARANCE_LIMIT_DEFAULTS.max_icon_length,
    color_names: l.color_names ?? APPEARANCE_LIMIT_DEFAULTS.color_names,
  };
}
