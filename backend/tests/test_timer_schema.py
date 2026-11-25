"""Timer config v2 (docs/specs/timers2.md §1, T28): lap types, variables and alerts.

Every §1.3 validation rule with its dotted path, the v1 shape in input and stored context, the
normalised output (``[]`` defaults, ``at_ms`` filled, names lowercase), the ``GET /limits`` rows
of §1.2, and the HTTP surfaces that carry a timer.
"""

from __future__ import annotations

from typing import Any

import httpx
import pytest
from pydantic import ValidationError
from sqlalchemy import update
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import TopicVersion
from app.schemas import limits
from app.schemas.base import issues_from
from app.schemas.questions import Timer
from app.services import timer_expr
from app.services.topics import parse_timer
from tests.helpers import make_topic

WEEK_MS = 7 * 24 * 3_600_000


def step(key: str = "work", label: str = "Work", **extra: Any) -> dict[str, Any]:
    return {"key": key, "label": label, **extra}


def lap(key: str = "run", label: str = "Run", **extra: Any) -> dict[str, Any]:
    return {"key": key, "label": label, **extra}


def alert(at: str = "t/2", key: str = "half", label: str = "Half", **extra: Any) -> dict[str, Any]:
    return {"key": key, "label": label, "at": at, **extra}


def var(name: str = "t", ms: Any = 60_000) -> dict[str, Any]:
    return {"name": name, "ms": ms}


def errors(timer: dict[str, Any], *, stored: bool = False) -> dict[str, str]:
    """Dotted path -> message for every place ``Timer`` rejects ``timer``; {} = accepted."""
    try:
        Timer.model_validate(timer, context={"stored": True} if stored else None)
    except ValidationError as exc:
        return {".".join(str(p) for p in i.loc): i.message for i in issues_from(exc)}
    return {}


def paths(timer: dict[str, Any]) -> list[str]:
    return sorted(errors(timer))


def normalised(timer: dict[str, Any], *, stored: bool = False) -> dict[str, Any]:
    out: dict[str, Any] = Timer.model_validate(
        timer, context={"stored": True} if stored else None
    ).model_dump(mode="json")
    return out


# --- the v1 shape and normalisation (§1.4) ----------------------------------------------------


@pytest.mark.parametrize("stored", [False, True])
def test_v1_shape_is_accepted_and_normalised(stored: bool) -> None:
    v1 = {"steps": [step("load", "Load"), step("rinse", "Rinse")]}
    assert normalised(v1, stored=stored) == {
        "steps": [
            {"key": "load", "label": "Load", "alerts": []},
            {"key": "rinse", "label": "Rinse", "alerts": []},
        ],
        "laps": [],
        "variables": [],
    }
    assert normalised({"steps": []}, stored=stored) == {"steps": [], "laps": [], "variables": []}


def test_output_is_normalised_with_at_ms_and_lowercase_names() -> None:
    timer = {
        "steps": [step(alerts=[alert("(T/2)+30s", "mid", "Mid")])],
        "laps": [
            lap("run", "Run", alerts=[alert("T/2"), alert("T", "full", "Full")]),
            lap("rest", "Rest"),
        ],
        "variables": [var("T", 60_000), var("Rest", 30_000)],
    }
    assert normalised(timer) == {
        "steps": [
            {
                "key": "work",
                "label": "Work",
                "alerts": [{"key": "mid", "label": "Mid", "at": "(T/2)+30s", "at_ms": 60_000}],
            }
        ],
        "laps": [
            {
                "key": "run",
                "label": "Run",
                "alerts": [
                    {"key": "half", "label": "Half", "at": "T/2", "at_ms": 30_000},
                    {"key": "full", "label": "Full", "at": "T", "at_ms": 60_000},
                ],
            },
            {"key": "rest", "label": "Rest", "alerts": []},
        ],
        "variables": [{"name": "t", "ms": 60_000}, {"name": "rest", "ms": 30_000}],
    }


def test_a_sent_at_ms_is_ignored_and_recomputed() -> None:
    timer = {"steps": [], "laps": [lap(alerts=[alert("t/2", at_ms=1)])], "variables": [var()]}
    assert normalised(timer)["laps"][0]["alerts"][0]["at_ms"] == 30_000
    timer["laps"][0]["alerts"][0]["at_ms"] = "anything"
    assert normalised(timer)["laps"][0]["alerts"][0]["at_ms"] == 30_000


def test_normalised_output_parses_back_to_itself() -> None:
    timer = {"steps": [step(alerts=[alert("30s")])], "laps": [lap()], "variables": [var("T")]}
    once = normalised(timer)
    assert normalised(once) == once
    assert normalised(once, stored=True) == once


def test_alerts_on_steps_and_lap_types_share_the_schema() -> None:
    """``alert-on-step``: a step's alerts evaluate like a lap type's (OQ-4)."""
    timer = {"steps": [step(alerts=[alert("1.5m")])], "laps": [lap(alerts=[alert("1.5m")])]}
    out = normalised(timer)
    assert out["steps"][0]["alerts"] == out["laps"][0]["alerts"]
    assert out["steps"][0]["alerts"][0]["at_ms"] == 90_000


# --- §1.3 rules, in table order -----------------------------------------------------------------


def test_counts() -> None:
    steps = [step(f"s{i}", f"S {i}") for i in range(30)]
    laps = [lap(f"l{i}", f"L {i}") for i in range(8)]
    variables = [var(f"v{i}") for i in range(16)]
    assert errors({"steps": steps, "laps": laps, "variables": variables}) == {}  # laps-max, variables-max
    assert paths({"steps": [*steps, step("s30", "S 30")]}) == ["steps"]
    assert paths({"steps": [], "laps": [*laps, lap("l8", "L 8")]}) == ["laps"]  # laps-too-many
    assert paths({"steps": [], "variables": [*variables, var("v16")]}) == ["variables"]  # variables-too-many


def test_one_and_two_lap_types() -> None:
    assert errors({"steps": [], "laps": [lap("cig", "Cig")]}) == {}  # laps-one-type
    assert errors({"steps": [], "laps": [lap("run", "Run"), lap("rest", "Rest")]}) == {}  # laps-two-types


@pytest.mark.parametrize("key", ["Run", "1run", "run-1", "", "x" * 64])
def test_lap_key_pattern(key: str) -> None:
    assert paths({"steps": [], "laps": [lap(), lap(key)]}) == ["laps.1.key"]


def test_keys_share_one_namespace_across_steps_and_lap_types() -> None:
    """``lap-key-collides-with-step``: reported at the lap type, naming the step."""
    timer = {"steps": [step("work"), step("cool", "Cool")], "laps": [lap("run"), lap("rest"), lap("work")]}
    assert errors(timer) == {"laps.2.key": "duplicate key 'work' (also a step)"}
    timer = {"steps": [], "laps": [lap("run"), lap("run", "Again")]}
    assert errors(timer) == {"laps.1.key": "duplicate lap type key 'run'"}
    timer = {"steps": [step("a"), step("a", "Again")]}
    assert errors(timer) == {"steps.1.key": "duplicate step key 'a'"}


def test_lap_keys_are_independent_of_question_and_variable_names() -> None:
    timer = {"steps": [], "laps": [lap("t")], "variables": [var("t")]}
    assert errors(timer) == {}


def test_lap_label_is_a_short_label() -> None:
    assert errors({"steps": [], "laps": [lap(label="x" * 64)]}) == {}
    assert paths({"steps": [], "laps": [lap(label="x" * 65)]}) == ["laps.0.label"]  # lap-label-65
    assert paths({"steps": [], "laps": [lap(label="")]}) == ["laps.0.label"]
    assert paths({"steps": [], "laps": [lap(label="   ")]}) == ["laps.0.label"]


def test_variable_names_are_lowercased_then_checked() -> None:
    # variable-name-uppercase-normalised
    assert normalised({"steps": [], "variables": [var("Work_1")]})["variables"] == [
        {"name": "work_1", "ms": 60_000}
    ]
    assert errors({"steps": [], "variables": [var("x" * 16)]}) == {}
    for bad in ["1t", "_t", "t-1", "", "x" * 17, "té"]:
        assert paths({"steps": [], "variables": [var(bad)]}) == ["variables.0.name"], bad


@pytest.mark.parametrize("unit", ["ms", "s", "m", "h", "M", "MS"])
def test_unit_names_are_reserved(unit: str) -> None:
    """``variable-name-reserved-unit``: ``2m`` and ``2*m`` must not read alike."""
    assert paths({"steps": [], "variables": [var("t"), var(unit)]}) == ["variables.1.name"]
    assert "unit" in errors({"steps": [], "variables": [var(unit)]})["variables.0.name"]


def test_variable_names_are_unique_case_insensitively() -> None:
    """``variable-name-duplicate-case``."""
    timer = {"steps": [], "variables": [var("t"), var("rest"), var("T")]}
    assert errors(timer) == {"variables.2.name": "duplicate variable name 't'"}


def test_variable_ms_bounds() -> None:
    assert errors({"steps": [], "variables": [var(ms=0), var("u", WEEK_MS)]}) == {}
    assert paths({"steps": [], "variables": [var(ms=-1)]}) == ["variables.0.ms"]  # variable-ms-negative
    assert paths({"steps": [], "variables": [var(ms=WEEK_MS + 1)]}) == [
        "variables.0.ms"
    ]  # variable-ms-over-7d
    for bad in [1.5, "60000", True, None]:
        assert paths({"steps": [], "variables": [var(ms=bad)]}) == ["variables.0.ms"], bad


@pytest.mark.parametrize("owner", ["steps", "laps"])
def test_alert_count(owner: str) -> None:
    def timer(n: int) -> dict[str, Any]:
        owners = {"steps": [], "laps": []}
        owners[owner] = [{"key": "a", "label": "A", "alerts": [alert("30s", f"k{i}") for i in range(n)]}]
        return owners

    assert errors(timer(8)) == {}  # alerts-max
    assert paths(timer(9)) == [f"{owner}.0.alerts"]  # alerts-too-many


@pytest.mark.parametrize("owner", ["steps", "laps"])
def test_alert_keys_are_unique_within_their_owner(owner: str) -> None:
    """``alert-key-duplicate``; the same key on another owner, or equal to a step key, is fine."""
    alerts = [alert("30s", "a"), alert("1m", "b"), alert("2m", "a")]
    timer = {"steps": [], "laps": [], owner: [{"key": "x", "label": "X", "alerts": alerts}]}
    assert errors(timer) == {f"{owner}.0.alerts.2.key": "duplicate alert key 'a'"}
    shared = [alert("30s", "x")]
    timer = {"steps": [step("x", alerts=shared)], "laps": [lap("y", alerts=shared)]}
    assert errors(timer) == {}
    assert paths({"steps": [], "laps": [lap(alerts=[alert("30s", "Bad")])]}) == ["laps.0.alerts.0.key"]


def test_alert_label_is_a_short_label() -> None:
    assert errors({"steps": [step(alerts=[alert("30s", label="x" * 64)])]}) == {}
    assert paths({"steps": [step(alerts=[alert("30s", label="x" * 65)])]}) == ["steps.0.alerts.0.label"]
    assert paths({"steps": [step(alerts=[alert("30s", label="")])]}) == ["steps.0.alerts.0.label"]


@pytest.mark.parametrize(
    ("at", "code", "pos"),
    [
        ("t+", "syntax", 2),  # alert-expr-syntax
        ("x/2", "unknown_variable", 0),  # alert-expr-unknown-variable
        ("t+30", "type", 1),  # alert-expr-type
        ("30", "type", 0),
        ("t/0", "div_zero", 1),
        ("-t", "negative", 0),
        ("t*20000", "too_long", 0),
        ("30d", "syntax", 2),
    ],
)
def test_alert_expression_is_evaluated_against_the_timers_variables(at: str, code: str, pos: int) -> None:
    timer = {"steps": [], "laps": [lap(), lap("rest", "Rest", alerts=[alert(at)])], "variables": [var()]}
    message = errors(timer)["laps.1.alerts.0.at"]
    assert list(errors(timer)) == ["laps.1.alerts.0.at"]
    assert message.startswith(f"{code} at {pos}: ")
    with pytest.raises(timer_expr.ExprError) as exc:
        timer_expr.evaluate(at, {"t": 60_000})
    assert message == str(exc.value)


def test_alert_expression_length() -> None:
    """``alert-expr-65-chars``: 1..64 characters (``max_expr_length``), then evaluated."""
    at_64 = "1s" + "+1s" * 20 + "*1"  # 21 seconds
    assert len(at_64) == 64
    out = normalised({"steps": [step(alerts=[alert(at_64)])]})
    assert out["steps"][0]["alerts"][0]["at_ms"] == 21_000
    assert paths({"steps": [step(alerts=[alert(at_64 + "1")])]}) == ["steps.0.alerts.0.at"]
    assert paths({"steps": [step(alerts=[alert("")])]}) == ["steps.0.alerts.0.at"]
    assert paths({"steps": [step(alerts=[alert("   ")])]}) == ["steps.0.alerts.0.at"]


def test_variables_are_matched_case_insensitively_in_expressions() -> None:
    """The user's spelling: ``T/2`` with ``T = 60s``, declared as ``t`` or ``T``."""
    for name in ("t", "T"):
        out = normalised({"steps": [], "laps": [lap(alerts=[alert("T/2")])], "variables": [var(name)]})
        assert out["laps"][0]["alerts"][0]["at_ms"] == 30_000


def test_an_expression_sees_only_its_own_timers_variables() -> None:
    assert paths({"steps": [step(alerts=[alert("t/2")])]}) == ["steps.0.alerts.0.at"]


def test_unknown_fields_are_rejected() -> None:
    assert paths({"steps": [], "laps": [lap(colour="red")]}) == ["laps.0.colour"]
    assert paths({"steps": [], "variables": [{**var(), "unit": "s"}]}) == ["variables.0.unit"]
    assert paths({"steps": [step(alerts=[alert(sound="beep")])]}) == ["steps.0.alerts.0.sound"]
    assert paths({"steps": [], "laps": None}) == ["laps"]


def test_errors_in_several_places_are_all_reported() -> None:
    timer = {"steps": [], "laps": [lap(label="x" * 65), lap("Bad")], "variables": [var(ms=-1)]}
    assert paths(timer) == ["laps.0.label", "laps.1.key", "variables.0.ms"]


# --- limits (§1.2) ------------------------------------------------------------------------------


NEW_LIMITS = {
    "max_steps": 30,
    "max_lap_types": 8,
    "max_variables": 16,
    "max_alerts": 8,
    "max_expr_length": 64,
    "max_var_name_length": 16,
    "max_short_label_length": 64,
}


def test_limit_constants() -> None:
    assert limits.MAX_STEPS == 30
    assert limits.MAX_LAP_TYPES == 8
    assert limits.MAX_VARIABLES == 16
    assert limits.MAX_ALERTS == 8
    assert limits.MAX_EXPR_LENGTH == timer_expr.MAX_LENGTH == 64
    assert limits.MAX_VAR_NAME_LENGTH == 16
    assert limits.MAX_SHORT_LABEL_LENGTH == 64
    assert limits.MAX_VARIABLE_MS == timer_expr.MAX_MS == WEEK_MS


async def test_get_limits_carries_the_new_rows(client: httpx.AsyncClient) -> None:
    r = await client.get("/limits")
    assert r.status_code == 200
    body = r.json()
    assert {k: body[k] for k in NEW_LIMITS} == NEW_LIMITS


# --- over HTTP ----------------------------------------------------------------------------------


V2 = {
    "steps": [{"key": "warm", "label": "Warm up", "alerts": [{"key": "go", "label": "Go", "at": "rest"}]}],
    "laps": [
        {"key": "run", "label": "Run", "alerts": [{"key": "half", "label": "Half", "at": "t/2"}]},
        {"key": "rest", "label": "Rest"},
    ],
    "variables": [{"name": "T", "ms": 60_000}, {"name": "rest", "ms": 30_000}],
}
V2_OUT = {
    "steps": [
        {
            "key": "warm",
            "label": "Warm up",
            "alerts": [{"key": "go", "label": "Go", "at": "rest", "at_ms": 30_000}],
        }
    ],
    "laps": [
        {
            "key": "run",
            "label": "Run",
            "alerts": [{"key": "half", "label": "Half", "at": "t/2", "at_ms": 30_000}],
        },
        {"key": "rest", "label": "Rest", "alerts": []},
    ],
    "variables": [{"name": "t", "ms": 60_000}, {"name": "rest", "ms": 30_000}],
}


async def test_create_and_read_a_v2_timer(client: httpx.AsyncClient) -> None:
    created = await make_topic(client, "Intervals", questions=[], timer=V2)
    assert created["timer"] == V2_OUT
    assert (await client.get("/topics/intervals")).json()["timer"] == V2_OUT
    assert [t["timer"] for t in (await client.get("/topics")).json()["items"]] == [V2_OUT]
    assert [v["timer"] for v in (await client.get("/topics/intervals/versions")).json()] == [V2_OUT]
    feed = (await client.get("/changes")).json()["items"]
    timers = [i["topic"]["timer"] if i["kind"] == "topic" else i["version"]["timer"] for i in feed]
    assert timers == [V2_OUT, V2_OUT]


async def test_publish_and_check_accept_v2(client: httpx.AsyncClient) -> None:
    await make_topic(client, "Intervals", questions=[], timer={"steps": []})
    check = await client.post("/topics/intervals/versions/check", json={"questions": [], "timer": V2})
    assert (check.status_code, check.json()["ok"]) == (200, True)
    body = {"questions": [], "base_version": 1, "timer": V2}
    r = await client.post("/topics/intervals/versions", json=body)
    assert r.status_code == 201, r.text
    assert r.json()["timer"] == V2_OUT
    # The same timer again (sent normalised or not) is no change.
    for timer in (V2, V2_OUT):
        r = await client.post("/topics/intervals/versions", json={**body, "base_version": 2, "timer": timer})
        assert (r.status_code, r.json()["detail"]) == (422, "no changes to publish")


@pytest.mark.parametrize(
    ("timer", "loc"),
    [
        ({**V2, "laps": [*V2["laps"], {"key": "warm", "label": "Warm"}]}, ["laps", 2, "key"]),
        (
            {
                **V2,
                "laps": [
                    V2["laps"][0],
                    {"key": "rest", "label": "Rest", "alerts": [{"key": "a", "label": "A", "at": "x"}]},
                ],
            },
            ["laps", 1, "alerts", 0, "at"],
        ),
        ({**V2, "variables": [{"name": "s", "ms": 1}]}, ["variables", 0, "name"]),
    ],
)
async def test_422_paths(client: httpx.AsyncClient, timer: dict[str, Any], loc: list[Any]) -> None:
    r = await client.post("/topics", json={"name": "Bad", "questions": [], "timer": timer})
    assert r.status_code == 422
    assert r.json()["code"] == "invalid_request"
    assert [e["loc"] for e in r.json()["errors"]] == [["body", "timer", *loc]]
    await make_topic(client, "Good", questions=[], timer={"steps": []})
    r = await client.post("/topics/good/versions", json={"questions": [], "base_version": 1, "timer": timer})
    assert [e["loc"] for e in r.json()["errors"]] == [["body", "timer", *loc]]


async def test_a_stored_v1_timer_reads_back_as_v2(client: httpx.AsyncClient, db: AsyncSession) -> None:
    """No data migration of ``topic_versions.timer``: a v1 row parses with the defaults, and
    resending it unchanged is no change to publish."""
    v1 = {"steps": [{"key": "load", "label": "Load"}]}
    await make_topic(client, "Dishwasher", questions=[], timer=v1)
    await db.execute(update(TopicVersion).values(timer=v1))  # as a v1 server stored it
    await db.commit()
    out = {"steps": [{"key": "load", "label": "Load", "alerts": []}], "laps": [], "variables": []}
    assert (await client.get("/topics/dishwasher")).json()["timer"] == out
    assert [v["timer"] for v in (await client.get("/topics/dishwasher/versions")).json()] == [out]
    r = await client.post(
        "/topics/dishwasher/versions", json={"questions": [], "base_version": 1, "timer": v1}
    )
    assert (r.status_code, r.json()["detail"]) == (422, "no changes to publish")
    check = await client.post("/topics/dishwasher/versions/check", json={"questions": [], "timer": out})
    assert check.json()["ok"] is False


def test_parse_timer_of_a_v1_row() -> None:
    timer = parse_timer({"steps": [{"key": "a", "label": "A"}]})
    assert timer is not None
    assert timer.model_dump(mode="json") == {
        "steps": [{"key": "a", "label": "A", "alerts": []}],
        "laps": [],
        "variables": [],
    }
