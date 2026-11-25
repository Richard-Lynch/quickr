"""Alert expression vectors: ``shared/fixtures/timer-expr-vectors.json``.

Generated from ``app/services/timer_expr.py`` (docs/specs/timers2.md §2), the reference
implementation of the alert expression grammar: an expression and its variables in, the whole
milliseconds or ``{error, pos}`` out. The PWA (``timerExpr.ts``) and the iOS app
(``TimerExpr.swift``) replay the same cases and must answer the same, ``pos`` included (spec
test T29). ``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites the file; otherwise the
committed file must match.
"""

from __future__ import annotations

from typing import Any

from app.services.timer_expr import MAX_LENGTH, MAX_MS, ExprError, evaluate

from tests.vectors import FIXTURES_DIR, check_or_write, dump_cases

PATH = FIXTURES_DIR / "timer-expr-vectors.json"
GENERATOR_VERSION = 1

T = {"t": 60_000}
HOUR = {"t": 3_600_000}
NONE: dict[str, int] = {}

# name -> (expression, variables)
CASES: dict[str, tuple[str, dict[str, int]]] = {
    "plain_seconds": ("30s", NONE),
    "minutes_fraction": ("1.5m", NONE),
    "hours": ("1h", NONE),
    "ms_unit": ("1500ms", NONE),
    "user_half": ("t*0.5", T),
    "user_half_spaced": ("t * 0.5", T),
    "user_alert1_uppercase": ("T/2", T),
    "user_alert2_uppercase": ("T", T),
    "user_div": ("t/2", T),
    "user_plus": ("t+30s", T),
    "user_parens": ("(t/2)+30s", T),
    "user_alert2": ("t", T),
    "precedence_mul_before_add": ("t+2*10s", T),
    "precedence_parens": ("(t+10s)*2", T),
    "left_assoc_minus": ("t-10s-10s", T),
    "number_times_duration": ("2*t", T),
    "division_truncates": ("t/3", {"t": 1_000}),
    "fractional_ms_truncates": ("0.0015s", NONE),
    "unary_minus_double": ("--t", T),
    "unary_minus_negative": ("-t", T),
    "case_insensitive_variable": ("T/2", T),
    "unit_uppercase_is_syntax": ("30S", NONE),
    "whitespace_ignored": ("t + 30s", T),
    "bare_number": ("30", NONE),
    "duration_plus_number": ("t+30", T),
    "duration_times_duration": ("t*t", T),
    "number_div_duration": ("2/t", T),
    "unknown_variable": ("x/2", T),
    "div_zero": ("t/0", T),
    "div_zero_expression": ("t/(1-1)", T),
    "too_long_text": ("+".join(["t"] * 33), T),
    "too_long_value": ("t*2000", HOUR),
    "too_long_intermediate": ("t*10000-t*10000", HOUR),
    "syntax_trailing": ("t+", T),
    "syntax_unknown_unit": ("30d", NONE),
    "syntax_space_before_unit": ("30 s", NONE),
    "syntax_empty": ("", NONE),
    "nested_parens": ("((t))", T),
    "two_variables": ("work+rest", {"work": 1_500_000, "rest": 300_000}),
    "zero_allowed": ("t-t", T),
}

# The "at least" list of timers2.md §2.5, in its order; every name must be a case above.
SPEC_CASES = [
    "plain_seconds",
    "minutes_fraction",
    "hours",
    "ms_unit",
    "user_half",
    "user_half_spaced",
    "user_alert1_uppercase",
    "user_alert2_uppercase",
    "user_div",
    "user_plus",
    "user_parens",
    "user_alert2",
    "precedence_mul_before_add",
    "precedence_parens",
    "left_assoc_minus",
    "number_times_duration",
    "division_truncates",
    "fractional_ms_truncates",
    "unary_minus_double",
    "unary_minus_negative",
    "case_insensitive_variable",
    "unit_uppercase_is_syntax",
    "whitespace_ignored",
    "bare_number",
    "duration_plus_number",
    "duration_times_duration",
    "number_div_duration",
    "unknown_variable",
    "div_zero",
    "div_zero_expression",
    "too_long_text",
    "too_long_value",
    "too_long_intermediate",
    "syntax_trailing",
    "syntax_unknown_unit",
    "syntax_space_before_unit",
    "syntax_empty",
    "nested_parens",
    "two_variables",
    "zero_allowed",
]


def outcome(name: str) -> dict[str, Any]:
    text, variables = CASES[name]
    try:
        return {"ms": evaluate(text, variables)}
    except ExprError as e:
        return {"error": e.code, "pos": e.pos}


def build() -> dict[str, Any]:
    return {
        "meta": {
            "generator": "backend/tests/test_timer_expr_vectors.py",
            "generator_version": GENERATOR_VERSION,
            "max_ms": MAX_MS,
            "max_length": MAX_LENGTH,
            "semantics": [
                "docs/specs/timers2.md §2. expr := term {('+'|'-') term}; term := factor {('*'|'/') "
                "factor}; factor := duration | number | ident | '(' expr ')' | '-' factor; "
                "duration := number unit; unit := 'ms' | 's' | 'm' | 'h'; number := digit {digit} "
                "['.' digit {digit}]; ident := letter {letter | digit | '_'}. Whitespace between "
                "tokens is ignored; tokens match longest-first (ms before m); a unit follows its "
                "number without a space; units are lowercase only.",
                "Two types: number and duration (ms). Variables are durations, matched "
                "case-insensitively by name. duration +- duration, duration * number, number * "
                "duration, duration / number, number op number and unary minus are allowed; "
                "anything else is a type error at the operator. The whole expression must be a "
                "duration (a bare number is type at 0), >= 0 (negative at 0) and <= max_ms "
                "(too_long at 0, also for any intermediate duration).",
                "Numbers and durations are IEEE doubles; a unit literal is number * factor "
                "(1, 1000, 60000, 3600000); the same operations in the same order on every "
                "platform; intermediates are never rounded; the result is truncated toward zero "
                "to whole ms.",
                "expected is {ms} or {error, pos}; pos is the 0-based character offset of the "
                "token the error is reported at: syntax at the offending character (end of input "
                "for an unexpected end), unknown_variable at the identifier, type and div_zero "
                "at the operator, negative at 0, too_long at max_length for text longer than "
                "max_length (checked first) and at 0 for a value.",
            ],
        },
        "cases": [
            {"name": name, "expr": text, "variables": variables, "expected": outcome(name)}
            for name, (text, variables) in CASES.items()
        ],
    }


def test_timer_expr_vectors_match_committed() -> None:
    check_or_write(PATH, dump_cases(build()))


def test_vectors_cover_the_spec() -> None:
    """timers2.md §2.5: every listed case is generated, with the outcomes the list states."""
    missing = [name for name in SPEC_CASES if name not in CASES]
    assert missing == []
    assert len(CASES["too_long_text"][0]) == 65
    assert outcome("minutes_fraction") == {"ms": 90_000}
    assert outcome("user_half") == {"ms": 30_000}
    assert outcome("user_alert1_uppercase") == {"ms": 30_000}
    assert outcome("user_alert2_uppercase") == {"ms": 60_000}
    assert outcome("user_plus") == {"ms": 90_000}
    assert outcome("user_parens") == {"ms": 60_000}
    assert outcome("user_alert2") == {"ms": 60_000}
    assert outcome("division_truncates") == {"ms": 333}
    assert outcome("fractional_ms_truncates") == {"ms": 1}
    assert outcome("unary_minus_negative") == {"error": "negative", "pos": 0}
    assert outcome("unit_uppercase_is_syntax") == {"error": "syntax", "pos": 2}
    assert outcome("bare_number") == {"error": "type", "pos": 0}
    assert outcome("duration_plus_number") == {"error": "type", "pos": 1}
    assert outcome("duration_times_duration") == {"error": "type", "pos": 1}
    assert outcome("number_div_duration") == {"error": "type", "pos": 1}
    assert outcome("unknown_variable") == {"error": "unknown_variable", "pos": 0}
    assert outcome("too_long_text") == {"error": "too_long", "pos": 64}
    assert outcome("zero_allowed") == {"ms": 0}
    # The rest of the list, with the outcomes §2.1 to §2.4 imply.
    assert outcome("plain_seconds") == {"ms": 30_000}
    assert outcome("hours") == {"ms": 3_600_000}
    assert outcome("ms_unit") == {"ms": 1_500}
    assert outcome("user_half_spaced") == {"ms": 30_000}
    assert outcome("user_div") == {"ms": 30_000}
    assert outcome("precedence_mul_before_add") == {"ms": 80_000}
    assert outcome("precedence_parens") == {"ms": 140_000}
    assert outcome("left_assoc_minus") == {"ms": 40_000}
    assert outcome("number_times_duration") == {"ms": 120_000}
    assert outcome("unary_minus_double") == {"ms": 60_000}
    assert outcome("case_insensitive_variable") == {"ms": 30_000}
    assert outcome("whitespace_ignored") == {"ms": 90_000}
    assert outcome("div_zero") == {"error": "div_zero", "pos": 1}
    assert outcome("div_zero_expression") == {"error": "div_zero", "pos": 1}
    assert outcome("too_long_value") == {"error": "too_long", "pos": 0}
    assert outcome("too_long_intermediate") == {"error": "too_long", "pos": 0}
    assert outcome("syntax_trailing") == {"error": "syntax", "pos": 2}
    assert outcome("syntax_unknown_unit") == {"error": "syntax", "pos": 2}
    assert outcome("syntax_space_before_unit") == {"error": "syntax", "pos": 3}
    assert outcome("syntax_empty") == {"error": "syntax", "pos": 0}
    assert outcome("nested_parens") == {"ms": 60_000}
    assert outcome("two_variables") == {"ms": 1_800_000}


def test_every_case_is_a_duration_or_a_spec_error() -> None:
    codes = {"syntax", "unknown_variable", "type", "negative", "too_long", "div_zero"}
    for name in CASES:
        got = outcome(name)
        if "ms" in got:
            assert 0 <= got["ms"] <= MAX_MS, name
        else:
            assert got["error"] in codes, name
            assert 0 <= got["pos"] <= max(len(CASES[name][0]), MAX_LENGTH), name
