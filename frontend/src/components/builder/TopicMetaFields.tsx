import { useFormContext } from 'react-hook-form';

import { slugify, type TopicDraft } from '../../lib/builder';
import { Field, Input, Textarea } from '../ui/Field';

/** Name / slug / description. The slug follows the name until edited. */
export function TopicMetaFields() {
  const { register, setValue, getValues, formState } = useFormContext<TopicDraft>();
  const e = formState.errors;
  const nameReg = register('name', {
    onChange: (ev: { target: { value: string } }) => {
      if (!getValues('slugEdited'))
        setValue('slug', slugify(ev.target.value), { shouldValidate: formState.isSubmitted });
    },
  });
  const slugReg = register('slug', { onChange: () => setValue('slugEdited', true) });
  return (
    <div className="flex flex-col gap-4">
      <Field label="Name" error={e.name?.message}>
        {({ id, describedBy, invalid }) => (
          <Input
            id={id}
            aria-describedby={describedBy}
            aria-invalid={invalid || undefined}
            placeholder="e.g. Sleep log"
            className="h-14 font-display text-xl font-semibold"
            {...nameReg}
          />
        )}
      </Field>
      <Field label="URL slug" hint="Lowercase letters, digits and dashes" error={e.slug?.message}>
        {({ id, describedBy, invalid }) => (
          <div className="flex items-center rounded-xl border border-line-strong bg-surface focus-within:border-accent focus-within:ring-3 focus-within:ring-accent/20">
            <span className="pl-3.5 font-mono text-sm text-muted select-none">/t/</span>
            <input
              id={id}
              aria-describedby={describedBy}
              aria-invalid={invalid || undefined}
              autoCapitalize="none"
              autoCorrect="off"
              spellCheck={false}
              placeholder="sleep-log"
              className="h-12 min-w-0 flex-1 bg-transparent pr-3.5 pl-0.5 font-mono outline-none"
              {...slugReg}
            />
          </div>
        )}
      </Field>
      <Field label="Description" optional error={e.description?.message}>
        {({ id, describedBy }) => (
          <Textarea
            id={id}
            aria-describedby={describedBy}
            rows={2}
            placeholder="What is this for?"
            {...register('description')}
          />
        )}
      </Field>
    </div>
  );
}
