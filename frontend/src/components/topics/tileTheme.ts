import type { Appearance } from '../../lib/appearance';

/**
 * The tile's accent chrome in the topic's theme (appearance.md §6.1): the leading bar, the due
 * border and the full-height action block (Log, Start). The `topic-*` utilities read the
 * variables `topicStyle()` sets on the tile. A topic without a colour keeps today's accent
 * classes exactly (§4.3), so its tile looks as it did before themes.
 */
export function tileTheme(appearance: Appearance | null | undefined) {
  const tinted = Boolean(appearance?.color);
  return {
    tinted,
    /** The 4 px bar: a due tile's, and always on a topic with a colour. */
    showsBar: (due: boolean) => due || tinted,
    bar: tinted ? 'bg-topic-tint' : 'bg-accent',
    dueBorder: tinted ? 'border-topic-tint/45' : 'border-accent/45',
    /** The filled block (a due tile's Log or Start). */
    loud: tinted
      ? 'border-topic-tint/30 bg-topic-tint text-topic-on-tint hover:brightness-110'
      : 'border-accent-strong/30 bg-accent text-on-accent hover:bg-accent-strong',
    /** The soft block; text on `tintSoft` is ink (§4.3). */
    soft: tinted
      ? 'border-line bg-topic-tint-soft text-ink hover:brightness-[0.97]'
      : 'border-line bg-accent-soft text-accent-strong hover:brightness-[0.97]',
  };
}

/** A tile's tag chips (§5): the first three, then "+N" for the rest. */
export function tileTags(tags: readonly string[]): { shown: string[]; more: number } {
  return { shown: tags.slice(0, 3), more: Math.max(0, tags.length - 3) };
}
