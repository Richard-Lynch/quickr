import { useQuery } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router';

import { errorMessage } from '../../api/errors';
import { useDeleteEntryWithUndo, useUpdateEntry } from '../../api/mutations';
import { getEntryOptions, listTopicVersionsOptions } from '../../client/@tanstack/react-query.gen';
import { Page, TopBar } from '../../components/AppShell';
import { EntryForm, type EntryFormValues } from '../../components/answers/EntryForm';
import { TimingSection } from '../../components/runs/TimingSection';
import { Button } from '../../components/ui/Button';
import { ChannelBadge } from '../../components/ChannelBadge';
import { Banner, VersionTag } from '../../components/ui/Card';
import { Icon } from '../../components/ui/Icon';
import { PageSpinner } from '../../components/ui/Spinner';
import { useToast } from '../../components/ui/Toast';
import { answerValuesFromEntry, archivedValuesInEntry } from '../../lib/answerSchema';
import { formatDateTime, toLocalInputValue } from '../../lib/dates';
import { useTopic } from './TopicLayout';

export function EntryEditPage() {
  const topic = useTopic();
  const { entryId = '' } = useParams();
  const navigate = useNavigate();
  const { toast } = useToast();
  const base = `/t/${topic.slug}`;

  const entry = useQuery(getEntryOptions({ path: { entry_id: entryId } }));
  const versions = useQuery(listTopicVersionsOptions({ path: { ref: topic.slug } }));
  const update = useUpdateEntry();
  const deleteWithUndo = useDeleteEntryWithUndo();

  const version = useMemo(
    () => versions.data?.find((v) => v.version === entry.data?.version),
    [versions.data, entry.data?.version],
  );

  const prepared = useMemo(() => {
    if (!entry.data || !version) return null;
    const s = entry.data;
    const defaults: EntryFormValues = {
      answers: answerValuesFromEntry(version.questions, s.answers),
      captured_at: toLocalInputValue(new Date(s.captured_at)),
      source: s.source,
      notes: s.notes,
    };
    // What the form shows. A timed entry's time is its run's, edited in the Timing section:
    // an Edit times save changes captured_at, and mustn't reset the form.
    const signature = JSON.stringify({
      ...defaults,
      captured_at: s.timing ? null : defaults.captured_at,
    });
    return {
      defaults,
      signature,
      allowArchived: archivedValuesInEntry(version.questions, s.answers),
    };
  }, [entry.data, version]);

  // The form takes new defaults (a remount) only when what it shows changed on the server
  // and the user hasn't started editing it; otherwise their edits stay.
  const [touched, setTouched] = useState(false);
  const [form, setForm] = useState<{ signature: string | null; generation: number }>({
    signature: null,
    generation: 0,
  });
  if (prepared && prepared.signature !== form.signature && (form.signature === null || !touched)) {
    setForm({ signature: prepared.signature, generation: form.generation + 1 });
  }

  const back = `${base}/entries`;

  if (entry.isPending || versions.isPending) {
    return (
      <>
        <TopBar back={back} title="Edit entry" />
        <PageSpinner />
      </>
    );
  }
  if (entry.isError || versions.isError || !prepared || !version) {
    return (
      <>
        <TopBar back={back} title="Edit entry" />
        <Page>
          <Banner title="Could not load this entry">
            {entry.error
              ? errorMessage(entry.error)
              : versions.error
                ? errorMessage(versions.error)
                : 'Its topic version could not be found.'}
          </Banner>
        </Page>
      </>
    );
  }

  const s = entry.data;
  const outdated = s.version !== topic.current_version;

  return (
    <>
      <TopBar back={back} title="Edit entry" />
      <Page className="mx-auto max-w-2xl">
        <div className="flex flex-wrap items-center gap-2 text-sm text-muted">
          <VersionTag version={s.version} />
          <ChannelBadge channel={s.channel} />
          <span>logged {formatDateTime(s.created_at)}</span>
        </div>
        {outdated ? (
          <Banner tone="info" title={`Logged against version ${s.version}`}>
            Validated with that version’s questions so historic answers stay consistent.
          </Banner>
        ) : null}

        {s.timing ? (
          <TimingSection entry={{ ...s, timing: s.timing }} steps={version.timer?.steps ?? []} />
        ) : null}

        <div
          className="contents"
          onInputCapture={() => setTouched(true)}
          onClickCapture={(e) => {
            if ((e.target as HTMLElement).closest('[id^="answer-"]')) setTouched(true);
          }}
        >
          <EntryForm
            key={`${s.id}-${String(form.generation)}`}
            questions={version.questions}
            defaultValues={prepared.defaults}
            allowArchived={prepared.allowArchived}
            submitLabel="Save changes"
            // A timed entry edits only its notes: its time is the run's and its source the
            // start's (timers.md §11.1); captured_at is hidden and never sent.
            meta={s.timing ? 'notes' : 'all'}
            secondaryAction={({ allowNavigation }) => (
              <Button
                variant="quiet-danger"
                size="lg"
                onClick={() => {
                  // No blocking confirm: the entry vanishes now and an Undo toast holds the
                  // actual DELETE back until it expires. Deleting discards any edits too.
                  allowNavigation();
                  void navigate(back);
                  deleteWithUndo(s, topic);
                }}
                icon={<Icon name="trash" />}
                aria-label="Delete entry"
                className="px-4"
              >
                <span className="hidden sm:inline">Delete</span>
              </Button>
            )}
            onSubmit={async (v, { allowNavigation }) => {
              await update.mutateAsync({
                path: { entry_id: s.id },
                body: {
                  // every key of the version: null clears a previously-set answer
                  answers: v.answers,
                  // A timed entry's captured_at is its run's end: the server refuses a change.
                  ...(s.timing ? {} : { captured_at: v.captured_at }),
                  source: v.source,
                  notes: v.notes,
                },
              });
              toast({ title: 'Entry updated' });
              allowNavigation();
              void navigate(back);
            }}
          />
        </div>
      </Page>
    </>
  );
}
