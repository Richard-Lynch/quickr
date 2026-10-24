import type { CompatibilityReport } from '../../client';
import { Badge, type Tone } from '../ui/Card';
import { cn } from '../ui/cn';
import { Icon, type IconName } from '../ui/Icon';

const LEVEL: Record<
  CompatibilityReport['issues'][number]['level'],
  { tone: Tone; icon: IconName; label: string; cls: string }
> = {
  error: {
    tone: 'danger',
    icon: 'alert',
    label: 'Blocks publishing',
    cls: 'border-danger/30 bg-danger-soft text-danger',
  },
  warning: {
    tone: 'warn',
    icon: 'alert',
    label: 'Warning',
    cls: 'border-warn/30 bg-warn-soft text-warn',
  },
  info: { tone: 'info', icon: 'info', label: 'Info', cls: 'border-info/30 bg-info-soft text-info' },
};

const KIND: Record<CompatibilityReport['changes'][number]['kind'], { tone: Tone; label: string }> =
  {
    added: { tone: 'ok', label: 'added' },
    removed: { tone: 'danger', label: 'removed' },
    modified: { tone: 'info', label: 'changed' },
    restored: { tone: 'accent', label: 'restored' },
    reordered: { tone: 'neutral', label: 'reordered' },
  };

/** Human-readable rendering of a dry-run compatibility check. */
export function CompatReport({
  report,
  labelFor,
  emptyText = 'No changes.',
}: {
  report: CompatibilityReport;
  labelFor: (key: string) => string;
  /** Shown when no question changed (e.g. "No question changes." beside a timer change). */
  emptyText?: string;
}) {
  const order = { error: 0, warning: 1, info: 2 } as const;
  const issues = [...report.issues].sort((a, b) => order[a.level] - order[b.level]);
  return (
    <div className="flex flex-col gap-5">
      <div
        className={cn(
          'flex items-center gap-3 rounded-2xl border px-4 py-3',
          report.ok
            ? 'border-ok/30 bg-ok-soft text-ok'
            : 'border-danger/30 bg-danger-soft text-danger',
        )}
      >
        <Icon name={report.ok ? 'check' : 'alert'} strokeWidth={2.6} />
        <p className="font-semibold">
          {report.ok
            ? `Ready to publish as v${report.next_version}`
            : 'Can’t publish yet — fix the errors below'}
        </p>
      </div>

      {issues.length > 0 ? (
        <section className="flex flex-col gap-2">
          <h3 className="text-xs font-semibold tracking-wide text-muted uppercase">Checks</h3>
          <ul className="flex flex-col gap-2">
            {issues.map((i, n) => {
              const meta = LEVEL[i.level];
              return (
                <li
                  key={n}
                  className={cn('flex gap-3 rounded-xl border px-3 py-2.5 text-sm', meta.cls)}
                >
                  <Icon name={meta.icon} className="mt-0.5 size-4" />
                  <div className="min-w-0 text-ink">
                    {i.question_key ? (
                      <p className="font-semibold">{labelFor(i.question_key)}</p>
                    ) : null}
                    <p className="text-ink-soft">{i.message}</p>
                  </div>
                </li>
              );
            })}
          </ul>
        </section>
      ) : null}

      <section className="flex flex-col gap-2">
        <h3 className="text-xs font-semibold tracking-wide text-muted uppercase">Changes</h3>
        {report.changes.length === 0 ? (
          <p className="text-sm text-muted">{emptyText}</p>
        ) : (
          <ul className="flex flex-col divide-y divide-dashed divide-line rounded-xl border border-line">
            {report.changes.map((c, n) => (
              <li key={n} className="flex flex-col gap-1 px-3 py-2.5">
                <div className="flex items-center gap-2">
                  <Badge tone={KIND[c.kind].tone}>{KIND[c.kind].label}</Badge>
                  <span className="min-w-0 truncate font-medium">
                    {c.question_key === '*' ? 'Question order' : labelFor(c.question_key)}
                  </span>
                </div>
                {c.details.length > 0 ? (
                  <ul className="flex flex-col gap-0.5 pl-1">
                    {c.details.map((d) => (
                      <li key={d} className="font-mono text-xs break-words text-muted">
                        {d}
                      </li>
                    ))}
                  </ul>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
