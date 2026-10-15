"""Rules for safely advancing a topic to a new version.

Questions are identified by ``key`` across the full version history. The rules
guarantee every historic answer stays interpretable and aggregatable:

* a key's type can never change (pick a new key instead);
* enum option values can never be removed (archive them instead);
* everything else (labels, help, constraints, required, order, adding and
  removing questions) is allowed, with warnings where existing data may not
  satisfy the new constraints.
"""

from __future__ import annotations

from collections.abc import Sequence

from app.schemas.api import CompatibilityIssue, CompatibilityReport, QuestionChange
from app.schemas.questions import (
    DoubleQuestion,
    EnumQuestion,
    IntQuestion,
    Question,
    StrQuestion,
)


def _fmt(v: object) -> str:
    return "none" if v is None else str(v)


def _range_tightened(old: IntQuestion | DoubleQuestion, new: IntQuestion | DoubleQuestion) -> bool:
    lower = new.min is not None and (old.min is None or new.min > old.min)
    upper = new.max is not None and (old.max is None or new.max < old.max)
    return lower or upper


def _diff_question(old: Question, new: Question, issues: list[CompatibilityIssue]) -> list[str]:
    details: list[str] = []
    key = new.key
    for attr in ("label", "help_text", "required"):
        a, b = getattr(old, attr), getattr(new, attr)
        if a != b:
            details.append(f"{attr}: {_fmt(a)} -> {_fmt(b)}")
    if not old.required and new.required:
        issues.append(
            CompatibilityIssue(
                level="warning",
                question_key=key,
                message="now required; existing sessions without an answer are kept as-is",
            )
        )

    match old, new:
        case (IntQuestion(), IntQuestion()) | (DoubleQuestion(), DoubleQuestion()):
            for attr in ("min", "max", "unit") + (("decimals",) if isinstance(new, DoubleQuestion) else ()):
                a, b = getattr(old, attr), getattr(new, attr)
                if a != b:
                    details.append(f"{attr}: {_fmt(a)} -> {_fmt(b)}")
            assert isinstance(old, IntQuestion | DoubleQuestion)
            assert isinstance(new, IntQuestion | DoubleQuestion)
            if _range_tightened(old, new):
                issues.append(
                    CompatibilityIssue(
                        level="warning",
                        question_key=key,
                        message="range tightened; historic answers outside it remain valid for their version",
                    )
                )
        case StrQuestion(), StrQuestion():
            for attr in ("min_length", "max_length", "multiline"):
                a, b = getattr(old, attr), getattr(new, attr)
                if a != b:
                    details.append(f"{attr}: {_fmt(a)} -> {_fmt(b)}")
            if new.max_length < old.max_length or new.min_length > old.min_length:
                issues.append(
                    CompatibilityIssue(
                        level="warning",
                        question_key=key,
                        message="length limits tightened; historic answers remain valid for their version",
                    )
                )
        case EnumQuestion(), EnumQuestion():
            old_opts = {o.value: o for o in old.options}
            new_opts = {o.value: o for o in new.options}
            for value in old_opts.keys() - new_opts.keys():
                details.append(f"option removed: {value}")
                issues.append(
                    CompatibilityIssue(
                        level="error",
                        question_key=key,
                        message=f"option '{value}' cannot be removed; archive it instead",
                    )
                )
            for value in new_opts.keys() - old_opts.keys():
                details.append(f"option added: {value}")
            for value in old_opts.keys() & new_opts.keys():
                o, n = old_opts[value], new_opts[value]
                if o.label != n.label:
                    details.append(f"option {value} label: {o.label} -> {n.label}")
                if o.archived != n.archived:
                    details.append(f"option {value} {'archived' if n.archived else 'unarchived'}")
            if [o.value for o in old.options if o.value in new_opts] != [
                o.value for o in new.options if o.value in old_opts
            ]:
                details.append("options reordered")
        case _:
            pass
    return details


def check_compatibility(
    history: Sequence[Sequence[Question]],
    proposed: Sequence[Question],
) -> CompatibilityReport:
    """Compare ``proposed`` against the latest version and all prior versions.

    ``history`` is ordered oldest -> newest and must be non-empty.
    """
    current = history[-1]
    current_by_key = {q.key: q for q in current}
    # Latest definition of every key ever published.
    ever: dict[str, Question] = {}
    for version in history:
        for q in version:
            ever[q.key] = q

    issues: list[CompatibilityIssue] = []
    changes: list[QuestionChange] = []

    for q in proposed:
        prior = ever.get(q.key)
        if prior is not None and prior.type != q.type:
            issues.append(
                CompatibilityIssue(
                    level="error",
                    question_key=q.key,
                    message=f"type cannot change ({prior.type} -> {q.type}); use a new key",
                )
            )
            continue
        if q.key in current_by_key:
            details = _diff_question(current_by_key[q.key], q, issues)
            if details:
                changes.append(QuestionChange(kind="modified", question_key=q.key, details=details))
        elif prior is not None:
            details = _diff_question(prior, q, issues)
            changes.append(QuestionChange(kind="restored", question_key=q.key, details=details))
        else:
            changes.append(QuestionChange(kind="added", question_key=q.key))
            if q.required:
                issues.append(
                    CompatibilityIssue(
                        level="info",
                        question_key=q.key,
                        message="new required question; existing sessions will show it as unanswered",
                    )
                )

    proposed_keys = {q.key for q in proposed}
    for q in current:
        if q.key not in proposed_keys:
            changes.append(QuestionChange(kind="removed", question_key=q.key))
            issues.append(
                CompatibilityIssue(
                    level="warning",
                    question_key=q.key,
                    message="removed from new sessions; historic answers are kept and still aggregated",
                )
            )

    common_old = [q.key for q in current if q.key in proposed_keys]
    common_new = [q.key for q in proposed if q.key in current_by_key]
    if common_old != common_new:
        changes.append(QuestionChange(kind="reordered", question_key="*"))

    if not changes:
        issues.append(CompatibilityIssue(level="error", question_key=None, message="no changes to publish"))

    return CompatibilityReport(
        ok=not any(i.level == "error" for i in issues),
        next_version=len(history) + 1,
        issues=issues,
        changes=changes,
    )
