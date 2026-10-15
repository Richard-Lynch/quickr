import type { ReactNode } from 'react';
import { isRouteErrorResponse, Link, Outlet, useNavigate, useRouteError } from 'react-router';

import { errorMessage } from '../api/errors';
import { ButtonLink, IconButton } from './ui/Button';
import { EmptyState } from './ui/Card';
import { cn } from './ui/cn';
import { Icon } from './ui/Icon';

/** The app icon (same artwork as public/favicon.svg), themed via tokens. */
export function AppMark({ className }: { className?: string | undefined }) {
  return (
    <svg viewBox="0 0 512 512" className={className} aria-hidden="true">
      <rect width="512" height="512" rx="116" className="fill-accent" />
      <g
        fill="none"
        className="stroke-on-accent"
        strokeLinecap="round"
        transform="translate(256 256) scale(0.9) translate(-218 -268)"
      >
        <circle cx="262" cy="242" r="88" strokeWidth="56" />
        <path d="M350 186v196" strokeWidth="56" />
        <path d="M88 202h44M70 242h62M88 282h44" strokeWidth="24" strokeOpacity="0.85" />
      </g>
    </svg>
  );
}

export function Logo({ className }: { className?: string | undefined }) {
  return (
    <Link
      to="/"
      className={cn(
        'group inline-flex items-center gap-2 font-display text-[1.35rem] font-bold tracking-tight',
        className,
      )}
      aria-label="quickR — all topics"
    >
      <AppMark className="size-7 transition-transform group-active:scale-90" />
      <span>
        quick<span className="text-accent">R</span>
      </span>
    </Link>
  );
}

export function AppShell() {
  return (
    <div className="mx-auto flex min-h-dvh w-full max-w-5xl flex-col">
      <Outlet />
    </div>
  );
}

/**
 * Compact sticky top bar. `back` renders a back button (phones navigate
 * mostly by thumb + back), `actions` sit on the right.
 */
export function TopBar({
  title,
  back,
  actions,
  className,
}: {
  title?: ReactNode;
  back?: string | true;
  actions?: ReactNode;
  className?: string | undefined;
}) {
  const navigate = useNavigate();
  return (
    <header
      className={cn(
        'sticky top-0 z-30 flex h-14 items-center gap-1 border-b border-line/70 bg-paper/85 px-2 pt-[env(safe-area-inset-top)] backdrop-blur-md sm:h-16 sm:px-4',
        className,
      )}
    >
      {back ? (
        <IconButton
          label="Back"
          onClick={() => {
            if (back === true) void navigate(-1);
            else void navigate(back);
          }}
        >
          <Icon name="chevronLeft" />
        </IconButton>
      ) : (
        <div className="px-2">
          <Logo />
        </div>
      )}
      <div className="min-w-0 flex-1 truncate font-display text-lg font-semibold tracking-tight">
        {title}
      </div>
      <div className="flex items-center gap-1">{actions}</div>
    </header>
  );
}

export function Page({
  children,
  className,
}: {
  children: ReactNode;
  className?: string | undefined;
}) {
  return (
    <main
      className={cn('flex w-full flex-1 flex-col gap-5 px-4 pt-4 pb-32 sm:px-6 sm:pt-6', className)}
    >
      {children}
    </main>
  );
}

/**
 * Primary action pinned to the bottom of the viewport on phones (thumb zone);
 * inline at the end of the content from `sm` up.
 */
export function StickyActions({
  children,
  className,
}: {
  children: ReactNode;
  className?: string | undefined;
}) {
  return (
    <div
      className={cn(
        'fixed inset-x-0 bottom-0 z-20 border-t border-line bg-paper/90 px-4 pt-3 pb-[max(0.75rem,env(safe-area-inset-bottom))] backdrop-blur-md',
        'sm:static sm:z-auto sm:mt-2 sm:border-0 sm:bg-transparent sm:p-0 sm:backdrop-blur-none',
        className,
      )}
    >
      <div className="mx-auto flex max-w-5xl gap-2 sm:justify-end">{children}</div>
    </div>
  );
}

export function RouteError() {
  const error = useRouteError();
  const notFound = isRouteErrorResponse(error) && error.status === 404;
  return (
    <div className="mx-auto flex min-h-dvh max-w-lg flex-col justify-center gap-6 p-6">
      <Logo />
      <EmptyState
        title={notFound ? 'Page not found' : 'Something broke'}
        icon={<Icon name="alert" className="size-8" />}
        action={
          <ButtonLink to="/" variant="primary">
            Back to topics
          </ButtonLink>
        }
      >
        {notFound ? 'That page does not exist.' : errorMessage(error)}
      </EmptyState>
    </div>
  );
}
