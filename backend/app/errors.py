from app.schemas.api import FieldIssue


class DomainError(Exception):
    status_code: int = 400
    code: str = "bad_request"

    def __init__(self, detail: str, errors: list[FieldIssue] | None = None) -> None:
        super().__init__(detail)
        self.detail = detail
        self.errors = errors or []


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
