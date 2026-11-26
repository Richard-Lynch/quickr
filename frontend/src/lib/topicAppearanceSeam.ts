/**
 * The appearance wire shape (docs/specs/appearance.md §1.1, §1.3) as the PWA uses it, on top of
 * the generated client types. Kept as one small module so the forms, the cache patch and the topic
 * header (F3-RENDER) read the appearance the same way.
 */
import type {
  AppearanceUpdate,
  Limits,
  TopicAppearanceOutput,
  TopicCreate,
  TopicSummary,
  TopicUpdate,
} from '../client';
import type { Appearance } from './appearance';

/** §1.1 `Appearance` as the server sends it (always normalised: the three keys are present). */
export type AppearanceWire = TopicAppearanceOutput;

/** §1.1 PATCH shape: an omitted field is unchanged; `color: null`/`icon: null`/`tags: []` clear. */
export type { AppearanceUpdate };

export type TopicUpdateBody = TopicUpdate;
export type TopicCreateBody = TopicCreate;

/** A topic's appearance; `null` only for an object that carries none. */
export function appearanceOf(topic: Partial<Pick<TopicSummary, 'appearance'>>): Appearance | null {
  return topic.appearance ?? null;
}

/** The `appearance` of a PATCH body. */
export function appearanceUpdateOf(body: TopicUpdate): AppearanceUpdate | undefined {
  return body.appearance;
}

/** A `patchTopics` patch that sets `appearance`. */
export function appearancePatch(a: Appearance): Partial<TopicSummary> {
  return { appearance: a };
}

export type AppearanceLimits = Pick<
  Limits,
  'max_tags' | 'max_tag_length' | 'max_icon_length' | 'color_names'
>;

/** The appearance limits from `GET /limits` (or `FALLBACK_LIMITS` until it has loaded). */
export function appearanceLimitsOf(limits: Limits): AppearanceLimits {
  return limits;
}
