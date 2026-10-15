import { useState } from 'react';
import { useNavigate } from 'react-router';

import { isEntryCreate } from '../../lib/outbox/kinds';
import type { OutboxItem } from '../../lib/outbox/types';
import { useOutbox } from '../../lib/outbox/useOutbox';
import { formatDateTime, formatRelative } from '../../lib/dates';
import { plural } from '../../lib/format';
import { Button } from '../ui/Button';
import { Banner } from '../ui/Card';
import { cn } from '../ui/cn';
import { Icon } from '../ui/Icon';
import { Sheet } from '../ui/Sheet';

interface ItemView {
  title: string;
  when: string;
  /** In-app route that lets the user correct the item (failed items). */
  fixUrl: string | null;
}

/** How each kind is shown in the sync list (seam: add a branch per new kind). */
export function describeOutboxItem(item: OutboxItem): ItemView {
  if (isEntryCreate(item)) {
    const { topic, body } = item.payload;
    return {
      title: `Entry · ${topic.name}`,
      when: formatDateTime(body.captured_at ?? item.created_at),
      fixUrl: `/t/${topic.slug}/record?fix=${encodeURIComponent(item.id)}`,
    };
  }
  return { title: item.kind, when: formatDateTime(item.created_at), fixUrl: null };
}

function statusLine(item: OutboxItem): string {
  if (item.status === 'failed') return `Failed — ${item.last_error?.message ?? 'rejected'}`;
  if (item.attempts === 0) return 'Waiting to sync';
  const err = item.last_error?.message ?? 'not sent yet';
  const wait = item.next_attempt_at - Date.now();
  const when = !navigator.onLine
    ? 'when back online'
    : wait < 60_000
      ? 'shortly'
      : formatRelative(new Date(item.next_attempt_at).toISOString());
  return `${err} · retrying ${when}`;
}

function OutboxRow({ item, onNavigate }: { item: OutboxItem; onNavigate?: () => void }) {
  const { retry, discard } = useOutbox();
  const navigate = useNavigate();
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const view = describeOutboxItem(item);
  const failed = item.status === 'failed';

  return (
    <li
      className={cn(
        'flex flex-col gap-2 rounded-2xl border px-4 py-3',
        failed ? 'border-danger/30 bg-danger-soft/50' : 'border-line bg-surface',
      )}
    >
      <div className="flex items-start gap-3">
        <span
          className={cn(
            'mt-0.5 grid size-7 shrink-0 place-items-center rounded-full',
            failed ? 'bg-danger text-white' : 'bg-info-soft text-info',
          )}
        >
          <Icon name={failed ? 'alert' : 'clock'} className="size-4" />
        </span>
        <div className="min-w-0 flex-1">
          <p className="truncate font-semibold">{view.title}</p>
          <p className="text-xs text-muted">{view.when}</p>
          <p className={cn('mt-1 text-sm', failed ? 'text-danger' : 'text-ink-soft')}>
            {statusLine(item)}
          </p>
        </div>
      </div>
      <div className="flex flex-wrap justify-end gap-2">
        {confirming ? (
          <>
            <Button size="sm" variant="ghost" onClick={() => setConfirming(false)}>
              Keep
            </Button>
            <Button
              size="sm"
              variant="danger"
              loading={busy}
              onClick={() => {
                setBusy(true);
                void discard(item.id).finally(() => setBusy(false));
              }}
            >
              Discard for good
            </Button>
          </>
        ) : (
          <>
            <Button size="sm" variant="quiet-danger" onClick={() => setConfirming(true)}>
              Discard
            </Button>
            {failed && view.fixUrl ? (
              <Button
                size="sm"
                icon={<Icon name="edit" className="size-4" />}
                onClick={() => {
                  onNavigate?.();
                  void navigate(view.fixUrl ?? '/');
                }}
              >
                Fix
              </Button>
            ) : null}
            <Button
              size="sm"
              variant={failed ? 'secondary' : 'primary'}
              loading={busy}
              icon={<Icon name="sync" className="size-4" />}
              onClick={() => {
                setBusy(true);
                void retry(item.id).finally(() => setBusy(false));
              }}
            >
              {failed ? 'Retry as is' : 'Retry now'}
            </Button>
          </>
        )}
      </div>
    </li>
  );
}

/** Everything waiting in the outbox, with retry / fix / discard per item. */
export function OutboxPanel({ onNavigate }: { onNavigate?: () => void }) {
  const { items, online, pendingCount, failedCount, syncNow } = useOutbox();
  const [syncing, setSyncing] = useState(false);
  return (
    <div className="flex flex-col gap-4">
      {!online ? (
        <Banner tone="warn" title="You’re offline">
          Entries are kept on this device and sync automatically when the connection is back.
        </Banner>
      ) : null}
      <div className="flex items-center justify-between gap-3">
        <p className="text-sm text-muted">
          {items.length === 0
            ? 'Everything is synced.'
            : [
                pendingCount ? `${plural(pendingCount, 'item')} waiting` : null,
                failedCount ? `${failedCount} failed` : null,
              ]
                .filter(Boolean)
                .join(' · ')}
        </p>
        {pendingCount > 0 ? (
          <Button
            size="sm"
            loading={syncing}
            disabled={!online}
            icon={<Icon name="sync" className="size-4" />}
            onClick={() => {
              setSyncing(true);
              void syncNow().finally(() => setSyncing(false));
            }}
          >
            Sync now
          </Button>
        ) : null}
      </div>
      {items.length > 0 ? (
        <ul className="flex flex-col gap-2">
          {items.map((i) => (
            <OutboxRow key={i.id} item={i} {...(onNavigate ? { onNavigate } : {})} />
          ))}
        </ul>
      ) : null}
    </div>
  );
}

/**
 * Header pill: "Offline", "2 waiting to sync" or "1 failed". Hidden when all is well.
 * Tapping opens the sync sheet.
 */
export function SyncIndicator() {
  const { online, pendingCount, failedCount, loaded } = useOutbox();
  const [open, setOpen] = useState(false);
  if (!loaded || (online && pendingCount === 0 && failedCount === 0)) return null;

  const failed = failedCount > 0;
  const label = failed
    ? `${failedCount} failed to sync`
    : pendingCount > 0
      ? `${pendingCount} waiting to sync`
      : 'Offline';
  const short = failed ? `${failedCount} failed` : pendingCount > 0 ? `${pendingCount}` : 'Offline';

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        aria-label={online ? label : `Offline${pendingCount ? ` · ${label}` : ''}`}
        className={cn(
          'mr-1 inline-flex h-8 items-center gap-1.5 rounded-full px-3 text-xs font-semibold whitespace-nowrap transition-colors',
          failed
            ? 'bg-danger text-white'
            : !online
              ? 'bg-warn-soft text-warn'
              : 'bg-info-soft text-info',
        )}
      >
        <Icon
          name={failed ? 'alert' : !online ? 'cloudOff' : 'sync'}
          className={cn('size-4', online && !failed && 'animate-spin [animation-duration:2.5s]')}
        />
        <span className="sm:hidden">{short}</span>
        <span className="max-sm:hidden">
          {online || !pendingCount ? label : `Offline · ${label}`}
        </span>
      </button>
      <Sheet open={open} onClose={() => setOpen(false)} title="Sync">
        <OutboxPanel onNavigate={() => setOpen(false)} />
      </Sheet>
    </>
  );
}

export function OfflineNotice({ what = 'Entries' }: { what?: string }) {
  const { online } = useOutbox();
  if (online) return null;
  return (
    <Banner tone="warn" title="You’re offline">
      {what} are saved on this device and sync automatically when you’re back online.
    </Banner>
  );
}
