import { useState, type ComponentProps, type ReactNode } from 'react';
import { FormProvider, type UseFormReturn } from 'react-hook-form';

import type { TopicDraft } from '../../lib/builder';
import { Segmented } from '../ui/Segmented';
import { FormPreview } from './FormPreview';
import { QuestionsEditor } from './QuestionsEditor';

interface Props<TOut> {
  form: UseFormReturn<TopicDraft, unknown, TOut>;
  /** Rendered above the questions (topic metadata, banners…). */
  header?: ReactNode;
  /** Rendered below the questions (change note…). */
  footer?: ReactNode;
  defaultExpanded: 'all' | 'new';
  onSubmit: NonNullable<ComponentProps<'form'>['onSubmit']>;
  actions: ReactNode;
}

/**
 * Two-pane builder: editor + live preview side by side on desktop; an
 * Edit / Preview switch on phones so each gets the full width.
 */
export function TopicBuilder<TOut>({
  form,
  header,
  footer,
  defaultExpanded,
  onSubmit,
  actions,
}: Props<TOut>) {
  const [pane, setPane] = useState<'edit' | 'preview'>('edit');
  return (
    <FormProvider {...form}>
      <form onSubmit={onSubmit} noValidate className="flex flex-col gap-5">
        <div className="lg:hidden">
          <Segmented
            label="Builder view"
            size="md"
            value={pane}
            onChange={setPane}
            options={[
              { value: 'edit', label: 'Edit' },
              { value: 'preview', label: 'Preview' },
            ]}
            className="w-full [&>label]:flex-1"
          />
        </div>
        <div className="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(0,24rem)]">
          <div
            className={
              pane === 'edit' ? 'flex flex-col gap-6' : 'hidden lg:flex lg:flex-col lg:gap-6'
            }
          >
            {header}
            <QuestionsEditor defaultExpanded={defaultExpanded} />
            {footer}
          </div>
          <aside
            className={
              pane === 'preview'
                ? 'block lg:sticky lg:top-20'
                : 'hidden lg:sticky lg:top-20 lg:block'
            }
          >
            <FormPreview />
          </aside>
        </div>
        {actions}
      </form>
    </FormProvider>
  );
}
