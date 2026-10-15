import { useId, type ComponentProps, type ReactNode } from 'react';

import { cn } from './cn';

const control =
  'w-full rounded-xl border border-line-strong bg-surface px-3.5 text-ink placeholder:text-muted/70 transition-[border-color,box-shadow] outline-none focus:border-accent focus:ring-3 focus:ring-accent/20 disabled:bg-sunken disabled:text-muted aria-invalid:border-danger aria-invalid:ring-danger/15';

export function Input({ className, ...rest }: ComponentProps<'input'>) {
  return <input className={cn(control, 'h-12', className)} {...rest} />;
}

export function Textarea({ className, ...rest }: ComponentProps<'textarea'>) {
  return <textarea className={cn(control, 'min-h-24 py-3 leading-relaxed', className)} {...rest} />;
}

export function Select({ className, children, ...rest }: ComponentProps<'select'>) {
  return (
    <div className="relative">
      <select className={cn(control, 'h-12 appearance-none pr-10', className)} {...rest}>
        {children}
      </select>
      <svg
        className="pointer-events-none absolute top-1/2 right-3.5 size-4 -translate-y-1/2 text-muted"
        viewBox="0 0 16 16"
        fill="none"
        aria-hidden="true"
      >
        <path d="m4 6 4 4 4-4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
      </svg>
    </div>
  );
}

interface FieldProps {
  label: ReactNode;
  hint?: ReactNode;
  error?: string | undefined;
  /** Renders after the label (e.g. a unit or counter). */
  aside?: ReactNode;
  className?: string | undefined;
  /** Mark the label as optional. */
  optional?: boolean;
  children: (ids: { id: string; describedBy: string | undefined; invalid: boolean }) => ReactNode;
}

/** Label + control + hint/error, with ids wired up for assistive tech. */
export function Field({ label, hint, error, aside, className, optional, children }: FieldProps) {
  const id = useId();
  const hintId = `${id}-hint`;
  const errId = `${id}-err`;
  const describedBy = [hint ? hintId : null, error ? errId : null].filter(Boolean).join(' ');
  return (
    <div className={cn('flex flex-col gap-1.5', className)}>
      <div className="flex items-baseline justify-between gap-2">
        <label htmlFor={id} className="text-sm font-semibold text-ink-soft">
          {label}
          {optional ? <span className="ml-1.5 font-normal text-muted">optional</span> : null}
        </label>
        {aside}
      </div>
      {children({ id, describedBy: describedBy || undefined, invalid: Boolean(error) })}
      {error ? (
        <p id={errId} role="alert" className="text-sm font-medium text-danger">
          {error}
        </p>
      ) : hint ? (
        <p id={hintId} className="text-[0.8rem] text-muted">
          {hint}
        </p>
      ) : null}
    </div>
  );
}

export function Checkbox({
  label,
  hint,
  className,
  ...rest
}: Omit<ComponentProps<'input'>, 'type'> & { label: ReactNode; hint?: ReactNode }) {
  return (
    <label
      className={cn(
        'flex min-h-11 cursor-pointer items-center gap-3 rounded-xl py-1 select-none',
        className,
      )}
    >
      <input
        type="checkbox"
        className="peer size-5 shrink-0 cursor-pointer appearance-none rounded-md border-2 border-line-strong bg-surface transition-colors checked:border-accent checked:bg-accent checked:bg-[url('data:image/svg+xml,%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22%20viewBox=%220%200%2016%2016%22%3E%3Cpath%20d=%22m3.5%208.5%203%203%206-7%22%20fill=%22none%22%20stroke=%22white%22%20stroke-width=%222.2%22%20stroke-linecap=%22round%22%20stroke-linejoin=%22round%22/%3E%3C/svg%3E')] disabled:opacity-50"
        {...rest}
      />
      <span className="flex flex-col">
        <span className="text-[0.95rem] font-medium">{label}</span>
        {hint ? <span className="text-xs text-muted">{hint}</span> : null}
      </span>
    </label>
  );
}
