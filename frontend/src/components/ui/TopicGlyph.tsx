import type { Appearance } from '../../lib/appearance';
import { glyphOf, topicStyle } from '../../lib/appearance';
import { cn } from './cn';

/**
 * A topic's glyph (appearance.md §4.2): its emoji, or its name's initial on a `tint` circle. An
 * image named after the topic for assistive tech. Themes itself from `appearance`, so it needs no
 * themed ancestor. Renders nothing when the topic has neither an emoji nor a name.
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
      style={{ ...topicStyle(appearance), ...box, fontSize: size * 0.52 }}
    >
      {glyph.value}
    </span>
  );
}
