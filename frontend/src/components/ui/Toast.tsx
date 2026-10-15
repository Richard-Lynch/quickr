import { createContext, use, useCallback, useMemo, useRef, useState, type ReactNode } from 'react';

import { cn } from './cn';
import { Icon } from './Icon';

export interface ToastInput {
  title: string;
  description?: string;
  tone?: 'ok' | 'danger' | 'info';
  action?: { label: string; onClick: () => void };
  /** ms; 0 keeps it until dismissed. */
  duration?: number;
}

interface ToastItem extends ToastInput {
  id: number;
}

interface ToastApi {
  toast: (t: ToastInput) => void;
}

const ToastContext = createContext<ToastApi | null>(null);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<ToastItem[]>([]);
  const next = useRef(1);

  const dismiss = useCallback((id: number) => {
    setItems((all) => all.filter((t) => t.id !== id));
  }, []);

  const toast = useCallback(
    (t: ToastInput) => {
      const id = next.current++;
      setItems((all) => [...all.slice(-2), { ...t, id }]);
      const duration = t.duration ?? (t.action ? 6000 : 3500);
      if (duration > 0) window.setTimeout(() => dismiss(id), duration);
    },
    [dismiss],
  );

  const api = useMemo(() => ({ toast }), [toast]);

  return (
    <ToastContext value={api}>
      {children}
      <div
        aria-live="polite"
        className="pointer-events-none fixed inset-x-0 top-0 z-50 flex flex-col items-center gap-2 px-3 pt-[max(0.75rem,env(safe-area-inset-top))] sm:top-auto sm:right-4 sm:bottom-4 sm:left-auto sm:items-end sm:px-0"
      >
        {items.map((t) => (
          <div
            key={t.id}
            role="status"
            className={cn(
              'pointer-events-auto flex w-full max-w-sm animate-rise items-start gap-3 rounded-2xl border border-line bg-ink px-4 py-3 text-paper shadow-float',
            )}
          >
            <span
              className={cn(
                'mt-0.5 grid size-5 place-items-center rounded-full',
                t.tone === 'danger' ? 'bg-danger' : t.tone === 'info' ? 'bg-info' : 'bg-ok',
              )}
            >
              <Icon
                name={t.tone === 'danger' ? 'x' : t.tone === 'info' ? 'info' : 'check'}
                className="size-3.5 text-white"
                strokeWidth={3}
              />
            </span>
            <div className="min-w-0 flex-1">
              <p className="text-sm font-semibold">{t.title}</p>
              {t.description ? <p className="text-xs opacity-75">{t.description}</p> : null}
            </div>
            {t.action ? (
              <button
                type="button"
                className="-my-1 h-8 shrink-0 rounded-full bg-paper/15 px-3 text-sm font-semibold hover:bg-paper/25"
                onClick={() => {
                  t.action?.onClick();
                  dismiss(t.id);
                }}
              >
                {t.action.label}
              </button>
            ) : null}
            <button
              type="button"
              aria-label="Dismiss"
              className="-my-1 -mr-1 grid size-8 shrink-0 place-items-center rounded-full opacity-60 hover:opacity-100"
              onClick={() => dismiss(t.id)}
            >
              <Icon name="x" className="size-4" />
            </button>
          </div>
        ))}
      </div>
    </ToastContext>
  );
}

export function useToast(): ToastApi {
  const ctx = use(ToastContext);
  if (!ctx) throw new Error('useToast must be used inside <ToastProvider>');
  return ctx;
}
