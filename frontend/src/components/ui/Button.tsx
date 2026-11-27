import type { ComponentProps, ReactNode } from 'react';
import { Link, type LinkProps } from 'react-router';

import { cn } from './cn';
import { Spinner } from './Spinner';

/**
 * `topic` is `primary` in the topic's theme (appearance.md §6.4): the `topic-*` utilities read
 * `topicStyle()`'s variables on an ancestor. Use it only for a topic with a colour, so a topic
 * without one keeps the accent primary exactly (§4.3).
 */
export type ButtonVariant = 'primary' | 'topic' | 'secondary' | 'ghost' | 'danger' | 'quiet-danger';
/** `hero` (72 px) is the run panel's primary (active-surfaces.md §6.1, §8.1). */
export type ButtonSize = 'sm' | 'md' | 'lg' | 'hero';

const base =
  'inline-flex select-none items-center justify-center gap-2 rounded-full font-semibold transition-[background-color,color,box-shadow,transform] duration-150 active:scale-[0.97] motion-reduce:active:scale-none disabled:pointer-events-none disabled:opacity-50';

const variants: Record<ButtonVariant, string> = {
  primary:
    'bg-accent text-on-accent shadow-[0_1px_0_rgb(0_0_0/0.15),inset_0_1px_0_rgb(255_255_255/0.2)] hover:bg-accent-strong',
  topic:
    'bg-topic-tint text-topic-on-tint shadow-[0_1px_0_rgb(0_0_0/0.15),inset_0_1px_0_rgb(255_255_255/0.2)] hover:brightness-110',
  secondary: 'border border-line-strong bg-surface text-ink hover:border-ink/40 hover:bg-sunken',
  ghost: 'text-ink-soft hover:bg-sunken hover:text-ink',
  danger: 'bg-danger text-white hover:brightness-110',
  'quiet-danger': 'text-danger hover:bg-danger-soft',
};

const sizes: Record<ButtonSize, string> = {
  sm: 'h-9 whitespace-nowrap px-3.5 text-sm',
  md: 'h-11 whitespace-nowrap px-5 text-[0.95rem]',
  lg: 'h-14 whitespace-nowrap px-7 text-base',
  // Grows with a two-line label ("Next: {long step}") rather than overflowing (§2.3).
  hero: 'min-h-[4.5rem] px-8 py-3 text-center text-xl leading-tight [&>svg]:size-7',
};

export function buttonClass(
  variant: ButtonVariant = 'secondary',
  size: ButtonSize = 'md',
  extra?: string,
): string {
  return cn(base, variants[variant], sizes[size], extra);
}

type ButtonProps = ComponentProps<'button'> & {
  variant?: ButtonVariant;
  size?: ButtonSize;
  loading?: boolean;
  icon?: ReactNode;
};

export function Button({
  variant = 'secondary',
  size = 'md',
  loading = false,
  icon,
  className,
  children,
  disabled,
  type = 'button',
  ...rest
}: ButtonProps) {
  return (
    <button
      type={type}
      className={buttonClass(variant, size, className)}
      disabled={disabled === true || loading}
      aria-busy={loading || undefined}
      {...rest}
    >
      {loading ? <Spinner className="size-4" /> : icon}
      {children}
    </button>
  );
}

type ButtonLinkProps = LinkProps & {
  variant?: ButtonVariant;
  size?: ButtonSize;
  icon?: ReactNode;
};

export function ButtonLink({
  variant = 'secondary',
  size = 'md',
  icon,
  className,
  children,
  ...rest
}: ButtonLinkProps) {
  return (
    <Link
      className={buttonClass(variant, size, typeof className === 'string' ? className : undefined)}
      {...rest}
    >
      {icon}
      {children}
    </Link>
  );
}

type IconButtonProps = ComponentProps<'button'> & { label: string; size?: 'sm' | 'md' };

export function IconButton({
  label,
  size = 'md',
  className,
  children,
  type = 'button',
  ...rest
}: IconButtonProps) {
  return (
    <button
      type={type}
      aria-label={label}
      title={label}
      className={cn(
        'inline-flex shrink-0 items-center justify-center rounded-full text-ink-soft transition-colors hover:bg-sunken hover:text-ink active:scale-95 disabled:pointer-events-none disabled:opacity-35',
        size === 'md' ? 'size-11' : 'size-9',
        className,
      )}
      {...rest}
    >
      {children}
    </button>
  );
}
