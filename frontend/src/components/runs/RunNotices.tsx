/**
 * Shows the §11.4 notices (`lib/runs/notices.ts`) as toasts while the app is on screen.
 * A notice that arrives while it's hidden stays for the sync sheet.
 */
import { useEffect, useSyncExternalStore } from 'react';

import { dismissRunNotice, getRunNotices, subscribeRunNotices } from '../../lib/runs/notices';
import { useToast } from '../ui/Toast';

export function useRunNotices() {
  return useSyncExternalStore(subscribeRunNotices, getRunNotices, getRunNotices);
}

export function RunNotices() {
  const notices = useRunNotices();
  const { toast } = useToast();
  useEffect(() => {
    if (document.visibilityState === 'hidden') return;
    for (const n of notices) {
      toast({ title: n.text, tone: 'info', duration: 6000 });
      dismissRunNotice(n.id);
    }
  }, [notices, toast]);
  return null;
}
