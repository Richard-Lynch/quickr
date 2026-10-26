/**
 * Shows the §11.4 notices (`lib/runs/notices.ts`) as toasts when they arrive while the app
 * is on screen; one that arrives while it's hidden, or was stored before the app was
 * ended, stays for the sync sheet.
 */
import { useEffect, useSyncExternalStore } from 'react';

import {
  dismissRunNotice,
  getRunNotices,
  loadRunNotices,
  subscribeNoticeArrivals,
  subscribeRunNotices,
} from '../../lib/runs/notices';
import { useToast } from '../ui/Toast';

export function useRunNotices() {
  return useSyncExternalStore(subscribeRunNotices, getRunNotices, getRunNotices);
}

export function RunNotices() {
  const { toast } = useToast();
  useEffect(() => {
    void loadRunNotices();
    return subscribeNoticeArrivals((n) => {
      if (document.visibilityState === 'hidden') return;
      toast({ title: n.text, tone: 'info', duration: 6000 });
      dismissRunNotice(n.id);
    });
  }, [toast]);
  return null;
}
