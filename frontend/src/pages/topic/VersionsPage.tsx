import { useQuery } from '@tanstack/react-query';

import { errorMessage } from '../../api/errors';
import { listTopicVersionsOptions } from '../../client/@tanstack/react-query.gen';
import { QuestionSummaryList } from '../../components/QuestionSummary';
import { ButtonLink } from '../../components/ui/Button';
import { Badge, Banner, Card, VersionTag } from '../../components/ui/Card';
import { Icon } from '../../components/ui/Icon';
import { Skeleton } from '../../components/ui/Spinner';
import { formatDateTime } from '../../lib/dates';
import { plural } from '../../lib/format';
import { useTopic } from './TopicLayout';

export function VersionsPage() {
  const topic = useTopic();
  const versions = useQuery(listTopicVersionsOptions({ path: { ref: topic.slug } }));

  if (versions.isPending) {
    return (
      <div className="flex flex-col gap-3">
        <Skeleton className="h-20 rounded-card" />
        <Skeleton className="h-20 rounded-card" />
      </div>
    );
  }
  if (versions.isError)
    return <Banner title="Could not load versions">{errorMessage(versions.error)}</Banner>;

  const sorted = [...versions.data].sort((a, b) => b.version - a.version);

  return (
    <>
      <div className="flex items-center justify-between gap-3">
        <p className="text-sm text-muted">
          Versions are immutable snapshots. Every entry stays pinned to the version it was recorded
          with.
        </p>
        <ButtonLink
          to={`/t/${topic.slug}/edit`}
          size="sm"
          icon={<Icon name="edit" className="size-4" />}
          className="shrink-0"
        >
          New version
        </ButtonLink>
      </div>
      <ol className="relative flex flex-col gap-3 before:absolute before:top-4 before:bottom-4 before:left-[1.4rem] before:w-px before:bg-line-strong">
        {sorted.map((v) => {
          const current = v.version === topic.current_version;
          return (
            <li key={v.version} className="relative pl-12">
              <span
                className={
                  current
                    ? 'absolute top-4 left-[1.05rem] size-3 rounded-full bg-accent ring-4 ring-paper'
                    : 'absolute top-4 left-[1.05rem] size-3 rounded-full border-2 border-line-strong bg-paper ring-4 ring-paper'
                }
              />
              <Card>
                <details className="group" open={current}>
                  <summary className="flex min-h-14 cursor-pointer list-none flex-wrap items-center gap-x-3 gap-y-1 px-4 py-3">
                    <VersionTag version={v.version} />
                    {current ? <Badge tone="accent">current</Badge> : null}
                    <span className="text-sm text-muted">{formatDateTime(v.created_at)}</span>
                    <span className="ml-auto flex items-center gap-2 text-sm">
                      <span className="font-mono tabular">
                        {plural(v.entry_count, 'entry', 'entries')}
                      </span>
                      <Icon
                        name="chevronDown"
                        className="size-4 text-muted transition-transform group-open:rotate-180"
                      />
                    </span>
                    <p className="basis-full text-[0.95rem]">
                      {v.change_note || (
                        <span className="text-muted italic">
                          {v.version === 1 ? 'Initial version' : 'No change note'}
                        </span>
                      )}
                    </p>
                  </summary>
                  <div className="border-t border-line px-4 pb-2">
                    <QuestionSummaryList questions={v.questions} />
                  </div>
                </details>
              </Card>
            </li>
          );
        })}
      </ol>
    </>
  );
}
