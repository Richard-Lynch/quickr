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
