import { useId, useState, type KeyboardEvent } from 'react';
import { useFormContext, useWatch, type FieldErrors } from 'react-hook-form';

import { useLimits } from '../../api/limits';
import { checkTags, COLOR_NAMES, topicStyle, type ColorName } from '../../lib/appearance';
import type { AppearanceDraft } from '../../lib/builder';
import { appearanceLimitsOf } from '../../lib/topicAppearanceSeam';
import { IconButton } from '../ui/Button';
import { Input } from '../ui/Field';
import { Icon } from '../ui/Icon';
import { cn } from '../ui/cn';
import { fieldError } from './fieldError';

/** appearance.md §7: the curated grid (U+FE0F written out where the emoji needs it). */
export const CURATED_EMOJI = [
  '🚬',
  '🏃',
  '😴',
  '💊',
  '🍺',
  '☕',
  '🧘',
  '\u{1F3CB}\u{FE0F}',
  '🚿',
  '\u{1F6CF}\u{FE0F}',
  '🦷',
  '💧',
  '\u{1F37D}\u{FE0F}',
  '🚶',
  '📚',
  '🧹',
  '🐕',
  '🚗',
  '💼',
  '🎸',
  '🩺',
  '🧠',
  '\u{2764}\u{FE0F}',
  '⭐',
] as const;

interface AppearanceForm {
  appearance: AppearanceDraft;
}

const title = (c: string) => c.charAt(0).toUpperCase() + c.slice(1);

/** The enclosing form's `appearance` and a setter that marks it dirty (and revalidates once submitted). */
function useAppearance() {
  const { control, setValue, formState } = useFormContext<AppearanceForm>();
  const value = useWatch({ control, name: 'appearance' });
  const set = <K extends keyof AppearanceDraft>(key: K, v: AppearanceDraft[K]) => {
    setValue(`appearance.${key}`, v as never, {
      shouldDirty: true,
      shouldValidate: formState.isSubmitted,
    });
  };
  const errors = formState.errors as FieldErrors;
  return { value, set, errors };
}

/**
 * The Appearance group of the new-topic and settings forms (appearance.md §7): colour swatches, an
 * emoji grid plus free input, and a tags editor. Reads and writes `appearance.*` of the enclosing
 * form (which must hold one, e.g. `appearanceDraftOf`), whose schema (`makeAppearanceSchema`)
 * validates it on submit; server errors land on the same paths (`builderFieldFor`).
 */
export function AppearanceFields() {
  return (
    <fieldset className="flex flex-col gap-4">
      <legend className="mb-3 font-display text-base font-semibold tracking-tight">
        Appearance
      </legend>
      <ColorField />
      <EmojiField />
      <TagsField />
    </fieldset>
  );
}

function GroupLabel({ id, children }: { id: string; children: string }) {
  return (
    <span id={id} className="text-sm font-semibold text-ink-soft">
      {children}
    </span>
  );
}

function ErrorText({ id, error }: { id: string; error: string | undefined }) {
  return error ? (
    <p id={id} role="alert" className="text-sm font-medium text-danger">
      {error}
    </p>
  ) : null;
}

const SWATCHES: readonly (ColorName | null)[] = [null, ...COLOR_NAMES];

function ColorField() {
  const { value, set, errors } = useAppearance();
  const error = fieldError(errors, 'appearance.color');
  const id = useId();
  return (
    <div className="flex flex-col gap-1.5">
      <GroupLabel id={`${id}-label`}>Colour</GroupLabel>
      <div
        role="radiogroup"
        aria-labelledby={`${id}-label`}
        aria-describedby={error ? `${id}-err` : undefined}
        className="flex flex-wrap gap-2"
      >
        {SWATCHES.map((c) => {
          const checked = value.color === c;
          return (
            <label
              key={c ?? 'none'}
              className="relative inline-flex size-9 cursor-pointer items-center justify-center"
            >
              <input
                type="radio"
                name={`${id}-color`}
                aria-label={c ? title(c) : 'None'}
                checked={checked}
                onChange={() => set('color', c)}
                className="peer sr-only"
              />
              <span
                aria-hidden="true"
                style={topicStyle({ color: c, icon: null, tags: [] })}
                className={cn(
                  'inline-flex size-9 items-center justify-center rounded-full peer-focus-visible:ring-3 peer-focus-visible:ring-accent/40',
                  c
                    ? 'bg-topic-tint text-topic-on-tint'
                    : 'border-2 border-dashed border-line-strong text-muted',
                  checked && 'ring-2 ring-ink ring-offset-2 ring-offset-surface',
                )}
              >
                {checked ? (
                  <Icon name="check" strokeWidth={3} className="size-4" />
                ) : c ? null : (
                  <Icon name="x" className="size-4" />
                )}
              </span>
            </label>
          );
        })}
      </div>
      <ErrorText id={`${id}-err`} error={error} />
    </div>
  );
}

function EmojiField() {
  const { value, set, errors } = useAppearance();
  const error = fieldError(errors, 'appearance.icon');
  const id = useId();
  const icon = value.icon;
  return (
    <div className="flex flex-col gap-1.5">
      <GroupLabel id={`${id}-label`}>Emoji</GroupLabel>
      <div role="group" aria-labelledby={`${id}-label`} className="grid grid-cols-8 gap-1">
        {CURATED_EMOJI.map((emoji) => {
          const pressed = icon === emoji;
          return (
            <button
              key={emoji}
              type="button"
              aria-pressed={pressed}
              onClick={() => set('icon', pressed ? '' : emoji)}
              className={cn(
                'inline-flex aspect-square items-center justify-center rounded-lg text-xl transition-colors',
                pressed ? 'bg-accent-soft ring-2 ring-accent' : 'hover:bg-sunken',
              )}
            >
              {emoji}
            </button>
          );
        })}
      </div>
      <div className="flex items-center gap-2">
        <label htmlFor={`${id}-input`} className="sr-only">
          Type an emoji
        </label>
        <Input
          id={`${id}-input`}
          name="appearance.icon"
          value={icon}
          onChange={(ev) => set('icon', ev.target.value)}
          placeholder="Or type one"
          autoComplete="off"
          aria-describedby={error ? `${id}-err` : undefined}
          aria-invalid={Boolean(error) || undefined}
          className="text-center text-xl"
        />
        {icon ? (
          <IconButton label="Remove emoji" size="sm" onClick={() => set('icon', '')}>
            <Icon name="x" className="size-4" />
          </IconButton>
        ) : null}
      </div>
      <ErrorText id={`${id}-err`} error={error} />
    </div>
  );
}

/** The tags error to show: the list's own (too many) or the first tag's, with that tag's index. */
function tagsError(errors: FieldErrors, tags: readonly string[]) {
  const own = fieldError(errors, 'appearance.tags');
  if (own) return { message: own, index: -1 };
  for (const i of tags.keys()) {
    const message = fieldError(errors, `appearance.tags.${String(i)}`);
    if (message) return { message, index: i };
  }
  return { message: undefined, index: -1 };
}

function TagsField() {
  const { value, set, errors } = useAppearance();
  const limits = appearanceLimitsOf(useLimits());
  const [text, setText] = useState('');
  const [local, setLocal] = useState<string | null>(null);
  const id = useId();
  const tags = value.tags;
  const server = tagsError(errors, tags);
  const error = local ?? server.message;

  /** Adds the non-blank parts in turn up to the first `checkTags` refuses; returns how many it took. */
  const commit = (parts: readonly string[]): number => {
    let next = tags;
    let taken = 0;
    for (const raw of parts) {
      if (raw.trim() === '') {
        taken++;
        continue;
      }
      const r = checkTags([...next, raw], {
        maxTags: limits.max_tags,
        maxLength: limits.max_tag_length,
      });
      if (!r.ok) {
        setLocal(r.message);
        break;
      }
      next = r.value;
      taken++;
    }
    if (next !== tags) set('tags', next);
    return taken;
  };
  const onKeyDown = (ev: KeyboardEvent<HTMLInputElement>) => {
    if (ev.key !== 'Enter' && ev.key !== ',') return;
    // Enter would submit the form; a comma is the separator, never part of a tag.
    ev.preventDefault();
    if (commit([text]) === 1) setText('');
  };
  const onTextChange = (v: string) => {
    setLocal(null);
    if (!v.includes(',')) {
      setText(v);
      return;
    }
    // A pasted "a, b, c" adds the complete parts and leaves the last in the input.
    const parts = v.split(',');
    const last = parts.pop() ?? '';
    const taken = commit(parts);
    setText(taken === parts.length ? last : [...parts.slice(taken), last].join(','));
  };
  const remove = (i: number) => {
    set(
      'tags',
      tags.filter((_, j) => j !== i),
    );
    setLocal(null);
  };

  return (
    <div className="flex flex-col gap-1.5">
      <label htmlFor={`${id}-input`} className="text-sm font-semibold text-ink-soft">
        Tags <span className="ml-1.5 font-normal text-muted">optional</span>
      </label>
      {tags.length > 0 ? (
        <ul aria-label="Current tags" className="flex flex-wrap gap-1.5">
          {tags.map((t, i) => (
            <li
              key={t}
              className={cn(
                'inline-flex h-7 items-center gap-0.5 rounded-full bg-sunken pr-0.5 pl-2.5 text-xs font-semibold text-ink-soft',
                server.index === i && local === null && 'bg-danger-soft text-danger',
              )}
            >
              {t}
              <button
                type="button"
                aria-label={`Remove tag ${t}`}
                onClick={() => remove(i)}
                className="inline-flex size-6 items-center justify-center rounded-full hover:bg-line"
              >
                <Icon name="x" className="size-3.5" />
              </button>
            </li>
          ))}
        </ul>
      ) : null}
      <Input
        id={`${id}-input`}
        value={text}
        onChange={(ev) => onTextChange(ev.target.value)}
        onKeyDown={onKeyDown}
        onBlur={() => {
          if (commit([text]) === 1) setText('');
        }}
        placeholder="Add a tag"
        autoComplete="off"
        enterKeyHint="done"
        aria-describedby={`${id}-${error ? 'err' : 'hint'}`}
        aria-invalid={Boolean(error) || undefined}
      />
      {error ? (
        <ErrorText id={`${id}-err`} error={error} />
      ) : (
        <p id={`${id}-hint`} className="text-[0.8rem] text-muted">
          Enter or a comma adds it · up to {limits.max_tags}
        </p>
      )}
    </div>
  );
}
