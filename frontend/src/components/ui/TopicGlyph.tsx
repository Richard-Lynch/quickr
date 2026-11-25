import type { Appearance } from '../../lib/appearance';
import { glyphOf, topicStyle } from '../../lib/appearance';
import { cn } from './cn';

// A colourless topic's circle is the brand accent even inside another topic's themed subtree,
// where `topicStyle()`'s `{}` would inherit that topic's variables.
const ACCENT: Record<`--${string}`, string> = {
  '--topic-tint': 'var(--color-accent)',
  '--topic-tint-soft': 'var(--color-accent-soft)',
  '--topic-on-tint': 'var(--color-on-accent)',
};

/**
 * A topic's glyph (appearance.md §4.2): its emoji, or its name's initial on a `tint` circle. An
 * image named after the topic for assistive tech. Themes itself from `appearance`, so it needs no
 * themed ancestor and ignores one. Renders nothing when the topic has neither an emoji nor a name.
 */
export function TopicGlyph({
  appearance,
  name,
  size = 22,
  className,
}: {
  appearance: Appearance | null | undefined;
  name: string;
  size?: number;
  className?: string | undefined;
}) {
  const glyph = glyphOf(appearance, name);
  if (!glyph.value) return null;
  const box = { width: size, height: size };
  if (glyph.kind === 'emoji') {
    return (
      <span
        role="img"
        aria-label={name}
        className={cn('inline-flex shrink-0 items-center justify-center leading-none', className)}
        style={{ ...box, fontSize: size * 0.85 }}
      >
        {glyph.value}
      </span>
    );
  }
  return (
    <span
      role="img"
      aria-label={name}
      className={cn(
        'inline-flex shrink-0 items-center justify-center rounded-full bg-topic-tint font-display leading-none font-bold text-topic-on-tint',
        className,
      )}
      style={{
        ...(appearance?.color ? topicStyle(appearance) : ACCENT),
        ...box,
        fontSize: size * 0.52,
      }}
    >
      {glyph.value}
    </span>
  );
}
