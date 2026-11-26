import { useId, useState, type ReactNode } from 'react';
import {
  useFormContext,
  useFormState,
  useWatch,
  type UseFormRegisterReturn,
} from 'react-hook-form';

import type { Limits } from '../../client';
import type { TopicDraft } from '../../lib/builder';
import { IconButton } from '../ui/Button';
import { Badge } from '../ui/Card';
import { cn } from '../ui/cn';
import { Input } from '../ui/Field';
import { Icon } from '../ui/Icon';
import { AlertsEditor } from './AlertsEditor';
import { fieldError } from './fieldError';

export type TimerOwner = 'steps' | 'laps';

/**
 * One step or lap type (timers2.md §1.6): its name, move and remove buttons, its key with a
 * published / new badge, and its alerts behind a toggle that shows their count while collapsed.
 * An error inside its alerts opens them, so a server error is never hidden.
 */
export function TimerItemRow({
  owner,
  index,
  uid,
  count,
  name,
  inputLabel,
  placeholder,
  keyTestId,
  registration,
  maxLength,
  limits,
  onMove,
  onRemove,
}: {
  owner: TimerOwner;
  index: number;
  uid: string;
  count: number;
  /** "Run (lap type 1)", or "lap type 1" while it has no name. */
  name: string;
  inputLabel: string;
  placeholder: string;
  keyTestId: string;
  registration: UseFormRegisterReturn;
  maxLength?: number | undefined;
  limits: Limits;
  onMove: (to: number) => void;
  onRemove: () => void;
}): ReactNode {
  const { control } = useFormContext<TopicDraft>();
  const { errors } = useFormState({ control, name: `${owner}.${index}` });
  const item = useWatch({ control, name: `${owner}.${index}` });
  const [open, setOpen] = useState(false);
  const alertsId = useId();
  const labelError = fieldError(errors, `${owner}.${index}.label`);
  const keyError = fieldError(errors, `${owner}.${index}.key`);
  const alertErrors = Boolean(
    (errors[owner] as Record<number, { alerts?: unknown } | undefined> | undefined)?.[index]
      ?.alerts,
  );
  const expanded = open || alertErrors;
  const errorId = `${uid}-error`;
  const alertCount = item.alerts.length;
  return (
    <li
      className={cn(
        'flex flex-col gap-1 rounded-card border bg-surface px-3 py-2 shadow-card',
        labelError || keyError ? 'border-danger/60' : 'border-line',
      )}
    >
      <div className="flex items-center gap-1">
        <span className="w-5 shrink-0 font-mono text-xs text-muted">{index + 1}</span>
        <Input
          id={uid}
          aria-label={inputLabel}
          aria-invalid={labelError || keyError ? true : undefined}
          aria-describedby={labelError || keyError ? errorId : undefined}
          placeholder={placeholder}
          className="h-11 min-w-0 flex-1"
          maxLength={maxLength}
          {...registration}
        />
        <IconButton
          label={`Move up: ${name}`}
          size="sm"
          disabled={index === 0}
          onClick={() => onMove(index - 1)}
        >
          <Icon name="up" className="size-4.5" />
        </IconButton>
        <IconButton
          label={`Move down: ${name}`}
          size="sm"
          disabled={index === count - 1}
          onClick={() => onMove(index + 1)}
        >
          <Icon name="down" className="size-4.5" />
        </IconButton>
        <IconButton
          label={`Remove ${name}`}
          size="sm"
          onClick={onRemove}
          className="hover:bg-danger-soft hover:text-danger"
        >
          <Icon name="trash" className="size-4.5" />
        </IconButton>
      </div>
      <div className="flex items-center gap-2 pl-6 text-xs text-muted">
        <span className="min-w-0 truncate font-mono" data-testid={keyTestId}>
          {item.key || '—'}
        </span>
        {item.locked ? <Badge>published</Badge> : <Badge tone="accent">new</Badge>}
        <button
          type="button"
          aria-label={`Alerts: ${name}`}
          aria-expanded={expanded}
          aria-controls={alertsId}
          onClick={() => setOpen(!expanded)}
          className={cn(
            'ml-auto inline-flex h-8 items-center gap-1.5 rounded-full px-2.5 font-medium text-ink-soft hover:bg-sunken',
            alertErrors && 'text-danger',
          )}
        >
          <Icon name="bell" className="size-4" />
          Alerts
          {alertCount > 0 ? (
            <span
              data-testid="alert-count"
              className="inline-flex h-5 min-w-5 items-center justify-center rounded-full bg-accent-soft px-1.5 font-mono text-[0.7rem] font-semibold text-accent-strong"
            >
              {alertCount}
            </span>
          ) : null}
          <Icon name={expanded ? 'up' : 'down'} className="size-3.5" />
        </button>
      </div>
      {labelError || keyError ? (
        <p id={errorId} role="alert" className="pl-6 text-sm font-medium text-danger">
          {labelError ?? keyError}
        </p>
      ) : null}
      {expanded ? (
        <div id={alertsId}>
          <AlertsEditor owner={owner} index={index} ownerName={name} limits={limits} />
        </div>
      ) : null}
    </li>
  );
}
