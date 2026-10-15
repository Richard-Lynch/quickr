import { useId } from 'react';

import { cn } from './cn';

interface SegmentedProps<T extends string> {
  value: T;
  onChange: (value: T) => void;
  options: readonly { value: T; label: string }[];
  label: string;
  size?: 'sm' | 'md';
  className?: string | undefined;
}

/** Compact single-choice control (filters, bucket pickers). */
export function Segmented<T extends string>({
  value,
  onChange,
  options,
  label,
  size = 'sm',
  className,
}: SegmentedProps<T>) {
  const name = useId();
  return (
    <div
      role="radiogroup"
      aria-label={label}
      className={cn(
        'scrollbar-none inline-flex max-w-full overflow-x-auto rounded-full border border-line bg-sunken p-1',
        className,
      )}
    >
      {options.map((o) => {
        const active = o.value === value;
        return (
          <label
            key={o.value}
            className={cn(
              'relative inline-flex shrink-0 cursor-pointer items-center justify-center rounded-full font-semibold whitespace-nowrap transition-colors select-none',
              size === 'sm' ? 'h-8 px-3 text-[0.8rem]' : 'h-10 px-4 text-sm',
              active ? 'bg-surface text-ink shadow-card' : 'text-muted hover:text-ink',
            )}
          >
            <input
              type="radio"
              name={name}
              value={o.value}
              checked={active}
              onChange={() => onChange(o.value)}
              className="sr-only"
            />
            {o.label}
          </label>
        );
      })}
    </div>
  );
}
