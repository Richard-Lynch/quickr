import { useRef } from 'react';
import { useFieldArray, useFormContext, useFormState, useWatch } from 'react-hook-form';

import type { Limits } from '../../client';
import { alertPreview, newDraftAlert, withAlertLabel, type TopicDraft } from '../../lib/builder';
import { inputMaxLength } from '../../lib/text';
import { Button, IconButton } from '../ui/Button';
import { cn } from '../ui/cn';
import { Input } from '../ui/Field';
import { Icon } from '../ui/Icon';
import { fieldError } from './fieldError';
import type { TimerOwner } from './TimerItemRow';

/**
 * The alerts of one step or lap type (timers2.md §1.6): each a label and an expression over the
 * draft's variables (`t/2`, `t+30s`, `1.5m`), evaluated as it is typed. The result shows as
 * "at 0:30"; an error shows the server's own message with the offending character marked, so
 * the field reads the same before and after submitting.
 */
export function AlertsEditor({
  owner,
  index,
  ownerName,
  limits,
}: {
  owner: TimerOwner;
  index: number;
  ownerName: string;
  limits: Limits;
}) {
  const { control, register, getValues, setValue } = useFormContext<TopicDraft>();
  const { errors, isSubmitted } = useFormState({ control, name: `${owner}.${index}.alerts` });
  const name = `${owner}.${index}.alerts` as const;
  const { fields, append, remove } = useFieldArray({ control, name, keyName: 'fieldId' });
  const addButton = useRef<HTMLButtonElement>(null);
  const listError = fieldError(errors, name);

  const add = () => {
    const alert = newDraftAlert('', []);
    append(alert, { shouldFocus: false });
    window.setTimeout(() => {
      document.getElementById(`alert-${alert.uid}`)?.focus();
    }, 0);
  };

  return (
    <div
      role="group"
      aria-label={`Alerts for ${ownerName}`}
      className="mt-1 flex flex-col gap-2 rounded-xl bg-sunken/60 p-2 sm:ml-6"
    >
      {fields.length === 0 ? (
        <p className="px-1 text-xs text-muted">
          No alerts. An alert cues you once this has run for a time, such as{' '}
          <code className="font-mono">t/2</code> or <code className="font-mono">t+30s</code>.
        </p>
      ) : null}
      <ol className="flex flex-col gap-2">
        {fields.map((f, j) => {
          const path = `${name}.${String(j)}` as `${typeof name}.${number}`;
          const labelError =
            fieldError(errors, `${path}.label`) ?? fieldError(errors, `${path}.key`);
          const reg = register(`${name}.${j}.label`, {
            onChange: (e: { target: { value: string } }) => {
              const all = getValues(name);
              const cur = all[j];
              if (!cur) return;
              const taken = all.filter((_, k) => k !== j).map((a) => a.key);
              const next = withAlertLabel(cur, e.target.value, taken);
              if (next.key !== cur.key)
                setValue(`${name}.${j}.key`, next.key, { shouldValidate: isSubmitted });
            },
          });
          const labelErrorId = `alert-${f.uid}-label-error`;
          return (
            <li key={f.fieldId} className="flex flex-col gap-1 rounded-lg bg-surface p-2">
              <div className="flex items-center gap-1">
                <Input
                  id={`alert-${f.uid}`}
                  aria-label={`Alert ${String(j + 1)} name`}
                  aria-invalid={labelError ? true : undefined}
                  aria-describedby={labelError ? labelErrorId : undefined}
                  placeholder="Alert name"
                  maxLength={inputMaxLength(limits.max_short_label_length)}
                  className="h-10 min-w-0 flex-1"
                  {...reg}
                />
                <IconButton
                  label={`Remove alert ${String(j + 1)}`}
                  size="sm"
                  onClick={() => {
                    const next = fields[j + 1] ?? fields[j - 1];
                    remove(j);
                    window.setTimeout(() => {
                      const el = next ? document.getElementById(`alert-${next.uid}`) : null;
                      (el ?? addButton.current)?.focus();
                    }, 0);
                  }}
                  className="hover:bg-danger-soft hover:text-danger"
                >
                  <Icon name="trash" className="size-4.5" />
                </IconButton>
              </div>
              {labelError ? (
                <p id={labelErrorId} role="alert" className="text-sm font-medium text-danger">
                  {labelError}
                </p>
              ) : null}
              <AlertTime path={`${name}.${j}`} uid={f.uid} index={j} limits={limits} />
            </li>
          );
        })}
      </ol>
      {listError ? (
        <p role="alert" className="text-sm font-medium text-danger">
          {listError}
        </p>
      ) : null}
      <Button
        ref={addButton}
        size="sm"
        onClick={add}
        className="self-start border-dashed"
        icon={<Icon name="plus" />}
        disabled={fields.length >= limits.max_alerts}
      >
        Add alert
      </Button>
    </div>
  );
}

/** An alert's expression, its key, and its live result or error. */
function AlertTime({
  path,
  uid,
  index,
  limits,
}: {
  path: `${TimerOwner}.${number}.alerts.${number}`;
  uid: string;
  index: number;
  limits: Limits;
}) {
  const { control, register } = useFormContext<TopicDraft>();
  const { errors } = useFormState({ control, name: `${path}.at` });
  const alert = useWatch({ control, name: path });
  const variables = useWatch({ control, name: 'variables' });
  const preview = alertPreview(alert.at, variables, limits);
  const formError = fieldError(errors, `${path}.at`);
  const resultId = `alert-${uid}-result`;
  const chars = Array.from(alert.at);
  return (
    <div className="flex flex-col gap-1">
      <div className="flex items-center gap-2">
        <Input
          aria-label={`Alert ${String(index + 1)} time`}
          aria-invalid={formError ? true : undefined}
          aria-describedby={resultId}
          placeholder="t/2"
          autoCapitalize="none"
          autoCorrect="off"
          spellCheck={false}
          className="h-10 min-w-0 flex-1 font-mono"
          {...register(`${path}.at`)}
        />
        <span className="shrink-0 font-mono text-xs text-muted" data-testid="alert-key">
          {alert.key || '—'}
        </span>
      </div>
      {formError || !preview.ok ? (
        <div className="flex flex-col gap-0.5">
          {!formError && !preview.ok && alert.at.trim() ? (
            <p aria-hidden className="font-mono text-xs break-all text-ink-soft">
              {chars.slice(0, preview.pos).join('')}
              <mark className="rounded-sm bg-danger-soft px-px text-danger underline decoration-2">
                {chars[preview.pos] ?? ' '}
              </mark>
              {chars.slice(preview.pos + 1).join('')}
            </p>
          ) : null}
          <p
            id={resultId}
            data-testid="alert-result"
            role={formError ? 'alert' : undefined}
            className={cn('text-sm font-medium', formError ? 'text-danger' : 'text-warn')}
          >
            {formError ?? (preview.ok ? '' : preview.message)}
          </p>
        </div>
      ) : (
        <p id={resultId} data-testid="alert-result" className="text-sm text-ok">
          at {preview.text}
        </p>
      )}
    </div>
  );
}
