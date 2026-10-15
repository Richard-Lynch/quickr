import { cn } from './cn';

export function Switch({
  checked,
  onChange,
  label,
  disabled,
  busy,
}: {
  checked: boolean;
  onChange: (next: boolean) => void;
  label: string;
  disabled?: boolean;
  busy?: boolean;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      aria-busy={busy === true ? true : undefined}
      disabled={disabled === true || busy === true}
      onClick={() => onChange(!checked)}
      className={cn(
        'relative inline-flex h-8 w-13 shrink-0 items-center rounded-full border-2 border-transparent transition-colors disabled:opacity-50',
        checked ? 'bg-accent' : 'bg-line-strong',
      )}
    >
      <span
        className={cn(
          'inline-block size-6 rounded-full bg-white shadow-card transition-transform',
          checked ? 'translate-x-5' : 'translate-x-0',
          busy && 'animate-pulse',
        )}
      />
    </button>
  );
}
