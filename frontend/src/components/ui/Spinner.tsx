import { cn } from './cn';

export function Spinner({ className }: { className?: string | undefined }) {
  return (
    <svg
      viewBox="0 0 24 24"
      className={cn('size-5 animate-spin', className)}
      aria-hidden="true"
      fill="none"
    >
      <circle cx="12" cy="12" r="9" stroke="currentColor" strokeOpacity="0.2" strokeWidth="3" />
      <path d="M21 12a9 9 0 0 0-9-9" stroke="currentColor" strokeWidth="3" strokeLinecap="round" />
    </svg>
  );
}

export function Skeleton({ className }: { className?: string | undefined }) {
  return <div className={cn('animate-pulse rounded-xl bg-sunken', className)} aria-hidden="true" />;
}

export function PageSpinner({ label = 'Loading' }: { label?: string }) {
  return (
    <div role="status" className="flex items-center justify-center gap-3 py-24 text-muted">
      <Spinner />
      <span className="text-sm">{label}…</span>
    </div>
  );
}
