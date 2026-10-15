import type { ComponentProps, ReactNode } from 'react';

import { cn } from './cn';

export function Card({ className, ...rest }: ComponentProps<'div'>) {
  return (
    <div
      className={cn('rounded-card border border-line bg-surface shadow-card', className)}
      {...rest}
    />
  );
}

export function SectionTitle({
  children,
  aside,
  className,
}: {
  children: ReactNode;
  aside?: ReactNode;
  className?: string | undefined;
}) {
  return (
    <div className={cn('flex items-end justify-between gap-3', className)}>
      <h2 className="font-display text-lg font-semibold tracking-tight">{children}</h2>
      {aside}
    </div>
  );
}

export type Tone = 'neutral' | 'accent' | 'ok' | 'warn' | 'danger' | 'info';

const tones: Record<Tone, string> = {
  neutral: 'bg-sunken text-ink-soft',
  accent: 'bg-accent-soft text-accent-strong',
  ok: 'bg-ok-soft text-ok',
  warn: 'bg-warn-soft text-warn',
  danger: 'bg-danger-soft text-danger',
  info: 'bg-info-soft text-info',
};

export function Badge({
  tone = 'neutral',
  className,
  children,
}: {
  tone?: Tone;
  className?: string | undefined;
  children: ReactNode;
}) {
  return (
    <span
      className={cn(
        'inline-flex h-6 items-center gap-1 rounded-full px-2.5 text-xs font-semibold whitespace-nowrap',
        tones[tone],
        className,
      )}
    >
      {children}
    </span>
  );
}

/** The "v3" version stamp used throughout. */
export function VersionTag({
  version,
  className,
}: {
  version: number;
  className?: string | undefined;
}) {
  return (
    <span
      className={cn(
        'inline-flex h-6 items-center rounded-md border border-line-strong px-1.5 font-mono text-xs font-semibold text-ink-soft',
        className,
      )}
      title={`Version ${version}`}
    >
      v{version}
    </span>
  );
}

export function Banner({
  tone = 'danger',
  title,
  children,
  action,
  className,
}: {
  tone?: Exclude<Tone, 'neutral'>;
  title?: ReactNode;
  children?: ReactNode;
  action?: ReactNode;
  className?: string | undefined;
}) {
  return (
    <div
      role={tone === 'danger' ? 'alert' : 'status'}
      className={cn(
        'flex flex-col gap-2 rounded-2xl border px-4 py-3 text-sm sm:flex-row sm:items-center',
        tones[tone],
        'border-current/15',
        className,
      )}
    >
      <div className="min-w-0 flex-1">
        {title ? <p className="font-semibold">{title}</p> : null}
        {children ? <div className="text-ink-soft">{children}</div> : null}
      </div>
      {action}
    </div>
  );
}

export function EmptyState({
  title,
  children,
  action,
  icon,
}: {
  title: string;
  children?: ReactNode;
  action?: ReactNode;
  icon?: ReactNode;
}) {
  return (
    <div className="flex flex-col items-center gap-3 rounded-card border border-dashed border-line-strong px-6 py-12 text-center">
      {icon ? <div className="text-accent">{icon}</div> : null}
      <h3 className="font-display text-xl font-semibold">{title}</h3>
      {children ? <div className="max-w-sm text-sm text-muted">{children}</div> : null}
      {action ? <div className="mt-2">{action}</div> : null}
    </div>
  );
}
