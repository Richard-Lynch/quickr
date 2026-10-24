/**
 * The run context a surface needs to tap a run (`RunContext`): the topic, the run's pinned
 * version, that version's steps and whether it has a required question.
 *
 * Topics don't carry their timer; versions do (`listTopicVersions`, timers.md §2.1). The
 * versions are read by topic id, so a run known only from the server (which names its
 * topic by id) resolves the same way as a tile. Offline with nothing cached, a run's
 * queued items carry the same facts (`LocalRun.steps`).
 */
import { useQuery } from '@tanstack/react-query';

import type { TopicVersionOut } from '../../client';
import { listTopicVersionsOptions } from '../../client/@tanstack/react-query.gen';
import type { RunContext } from '../../lib/runs/actions';
import type { LocalRun } from '../../lib/runs/localView';
import type { Timer } from '../../lib/runs/types';

type TopicRef = RunContext['topic'];

/** Versions change only on publish; tiles share this cache. */
const VERSIONS_STALE_MS = 5 * 60_000;

export function topicVersionsOptions(topicId: string) {
  return { ...listTopicVersionsOptions({ path: { ref: topicId } }), staleTime: VERSIONS_STALE_MS };
}

/** The context for `version` of `topic`, or null when that version isn't timed or isn't known. */
export function contextFor(
  topic: TopicRef,
  versions: readonly TopicVersionOut[] | undefined,
  version: number,
): RunContext | null {
  const v = versions?.find((x) => x.version === version);
  if (!v?.timer) return null;
  return {
    topic,
    version,
    steps: v.timer.steps,
    requires_answers: v.questions.some((q) => q.required),
  };
}

/**
 * A run's context from its own items, when the versions aren't known. Their steps may be
 * unknown too (a run only the server has told us of, or a reminder's Start with nothing
 * cached): the run can still be timed, with no step list and no Skip.
 */
export function contextFromRun(run: LocalRun, topic: TopicRef): RunContext {
  return {
    topic,
    version: run.version,
    steps: run.steps ? [...run.steps] : null,
    requires_answers: run.requires_answers,
  };
}

/**
 * Whether `version` of the topic is timed: its timer, `null` when it isn't timed, or
 * `undefined` while the versions aren't known.
 */
export function timerOf(
  versions: readonly TopicVersionOut[] | undefined,
  version: number,
): Timer | null | undefined {
  const v = versions?.find((x) => x.version === version);
  return v ? v.timer : undefined;
}

/** The topic's versions (by id), for timers and run contexts. */
export function useTopicVersions(topicId: string, enabled = true) {
  return useQuery({ ...topicVersionsOptions(topicId), enabled });
}

/** The context for tapping `run` (its pinned version), or null while it can't be known. */
export function useRunContext(
  run: LocalRun | null | undefined,
  topic: TopicRef | null,
): RunContext | null {
  const versions = useTopicVersions(run?.topic_id ?? '', Boolean(run));
  if (!run || !topic) return null;
  return contextFor(topic, versions.data, run.version) ?? contextFromRun(run, topic);
}
