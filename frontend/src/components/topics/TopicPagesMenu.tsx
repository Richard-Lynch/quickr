/**
 * The "…" button that reaches a topic's own pages from a surface that shows its run instead
 * (active-surfaces.md §3.2, §6.2): the active card and the run panel. Its sheet links to the
 * topic's stats (the overview), entries, the question builder and settings, so an open run
 * never hides them.
 */
import { useState } from 'react';
import { Link } from 'react-router';

import { cn } from '../ui/cn';
import { Icon, type IconName } from '../ui/Icon';
import { Sheet } from '../ui/Sheet';

/** The pages, in the sheet's order: (path under `/t/{slug}`, title, icon, test id suffix). */
const PAGES: readonly { path: string; title: string; icon: IconName; id: string }[] = [
  { path: '', title: 'Stats', icon: 'chart', id: 'stats' },
  { path: '/entries', title: 'Entries', icon: 'list', id: 'entries' },
  { path: '/edit', title: 'Edit questions', icon: 'edit', id: 'edit' },
  { path: '/settings', title: 'Topic settings', icon: 'settings', id: 'settings' },
];

export function TopicPagesMenu({
  topic,
  testId,
  bare = false,
}: {
  topic: { slug: string; name: string };
  /** The trigger's test id; each link is `{testId}-{stats|entries|edit|settings}`. */
  testId: string;
  /** Without the outline, as the top bar's other icon buttons. */
  bare?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const base = `/t/${topic.slug}`;
  return (
    <>
      <button
        type="button"
        aria-label={`${topic.name}: topic pages`}
        aria-haspopup="dialog"
        title="Topic pages"
        data-testid={testId}
        onClick={() => setOpen(true)}
        className={cn(
          'inline-flex size-11 shrink-0 items-center justify-center rounded-full text-ink-soft transition-colors hover:bg-sunken hover:text-ink active:scale-95 motion-reduce:active:scale-none',
          !bare && 'border border-line-strong bg-surface',
        )}
      >
        <Icon name="dots" className="size-5" />
      </button>
      <Sheet open={open} onClose={() => setOpen(false)} title={topic.name}>
        <ul className="flex flex-col gap-2 pb-2" aria-label="Topic pages">
          {PAGES.map((p) => (
            <li key={p.id}>
              <Link
                to={`${base}${p.path}`}
                data-testid={`${testId}-${p.id}`}
                onClick={() => setOpen(false)}
                className="flex min-h-14 w-full items-center gap-3 rounded-[1.75rem] border border-line-strong bg-surface px-5 py-3 text-base font-semibold text-ink transition-colors hover:bg-sunken"
              >
                <Icon name={p.icon} className="size-4.5 shrink-0" />
                {p.title}
              </Link>
            </li>
          ))}
        </ul>
      </Sheet>
    </>
  );
}
