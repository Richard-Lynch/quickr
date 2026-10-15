import './index.css';

import { PersistQueryClientProvider } from '@tanstack/react-query-persist-client';
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { RouterProvider } from 'react-router/dom';

import { connectDueBadge } from './api/dueBadge';
import { connectOutboxEffects } from './api/outboxEffects';
import { persistOptions } from './api/persist';
import { createQueryClient } from './api/queryClient';
import { UpdatePrompt } from './components/pwa/UpdatePrompt';
import { ToastProvider } from './components/ui/Toast';
import { captureInstallPrompt } from './lib/install';
import { outbox, startOutbox } from './lib/outbox/client';
import { isNavigateMessage } from './lib/pushPayload';
import { router } from './router';

const root = document.getElementById('root');
if (!root) throw new Error('#root missing');

// Before anything renders: Chromium fires this early and only once.
captureInstallPrompt();

const queryClient = createQueryClient();
connectOutboxEffects(queryClient, outbox);
connectDueBadge(queryClient);

// Notification clicks: the SW asks an open window to route in-app (keeps SPA state and
// goes through the unsaved-changes guard).
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.addEventListener('message', (e: MessageEvent) => {
    if (isNavigateMessage(e.data)) void router.navigate(e.data.url);
  });
}

/** Restored (or failed to restore) the cache: now flush the outbox over fresh state. */
const onCacheReady = () => {
  startOutbox();
  void queryClient.resumePausedMutations();
};

createRoot(root).render(
  <StrictMode>
    <PersistQueryClientProvider
      client={queryClient}
      persistOptions={persistOptions}
      onSuccess={onCacheReady}
      onError={onCacheReady}
    >
      <ToastProvider>
        <RouterProvider router={router} />
        <UpdatePrompt />
      </ToastProvider>
    </PersistQueryClientProvider>
  </StrictMode>,
);
