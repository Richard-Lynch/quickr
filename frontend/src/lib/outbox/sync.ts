import { isClientOutdated } from '../../api/clientVersion';
import type { Outbox } from './outbox';

/**
 * A Background Sync event's flush (the service worker's `sync` handler). Rejecting asks the
 * browser to retry later, with its own backoff, so it rejects while items are still pending.
 * It resolves when the bundle is outdated (client-versions.md §5.3): a retry would only be
 * held again, and the updated bundle sends the items.
 */
export async function syncOutbox(outbox: Outbox, lastChance: boolean): Promise<void> {
  if (isClientOutdated()) return;
  await outbox.flush({ force: true });
  if (isClientOutdated()) return;
  const stillPending = (await outbox.list()).some((i) => i.status === 'pending');
  if (stillPending && !lastChance) throw new Error('outbox: items still pending');
}
