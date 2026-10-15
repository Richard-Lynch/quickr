import { useQueryClient } from '@tanstack/react-query';
import { useEffect, useState, useSyncExternalStore, type ReactNode } from 'react';

import { Page, TopBar } from '../components/AppShell';
import { IosInstallSteps } from '../components/pwa/InstallHint';
import { OutboxPanel } from '../components/pwa/Sync';
import { getRegistration, subscribeRegistration } from '../components/pwa/swRegistration';
import { Button } from '../components/ui/Button';
import { Badge, Card, SectionTitle } from '../components/ui/Card';
import { Icon } from '../components/ui/Icon';
import { ConfirmSheet } from '../components/ui/Sheet';
import { Switch } from '../components/ui/Switch';
import { useToast } from '../components/ui/Toast';
import { badgeSupported } from '../lib/badge';
import { formatDateTime } from '../lib/dates';
import { plural } from '../lib/format';
import { promptInstall, useInstallState } from '../lib/install';
import { clearLocalData } from '../lib/localData';
import { useOutbox } from '../lib/outbox/useOutbox';
import {
  disablePush,
  enablePush,
  fetchPushConfig,
  getPushSubscription,
  pushSupport,
  sendTestPush,
  type PushSupport,
} from '../lib/push';

function Section({
  title,
  icon,
  aside,
  children,
}: {
  title: string;
  icon: Parameters<typeof Icon>[0]['name'];
  aside?: ReactNode;
  children: ReactNode;
}) {
  return (
    <Card className="flex flex-col gap-4 p-4 sm:p-5">
      <SectionTitle
        aside={aside}
        className="items-center [&>h2]:flex [&>h2]:items-center [&>h2]:gap-2"
      >
        <Icon name={icon} className="size-5 text-accent" />
        {title}
      </SectionTitle>
      {children}
    </Card>
  );
}

export function AppSettingsPage() {
  return (
    <>
      <TopBar back="/" title="Settings" />
      <Page className="mx-auto max-w-2xl gap-4">
        <InstallSection />
        <NotificationsSection />
        <SyncSection />
        <AboutSection />
        <StorageSection />
      </Page>
    </>
  );
}

function InstallSection() {
  const { standalone, canPrompt, platform, justInstalled } = useInstallState();
  const installed = standalone || justInstalled;
  return (
    <Section
      title="App"
      icon="phone"
      aside={
        installed ? <Badge tone="ok">Installed</Badge> : <Badge tone="neutral">In browser</Badge>
      }
    >
      {installed ? (
        <p className="text-sm text-muted">
          {standalone
            ? 'quickR is running as an installed app.'
            : 'Installed — open quickR from your Home Screen or app list.'}
        </p>
      ) : platform.os === 'ios' ? (
        <>
          <p className="text-sm text-muted">
            Add quickR to your Home Screen for a full-screen app that opens instantly, works offline
            and can send notifications.
          </p>
          <IosInstallSteps platform={platform} />
        </>
      ) : canPrompt ? (
        <div className="flex flex-col items-start gap-3">
          <p className="text-sm text-muted">Install quickR for a full-screen, offline-ready app.</p>
          <Button
            variant="primary"
            icon={<Icon name="download" className="size-4" />}
            onClick={() => void promptInstall()}
          >
            Install app
          </Button>
        </div>
      ) : (
        <p className="text-sm text-muted">
          To install, use your browser’s menu (e.g. “Install app” or “Add to Home screen”).
        </p>
      )}
    </Section>
  );
}

function NotificationsSection() {
  const { toast } = useToast();
  const { platform } = useInstallState();
  const [support, setSupport] = useState<PushSupport>(pushSupport);
  const [subscribed, setSubscribed] = useState<boolean | null>(null);
  // undefined = still checking, null = the server has no push support (yet)
  const [publicKey, setPublicKey] = useState<string | null | undefined>(undefined);
  const [busy, setBusy] = useState(false);
  const [testing, setTesting] = useState(false);
  const available = support.state === 'available';

  useEffect(() => {
    if (!available) return;
    let alive = true;
    void getPushSubscription().then((s) => {
      if (alive) setSubscribed(s !== null);
    });
    fetchPushConfig().then(
      (c) => {
        if (alive) setPublicKey(c?.public_key ?? null);
      },
      () => {
        if (alive) setPublicKey(null);
      },
    );
    return () => {
      alive = false;
    };
  }, [available]);

  const toggle = (on: boolean) => {
    setBusy(true);
    // enablePush asks for permission first thing — keep it directly in the tap handler.
    const work = on ? enablePush(publicKey ?? undefined) : disablePush().then(() => ({ ok: true }));
    work
      .then((r) => {
        if (r.ok) {
          setSubscribed(on);
          toast({ title: on ? 'Notifications on' : 'Notifications off' });
          return;
        }
        if ('reason' in r) {
          if (r.reason === 'denied') setSupport({ state: 'denied' });
          toast({
            title:
              r.reason === 'not-configured'
                ? 'Notifications aren’t set up on this server yet'
                : r.reason === 'no-service-worker'
                  ? 'Reload the app and try again'
                  : 'Notifications not allowed',
            tone: 'info',
          });
        }
      })
      .catch((err: unknown) => {
        toast({
          title: 'Could not change notifications',
          description: err instanceof Error ? err.message : undefined,
          tone: 'danger',
        });
      })
      .finally(() => {
        setBusy(false);
        setSupport(pushSupport());
      });
  };

  const control =
    available && publicKey !== null ? (
      <Switch
        label="Notifications"
        checked={subscribed === true}
        busy={busy || subscribed === null || publicKey === undefined}
        onChange={toggle}
      />
    ) : null;

  return (
    <Section title="Notifications" icon="bell" aside={control}>
      {support.state === 'needs-install' ? (
        <p className="text-sm text-muted">
          On iPhone and iPad, notifications only work once quickR is added to the Home Screen (iOS
          16.4+, see above). Then open it from there and turn them on here.
        </p>
      ) : support.state === 'unsupported' ? (
        <p className="text-sm text-muted">{support.reason}</p>
      ) : support.state === 'denied' ? (
        <p className="text-sm text-muted">
          Notifications are blocked.{' '}
          {platform.os === 'ios'
            ? 'Turn them on in the iOS Settings app → Notifications → quickR.'
            : 'Allow them in your browser’s site settings for this page.'}
        </p>
      ) : publicKey === null ? (
        <p className="text-sm text-muted">This server doesn’t support notifications yet.</p>
      ) : (
        <>
          <p className="text-sm text-muted">
            Get reminders when it’s time to record.
            {badgeSupported() ? ' The app icon shows how many are due.' : ''}
          </p>
          {subscribed ? (
            <div>
              <Button
                size="sm"
                loading={testing}
                icon={<Icon name="bell" className="size-4" />}
                onClick={() => {
                  setTesting(true);
                  sendTestPush()
                    .then((ok) => {
                      toast(
                        ok
                          ? { title: 'Test sent', description: 'It should arrive in a moment.' }
                          : { title: 'Test not available on this server', tone: 'info' },
                      );
                    })
                    .catch((err: unknown) => {
                      toast({
                        title: 'Test failed',
                        description: err instanceof Error ? err.message : undefined,
                        tone: 'danger',
                      });
                    })
                    .finally(() => setTesting(false));
                }}
              >
                Send a test notification
              </Button>
            </div>
          ) : null}
        </>
      )}
    </Section>
  );
}

function SyncSection() {
  const { online } = useOutbox();
  return (
    <Section
      title="Offline & sync"
      icon="sync"
      aside={online ? <Badge tone="ok">Online</Badge> : <Badge tone="warn">Offline</Badge>}
    >
      <p className="text-sm text-muted">
        Topics and recent entries you’ve viewed are kept on this device. Entries recorded offline
        are queued here and sent automatically.
      </p>
      <OutboxPanel />
    </Section>
  );
}

function AboutSection() {
  const { toast } = useToast();
  const registration = useSyncExternalStore(
    subscribeRegistration,
    getRegistration,
    getRegistration,
  );
  const [checking, setChecking] = useState(false);
  return (
    <Section title="About" icon="info">
      <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5 text-sm">
        <dt className="text-muted">Version</dt>
        <dd className="font-mono">{__APP_VERSION__}</dd>
        <dt className="text-muted">Built</dt>
        <dd>{formatDateTime(__BUILD_TIME__)}</dd>
        <dt className="text-muted">API schema</dt>
        <dd className="font-mono">{__API_HASH__}</dd>
        <dt className="text-muted">Offline support</dt>
        <dd>{registration?.active ? 'Active' : 'Not active (needs HTTPS)'}</dd>
      </dl>
      {registration ? (
        <div>
          <Button
            size="sm"
            loading={checking}
            onClick={() => {
              setChecking(true);
              registration
                .update()
                .then(() => {
                  if (!registration.waiting && !registration.installing)
                    toast({ title: 'You’re up to date', tone: 'info' });
                })
                .catch(() => toast({ title: 'Could not check for updates', tone: 'danger' }))
                .finally(() => setChecking(false));
            }}
          >
            Check for updates
          </Button>
        </div>
      ) : null}
    </Section>
  );
}

function StorageSection() {
  const qc = useQueryClient();
  const { items } = useOutbox();
  const [confirm, setConfirm] = useState(false);
  const [busy, setBusy] = useState(false);
  return (
    <Section title="Local data" icon="trash">
      <p className="text-sm text-muted">
        Remove cached data and preferences from this device. Nothing on the server is changed.
      </p>
      <div>
        <Button variant="quiet-danger" onClick={() => setConfirm(true)}>
          Clear local data
        </Button>
      </div>
      <ConfirmSheet
        open={confirm}
        onClose={() => setConfirm(false)}
        title="Clear local data?"
        danger
        busy={busy}
        confirmLabel="Clear and reload"
        body={
          <>
            <p>Cached topics and entries and your preferences on this device will be removed.</p>
            {items.length > 0 ? (
              <p className="font-semibold text-danger">
                {plural(items.length, 'unsynced item')} will be lost for good.
              </p>
            ) : null}
          </>
        }
        onConfirm={() => {
          setBusy(true);
          void clearLocalData(qc).finally(() => {
            window.location.reload();
          });
        }}
      />
    </Section>
  );
}
