import { useEffect, useRef, useState, type ReactNode } from 'react';

import { Button, IconButton } from './Button';
import { cn } from './cn';
import { Input } from './Field';
import { Icon } from './Icon';

interface SheetProps {
  open: boolean;
  onClose: () => void;
  title: ReactNode;
  description?: ReactNode;
  children?: ReactNode;
  footer?: ReactNode;
  /** Wider dialog on desktop (e.g. compatibility review). */
  wide?: boolean;
}

/**
 * Bottom sheet on phones, centred dialog from `sm` up. Built on the native
 * <dialog> element for focus trapping, Escape and inert background for free.
 */
export function Sheet({ open, onClose, title, description, children, footer, wide }: SheetProps) {
  const ref = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    if (open && !el.open) {
      // jsdom lacks showModal; fall back to the open attribute.
      if (typeof el.showModal === 'function') el.showModal();
      else el.setAttribute('open', '');
    } else if (!open && el.open) {
      if (typeof el.close === 'function') el.close();
      else el.removeAttribute('open');
    }
  }, [open]);

  return (
    <dialog
      ref={ref}
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
      className={cn(
        'm-0 mt-auto max-h-[92dvh] w-full max-w-none overflow-hidden rounded-t-[1.75rem] border border-line bg-surface p-0 text-ink shadow-float backdrop:bg-ink/40 backdrop:backdrop-blur-[2px] open:animate-sheet',
        'sm:m-auto sm:rounded-[1.5rem] sm:open:animate-rise',
        wide ? 'sm:max-w-2xl' : 'sm:max-w-md',
      )}
    >
      {open ? (
        <div className="flex max-h-[92dvh] flex-col">
          <div className="mx-auto mt-2.5 h-1.5 w-10 shrink-0 rounded-full bg-line-strong sm:hidden" />
          <header className="flex items-start gap-3 px-5 pt-4 pb-2 sm:px-6 sm:pt-5">
            <div className="min-w-0 flex-1">
              <h2 className="font-display text-xl font-semibold tracking-tight">{title}</h2>
              {description ? <p className="mt-1 text-sm text-muted">{description}</p> : null}
            </div>
            <IconButton label="Close" size="sm" onClick={onClose} className="-mt-1 -mr-2">
              <Icon name="x" />
            </IconButton>
          </header>
          {children ? (
            <div className="min-h-0 flex-1 overflow-y-auto px-5 pb-4 sm:px-6">{children}</div>
          ) : null}
          {footer ? (
            <footer className="flex shrink-0 flex-col-reverse gap-2 border-t border-line bg-surface px-5 pt-3 pb-[max(1rem,env(safe-area-inset-bottom))] sm:flex-row sm:justify-end sm:px-6">
              {footer}
            </footer>
          ) : null}
        </div>
      ) : null}
    </dialog>
  );
}

interface ConfirmProps {
  open: boolean;
  onClose: () => void;
  onConfirm: () => void;
  title: string;
  body: ReactNode;
  confirmLabel: string;
  danger?: boolean;
  busy?: boolean;
  /** Require typing this text before confirming. */
  typeToConfirm?: string;
}

export function ConfirmSheet({
  open,
  onClose,
  onConfirm,
  title,
  body,
  confirmLabel,
  danger,
  busy,
  typeToConfirm,
}: ConfirmProps) {
  const [typed, setTyped] = useState('');
  const ready = typeToConfirm === undefined || typed.trim() === typeToConfirm;
  const close = () => {
    setTyped('');
    onClose();
  };
  return (
    <Sheet
      open={open}
      onClose={close}
      title={title}
      footer={
        <>
          <Button onClick={close} size="lg" className="sm:h-11 sm:px-5 sm:text-[0.95rem]">
            Cancel
          </Button>
          <Button
            variant={danger ? 'danger' : 'primary'}
            size="lg"
            className="sm:h-11 sm:px-5 sm:text-[0.95rem]"
            disabled={!ready}
            loading={busy ?? false}
            onClick={onConfirm}
          >
            {confirmLabel}
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-4 text-[0.95rem] text-ink-soft">
        {body}
        {typeToConfirm !== undefined ? (
          <label className="flex flex-col gap-1.5">
            <span className="text-sm">
              Type <strong className="font-mono text-ink">{typeToConfirm}</strong> to confirm
            </span>
            <Input
              value={typed}
              onChange={(e) => setTyped(e.target.value)}
              autoComplete="off"
              autoCapitalize="none"
              spellCheck={false}
            />
          </label>
        ) : null}
      </div>
    </Sheet>
  );
}
