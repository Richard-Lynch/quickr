"""Alert expression vectors: ``shared/fixtures/timer-expr-vectors.json``.

Generated from ``app/services/timer_expr.py`` (docs/specs/timers2.md §2), the reference
implementation of the alert expression grammar: an expression and its variables in, the whole
milliseconds or ``{error, pos}`` out. The PWA (``timerExpr.ts``) and the iOS app
(``TimerExpr.swift``) replay the same cases and must answer the same, ``pos`` included (spec
test T29). ``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites the file; otherwise the
committed file must match.
"""

from __future__ import annotations

import re
from pathlib import Path
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

# Clarifications of §2 the spec leaves open, pinned so the ports answer the same (proposed for
# timers2.md §2.3/§2.4 in the M1-EXPR PR).
CASES |= {
    # The whole text parses before anything evaluates: a syntax error wins over the rest.
    "syntax_before_evaluation": ("x+", T),
    # Then the first error in evaluation order: operands left to right, then the operator.
    "first_error_in_evaluation_order": ("t/0+x", T),
    "operand_before_operator_type": ("30+x", T),
    "type_before_div_zero": ("t/(t-t)", T),
    # Every check is on the double, before truncation.
    "negative_sub_ms": ("0s-0.5ms", NONE),
    "too_long_sub_ms": ("168h+0.5ms", NONE),
    "seven_days_exactly": ("168h", NONE),
    # The 7-day bound is on a duration's magnitude: -200h is too long, not negative.
    "too_long_negative_duration": ("-t*200", HOUR),
    # Numbers have no bound of their own.
    "number_intermediate_unbounded": ("t*(1000000/1000000)", T),
    # Whitespace is space, tab, CR and LF only; positions and the length count code points.
    "whitespace_tab_newline": ("t\t+\r\n30s", T),
    "unknown_variable_after_crlf": ("t\r\n+x", T),
    "nbsp_is_syntax": ("t\u00a0+30s", T),
    "length_counts_code_points": ("\U0001f600" * 33, T),
    # The ASCII letters right after a number are its unit and must be one of ms, s, m, h.
    "unit_letters_run": ("30sec", NONE),
    "compound_duration_is_syntax": ("1m30s", NONE),
    "number_trailing_dot": ("1.s", NONE),
    "number_leading_dot": ("t*.5", T),
}

SPEC = Path(__file__).resolve().parents[2] / "docs" / "specs" / "timers2.md"


def spec_cases() -> dict[str, str | None]:
    """The "Cases (at least)" list of timers2.md §2.5: name -> the expression it spells out
    (``None`` when the spec describes it in words, e.g. ``too_long_text``)."""
    text = SPEC.read_text()
    section = text[text.index("### 2.5 Implementations and vectors") : text.index("## 3. Fold v4")]
    listing = section[section.index("Cases (at least):") :].replace("\n", " ")
    found = re.finditer(r"`([a-z][a-z0-9_]*)` \((?:`([^`]*)`)?", listing)
    return {m.group(1): m.group(2) for m in found}


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
                "Characters are Unicode code points (not UTF-16 units, not grapheme clusters): "
                "the length limit and pos count them. Whitespace is space, tab, CR and LF only; "
                "letter and digit are ASCII. The ASCII letters right after a number form its "
                "unit, which must be exactly ms, s, m or h (else syntax at the unit's first "
                "letter); a '.' must be followed by a digit (else syntax at the '.').",
                "Error precedence: the text length, then the whole parse (the first syntax "
                "error), then evaluation, which reports the first error in evaluation order: "
                "the left operand, the right operand, then the operator's checks (type, then "
                "div_zero, then too_long when the result is a duration whose magnitude exceeds "
                "max_ms; literals and variables are checked too). Last, on the untruncated "
                "result: a number is type at 0, below 0 is negative at 0. Numbers have no bound.",
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
    listed = spec_cases()
    assert len(listed) >= 40
    missing = [name for name in listed if name not in CASES]
    assert missing == []
    spelled = {name: CASES[name][0] for name, expr in listed.items() if expr is not None}
    assert spelled == {name: expr for name, expr in listed.items() if expr is not None}
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


def test_clarifications_answer_as_documented() -> None:
    """The cases this generator adds beyond the §2.5 list, with the outcomes their comments state."""
    assert outcome("syntax_before_evaluation") == {"error": "syntax", "pos": 2}
    assert outcome("first_error_in_evaluation_order") == {"error": "div_zero", "pos": 1}
    assert outcome("operand_before_operator_type") == {"error": "unknown_variable", "pos": 3}
    assert outcome("type_before_div_zero") == {"error": "type", "pos": 1}
    assert outcome("negative_sub_ms") == {"error": "negative", "pos": 0}
    assert outcome("too_long_sub_ms") == {"error": "too_long", "pos": 0}
    assert outcome("seven_days_exactly") == {"ms": MAX_MS}
    assert outcome("too_long_negative_duration") == {"error": "too_long", "pos": 0}
    assert outcome("number_intermediate_unbounded") == {"ms": 60_000}
    assert outcome("whitespace_tab_newline") == {"ms": 90_000}
    assert outcome("unknown_variable_after_crlf") == {"error": "unknown_variable", "pos": 4}
    assert outcome("nbsp_is_syntax") == {"error": "syntax", "pos": 1}
    assert len(CASES["length_counts_code_points"][0]) == 33
    assert len(CASES["length_counts_code_points"][0].encode("utf-16-le")) // 2 == 66
    assert outcome("length_counts_code_points") == {"error": "syntax", "pos": 0}
    assert outcome("unit_letters_run") == {"error": "syntax", "pos": 2}
    assert outcome("compound_duration_is_syntax") == {"error": "syntax", "pos": 2}
    assert outcome("number_trailing_dot") == {"error": "syntax", "pos": 1}
    assert outcome("number_leading_dot") == {"error": "syntax", "pos": 2}


def test_every_case_is_a_duration_or_a_spec_error() -> None:
    codes = {"syntax", "unknown_variable", "type", "negative", "too_long", "div_zero"}
    for name in CASES:
        got = outcome(name)
        if "ms" in got:
            assert 0 <= got["ms"] <= MAX_MS, name
        else:
            assert got["error"] in codes, name
            assert 0 <= got["pos"] <= max(len(CASES[name][0]), MAX_LENGTH), name
