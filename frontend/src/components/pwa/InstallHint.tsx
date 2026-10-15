import { useState, type ReactNode } from 'react';

import {
  dismissInstallHint,
  installHintDismissed,
  promptInstall,
  useInstallState,
} from '../../lib/install';
import type { Platform } from '../../lib/platform';
import { Button, IconButton } from '../ui/Button';
import { Card } from '../ui/Card';
import { Icon } from '../ui/Icon';

/** Step-by-step "Add to Home Screen" instructions for the current iOS browser. */
export function IosInstallSteps({ platform }: { platform: Platform }) {
  const browser = platform.os === 'ios' ? platform.browser : 'safari';
  const share = <Icon name="share" className="inline size-4 align-[-3px]" />;
  const steps: ReactNode[] =
    browser === 'chrome'
      ? [
          <>Tap the Share icon {share} in the address bar (top right).</>,
          <>
            Choose <strong>Add to Home Screen</strong> (scroll down if needed).
          </>,
          <>
            Tap <strong>Add</strong>, then open quickR from your Home Screen.
          </>,
        ]
      : browser === 'safari'
        ? [
            <>Tap the Share button {share} in the toolbar.</>,
            <>
              Choose <strong>Add to Home Screen</strong>.
            </>,
            <>
              Tap <strong>Add</strong>, then open quickR from your Home Screen.
            </>,
          ]
        : [
            <>Open your browser’s Share menu {share}.</>,
            <>
              Choose <strong>Add to Home Screen</strong> (or open this page in Safari or Chrome to
              do it).
            </>,
          ];
  return (
    <ol className="flex list-decimal flex-col gap-1.5 pl-5 text-sm text-ink-soft">
      {steps.map((s, i) => (
        <li key={i}>{s}</li>
      ))}
    </ol>
  );
}

/**
 * One-time, dismissible install suggestion (topics screen). Never shown once installed,
 * once dismissed, or when there is nothing actionable to say.
 */
export function InstallHint() {
  const { standalone, canPrompt, platform } = useInstallState();
  const [hidden, setHidden] = useState(installHintDismissed);
  const ios = platform.os === 'ios';
  if (hidden || standalone || (!ios && !canPrompt)) return null;

  const dismiss = () => {
    dismissInstallHint();
    setHidden(true);
  };

  return (
    <Card className="relative flex animate-rise flex-col gap-3 p-4 pr-12">
      <IconButton label="Dismiss" size="sm" onClick={dismiss} className="absolute top-2 right-2">
        <Icon name="x" className="size-4" />
      </IconButton>
      <div className="flex items-center gap-3">
        <span className="grid size-9 shrink-0 place-items-center rounded-xl bg-accent-soft text-accent-strong">
          <Icon name="phone" className="size-5" />
        </span>
        <div>
          <p className="font-semibold">Install quickR</p>
          <p className="text-sm text-muted">
            Full screen, one tap from your Home Screen
            {ios ? ', with notifications.' : ', works offline.'}
          </p>
        </div>
      </div>
      {ios ? (
        <IosInstallSteps platform={platform} />
      ) : (
        <div>
          <Button
            variant="primary"
            size="sm"
            icon={<Icon name="download" className="size-4" />}
            onClick={() => {
              void promptInstall().then((accepted) => {
                if (accepted) dismiss();
              });
            }}
          >
            Install app
          </Button>
        </div>
      )}
    </Card>
  );
}
