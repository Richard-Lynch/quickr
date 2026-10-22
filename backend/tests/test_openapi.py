"""OpenAPI spec generation and drift against the committed ../openapi.json."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from app.main import app

SPEC_PATH = Path(__file__).resolve().parents[2] / "openapi.json"
METHODS = {"get", "post", "put", "patch", "delete"}


def spec() -> dict[str, Any]:
    generated: dict[str, Any] = app.openapi()
    return generated


def test_spec_generates() -> None:
    s = spec()
    assert s["openapi"].startswith("3.")
    assert s["info"]["title"] == "quickR API"
    assert "/api/v1/topics" in s["paths"]


def test_every_operation_has_unique_operation_id() -> None:
    ids = [
        op.get("operationId")
        for item in spec()["paths"].values()
        for method, op in item.items()
        if method in METHODS
    ]
    assert ids
    assert all(ids), "every operation needs an operationId"
    assert len(ids) == len(set(ids))


def test_committed_spec_matches() -> None:
    committed = json.loads(SPEC_PATH.read_text())
    # Round-trip through JSON so the comparison matches the exported file exactly.
    assert committed == json.loads(json.dumps(spec())), (
        "openapi.json is stale; run `PYTHONPATH=. uv run python scripts/export_openapi.py`"
    )


def _answers_map(schema: dict[str, Any]) -> dict[str, Any]:
    if "anyOf" in schema:  # optional on update: anyOf [map, null]
        (schema,) = (s for s in schema["anyOf"] if s.get("type") == "object")
    return schema


def test_answers_map_uses_additional_properties() -> None:
    """Swift's generator drops patternProperties, so the answers map is spelled out explicitly."""
    schemas = spec()["components"]["schemas"]
    for model in ("EntryCreate", "EntryUpdate"):
        answers = _answers_map(schemas[model]["properties"]["answers"])
        assert answers["type"] == "object"
        assert "patternProperties" not in answers
        assert answers["propertyNames"] == {"pattern": "^[a-z][a-z0-9_]{0,62}$"}
        assert answers["additionalProperties"] == {
            "anyOf": [
                {"type": "number"},
                {"type": "string"},
                {"type": "array", "items": {"type": "string"}},
                {"type": "null"},
            ]
        }
        assert answers["description"].startswith("Map of question key")
