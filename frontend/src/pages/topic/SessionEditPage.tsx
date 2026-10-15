import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router';

import { errorMessage } from '../../api/errors';
import { invalidateSessionData } from '../../api/queryClient';
import {
  deleteSessionMutation,
  getSessionOptions,
  listTopicVersionsOptions,
  updateSessionMutation,
} from '../../client/@tanstack/react-query.gen';
import { Page, TopBar } from '../../components/AppShell';
import { SessionForm, type SessionFormValues } from '../../components/answers/SessionForm';
import { Button } from '../../components/ui/Button';
import { Badge, Banner, VersionTag } from '../../components/ui/Card';
import { Icon } from '../../components/ui/Icon';
import { ConfirmSheet } from '../../components/ui/Sheet';
import { PageSpinner } from '../../components/ui/Spinner';
import { useToast } from '../../components/ui/Toast';
import { answerValuesFromSession, archivedValuesInSession } from '../../lib/answerSchema';
import { formatDateTime, toLocalInputValue } from '../../lib/dates';
import { useTopic } from './TopicLayout';

export function SessionEditPage() {
  const topic = useTopic();
  const { sessionId = '' } = useParams();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const { toast } = useToast();
  const [confirmDelete, setConfirmDelete] = useState(false);
  const base = `/t/${topic.slug}`;

  const session = useQuery(getSessionOptions({ path: { session_id: sessionId } }));
  const versions = useQuery(listTopicVersionsOptions({ path: { ref: topic.slug } }));
  const update = useMutation(updateSessionMutation());
  const remove = useMutation(deleteSessionMutation());

  const version = useMemo(
    () => versions.data?.find((v) => v.version === session.data?.version),
    [versions.data, session.data?.version],
  );

  const prepared = useMemo(() => {
    if (!session.data || !version) return null;
    const s = session.data;
    const defaults: SessionFormValues = {
      answers: answerValuesFromSession(version.questions, s.answers),
      captured_at: toLocalInputValue(new Date(s.captured_at)),
      source: s.source,
      notes: s.notes,
    };
    return { defaults, allowArchived: archivedValuesInSession(version.questions, s.answers) };
  }, [session.data, version]);

  const back = `${base}/sessions`;

  if (session.isPending || versions.isPending) {
    return (
      <>
        <TopBar back={back} title="Edit entry" />
        <PageSpinner />
      </>
    );
  }
  if (session.isError || versions.isError || !prepared || !version) {
    return (
      <>
        <TopBar back={back} title="Edit entry" />
        <Page>
          <Banner title="Could not load this entry">
            {session.error
              ? errorMessage(session.error)
              : versions.error
                ? errorMessage(versions.error)
                : 'Its topic version could not be found.'}
          </Banner>
        </Page>
      </>
    );
  }

  const s = session.data;
  const outdated = s.version !== topic.current_version;

  return (
    <>
      <TopBar back={back} title="Edit entry" />
      <Page className="mx-auto max-w-2xl">
        <div className="flex flex-wrap items-center gap-2 text-sm text-muted">
          <VersionTag version={s.version} />
          <Badge>{s.channel}</Badge>
          <span>recorded {formatDateTime(s.created_at)}</span>
        </div>
        {outdated ? (
          <Banner tone="info" title={`Recorded against version ${s.version}`}>
            Validated with that version’s questions so historic answers stay consistent.
          </Banner>
        ) : null}

        <SessionForm
          key={s.updated_at}
          questions={version.questions}
          defaultValues={prepared.defaults}
          allowArchived={prepared.allowArchived}
          submitLabel="Save changes"
          secondaryAction={
            <Button
              variant="quiet-danger"
              size="lg"
              onClick={() => setConfirmDelete(true)}
              icon={<Icon name="trash" />}
              aria-label="Delete entry"
              className="px-4"
            >
              <span className="hidden sm:inline">Delete</span>
            </Button>
          }
          onSubmit={async (v) => {
            await update.mutateAsync({
              path: { session_id: s.id },
              body: {
                // every key of the version: null clears a previously-set answer
                answers: v.answers,
                captured_at: v.captured_at,
                source: v.source,
                notes: v.notes,
              },
            });
            await invalidateSessionData(qc);
            toast({ title: 'Entry updated' });
            void navigate(back);
          }}
        />
      </Page>

      <ConfirmSheet
        open={confirmDelete}
        onClose={() => setConfirmDelete(false)}
        title="Delete this entry?"
        body={
          <p>
            This permanently removes the entry from {formatDateTime(s.captured_at)}. It can’t be
            undone.
          </p>
        }
        confirmLabel="Delete entry"
        danger
        busy={remove.isPending}
        onConfirm={() => {
          remove.mutate(
            { path: { session_id: s.id } },
            {
              onSuccess: () => {
                setConfirmDelete(false);
                qc.removeQueries({
                  queryKey: getSessionOptions({ path: { session_id: s.id } }).queryKey,
                });
                void invalidateSessionData(qc);
                toast({ title: 'Entry deleted' });
                void navigate(back);
              },
              onError: (err) =>
                toast({ title: 'Delete failed', description: errorMessage(err), tone: 'danger' }),
            },
          );
        }}
      />
    </>
  );
}
