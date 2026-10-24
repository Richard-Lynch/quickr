from app.schemas.api import FieldIssue


class DomainError(Exception):
    status_code: int = 400
    code: str = "bad_request"

    def __init__(self, detail: str, errors: list[FieldIssue] | None = None) -> None:
        super().__init__(detail)
        self.detail = detail
        self.errors = errors or []

    def describe(self) -> str:
        """Detail plus every field issue, for clients that only see a message (MCP)."""
        if not self.errors:
            return self.detail
        issues = "; ".join(f"{'.'.join(str(p) for p in e.loc)}: {e.message}" for e in self.errors)
        return f"{self.detail}: {issues}"


class NotFound(DomainError):
    status_code = 404
    code = "not_found"


class Conflict(DomainError):
    status_code = 409
    code = "conflict"


class InvalidAnswers(DomainError):
    status_code = 422
    code = "invalid_answers"


class IncompatibleVersion(DomainError):
    status_code = 422
    code = "incompatible_version"


class TopicArchived(DomainError):
    status_code = 409
    code = "topic_archived"


class EntryDeleted(Conflict):
    """The entry id was deleted (or reserved by a delete) and can never be recreated."""

    code = "entry_deleted"


class StaleRevision(Conflict):
    """``expected_revision`` no longer matches: someone else changed the row first."""

    code = "stale_revision"


class ServerMismatch(Conflict):
    """``X-QuickR-Expect-Server-Id`` names another server: nothing was changed."""

    code = "server_mismatch"


class EpochMismatch(Conflict):
    """``X-QuickR-Expect-Epoch`` names an older feed epoch (restore/reset): nothing was changed."""

    code = "epoch_mismatch"


class ApnsDisabled(Conflict):
    """APNs is not configured on this server (``GET /push/config`` says ``apns_enabled: false``)."""

    code = "apns_disabled"


class InvalidRequest(DomainError):
    """A request that is well-formed JSON but breaks a rule the schema can't express."""

    status_code = 422
    code = "invalid_request"


# --- runs (docs/specs/timers.md §3.9) -------------------------------------------------


class TopicNotTimed(Conflict):
    """A ``start`` against a topic version without a ``timer``."""

    code = "topic_not_timed"


class IdConflict(Conflict):
    """Run and entry ids share one id space: a ``start`` with an entry's id, or a ``createEntry``
    with the id of a run that has no entry (open, finishing, discarded) or of an alias."""

    code = "id_conflict"


class EventConflict(Conflict):
    """A run event id was reused with different content."""

    code = "event_conflict"


class RunDeleted(Conflict):
    """The run's topic was deleted: its id is reserved and the run is gone."""

    code = "run_deleted"


class RunOpen(Conflict):
    """A ``finish`` reached a run that hasn't stopped: nothing stored; send the stop first."""

    code = "run_open"


class BeforeStart(DomainError):
    """A ``stop`` with ``at`` before the run's ``started_at``: it would make a negative segment."""

    status_code = 422
    code = "before_start"


class RunTooLong(DomainError):
    """A ``stop`` that would make the run longer than 7 days."""

    status_code = 422
    code = "run_too_long"


class RunTooManyEvents(DomainError):
    """The run already has the maximum number of events (void ones included)."""

    status_code = 422
    code = "run_too_many_events"
