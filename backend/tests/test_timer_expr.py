"""The alert expression grammar (docs/specs/timers2.md §2): one test per grammar rule of §2.1,
per type rule of §2.2 and per error code of §2.3, the evaluation rules of §2.4, and a seeded
property test (random well-typed expressions evaluate to the same ms as a direct computation).
"""

from __future__ import annotations

import dataclasses
import random
from collections.abc import Mapping

import pytest

from app.services.timer_expr import MAX_LENGTH, MAX_MS, ExprError, evaluate

T = {"t": 60_000}
HOUR = 3_600_000
DAY = 24 * HOUR


def err(text: str, variables: Mapping[str, int] | None = None) -> tuple[str, int]:
    with pytest.raises(ExprError) as info:
        evaluate(text, T if variables is None else variables)
    return info.value.code, info.value.pos


# --- §2.1 grammar, one rule at a time --------------------------------------------------------


def test_expr_plus_and_minus_are_left_associative() -> None:
    assert evaluate("t-10s-10s", T) == 40_000
    assert evaluate("t-10s+5s", T) == 55_000
    assert evaluate("10s-t+t", T) == 10_000


def test_term_binds_tighter_than_expr() -> None:
    assert evaluate("t+2*10s", T) == 80_000
    assert evaluate("t-10s/2", T) == 55_000
    assert evaluate("2*10s+t", T) == 80_000


def test_term_times_and_divide_are_left_associative() -> None:
    assert evaluate("t/2/3", T) == 10_000
    assert evaluate("t*2/4", T) == 30_000
    assert evaluate("t/4*2", T) == 30_000


def test_factor_duration() -> None:
    assert evaluate("30s", {}) == 30_000


def test_factor_number_inside_a_duration_expression() -> None:
    assert evaluate("t*2", T) == 120_000
    assert evaluate("t*(2+3)", T) == 300_000
    assert evaluate("t*(2-1)", T) == 60_000
    assert evaluate("t*(6/3)", T) == 120_000
    assert evaluate("t*(2*2)", T) == 240_000


def test_factor_ident() -> None:
    assert evaluate("t", T) == 60_000
    assert evaluate("work+rest", {"work": 1_500_000, "rest": 300_000}) == 1_800_000


def test_factor_parens() -> None:
    assert evaluate("(t/2)+30s", T) == 60_000
    assert evaluate("(t+10s)*2", T) == 140_000
    assert evaluate("((t))", T) == 60_000


def test_factor_unary_minus() -> None:
    assert evaluate("--t", T) == 60_000
    assert evaluate("-(-t)", T) == 60_000
    assert evaluate("- -t", T) == 60_000
    assert evaluate("t*-2*-1", T) == 120_000
    assert evaluate("-t/2+t", T) == 30_000  # (-t)/2 + t
    assert evaluate("-2*t+3*t", T) == 60_000


def test_duration_each_unit() -> None:
    assert evaluate("1ms", {}) == 1
    assert evaluate("1s", {}) == 1_000
    assert evaluate("1m", {}) == 60_000
    assert evaluate("1h", {}) == 3_600_000


def test_duration_longest_unit_first_ms_before_m() -> None:
    assert evaluate("2ms", {}) == 2
    assert evaluate("2m", {}) == 120_000


def test_duration_fractional_number() -> None:
    assert evaluate("1.5m", {}) == 90_000
    assert evaluate("0.5h", {}) == 1_800_000
    assert evaluate("0.25s", {}) == 250


def test_number_digits_with_optional_fraction() -> None:
    assert evaluate("007s", {}) == 7_000
    assert evaluate("t*1.5", T) == 90_000
    assert evaluate("t*0.50", T) == 30_000
    assert err("t*.5") == ("syntax", 2)
    assert err("t*1.5.5") == ("syntax", 5)


def test_ident_letters_digits_and_underscore_one_token() -> None:
    variables = {"work_1": 10_000, "r2": 5_000}
    assert evaluate("work_1+r2", variables) == 15_000
    # ``t2`` is one identifier, not ``t`` followed by ``2``.
    assert err("t2") == ("unknown_variable", 0)


def test_ident_matches_variables_case_insensitively() -> None:
    assert evaluate("T/2", T) == 30_000
    assert evaluate("T", T) == 60_000
    assert evaluate("Work_A+WORK_A", {"work_a": 1_000}) == 2_000


def test_whitespace_between_tokens_is_ignored() -> None:
    assert evaluate("t + 30s", T) == 90_000
    assert evaluate("  t  *  0.5  ", T) == 30_000
    assert evaluate("( t / 2 ) + 30s", T) == 60_000


def test_unit_must_follow_its_number_without_a_space() -> None:
    assert err("30 s", {}) == ("syntax", 3)
    assert err("t + 30 s") == ("syntax", 7)


def test_units_are_lowercase_only() -> None:
    assert err("30S", {}) == ("syntax", 2)
    assert err("1H", {}) == ("syntax", 1)
    assert err("5Ms", {}) == ("syntax", 1)


# --- §2.2 types ------------------------------------------------------------------------------


def test_type_duration_plus_minus_duration() -> None:
    assert evaluate("t+30s", T) == 90_000
    assert evaluate("t-30s", T) == 30_000


def test_type_duration_times_number_both_ways() -> None:
    assert evaluate("t*0.5", T) == 30_000
    assert evaluate("0.5*t", T) == 30_000
    assert evaluate("2*t", T) == 120_000


def test_type_duration_divided_by_number() -> None:
    assert evaluate("t/2", T) == 30_000


def test_type_number_op_number_is_a_number() -> None:
    assert evaluate("t*(1+1)", T) == 120_000
    assert evaluate("t*(3-1)", T) == 120_000
    assert evaluate("t*(1*2)", T) == 120_000
    assert evaluate("t*(4/2)", T) == 120_000


def test_type_negation_keeps_the_type() -> None:
    assert evaluate("-(-t)", T) == 60_000
    assert evaluate("t*(-(-2))", T) == 120_000


def test_type_duration_plus_number_errors_at_the_operator() -> None:
    assert err("t+30") == ("type", 1)
    assert err("30+t") == ("type", 2)
    assert err("t-30") == ("type", 1)
    assert err("30-t") == ("type", 2)
    assert err("(t/2)+30") == ("type", 5)


def test_type_duration_times_duration_errors_at_the_operator() -> None:
    assert err("t*t") == ("type", 1)
    assert err("t*30s") == ("type", 1)
    assert err("(t+10s)*(t)") == ("type", 7)


def test_type_number_divided_by_duration_errors_at_the_operator() -> None:
    assert err("2/t") == ("type", 1)
    assert err("(2)/t") == ("type", 3)


def test_type_duration_divided_by_duration_errors_at_the_operator() -> None:
    assert err("t/t") == ("type", 1)
    assert err("t/(t-t)") == ("type", 1)  # a type error, not div_zero: the divisor is a duration


def test_type_bare_number_result_errors_at_zero() -> None:
    assert err("30", {}) == ("type", 0)
    assert err("2*3", {}) == ("type", 0)
    assert err("(2)", {}) == ("type", 0)
    assert err("-2", {}) == ("type", 0)
    assert err("  2", {}) == ("type", 0)


# --- §2.3 errors, one code at a time ----------------------------------------------------------


def test_syntax_unexpected_token() -> None:
    assert err("t t") == ("syntax", 2)
    assert err("t+*2s") == ("syntax", 2)
    assert err("()") == ("syntax", 1)
    assert err("t)") == ("syntax", 1)
    assert err("*t") == ("syntax", 0)


def test_syntax_unexpected_end() -> None:
    assert err("t+") == ("syntax", 2)
    assert err("(t") == ("syntax", 2)
    assert err("t*(") == ("syntax", 3)
    assert err("-") == ("syntax", 1)


def test_syntax_unknown_character() -> None:
    assert err("t%2") == ("syntax", 1)
    assert err("t+30s!") == ("syntax", 5)
    assert err("t+é") == ("syntax", 2)
    assert err("[t]") == ("syntax", 0)


def test_syntax_unknown_unit() -> None:
    assert err("30d", {}) == ("syntax", 2)
    assert err("t+30x") == ("syntax", 4)


def test_syntax_empty_input() -> None:
    assert err("", {}) == ("syntax", 0)


def test_unknown_variable_at_the_identifier() -> None:
    assert err("x/2") == ("unknown_variable", 0)
    assert err("t+x") == ("unknown_variable", 2)
    assert err("t+(rest)") == ("unknown_variable", 3)
    assert err("T", {}) == ("unknown_variable", 0)


def test_div_zero_at_the_slash() -> None:
    assert err("t/0") == ("div_zero", 1)
    assert err("t/0.0") == ("div_zero", 1)
    assert err("t/(1-1)") == ("div_zero", 1)
    assert err("(t)/0") == ("div_zero", 3)
    assert err("t/-0") == ("div_zero", 1)


def test_negative_result_at_zero() -> None:
    assert err("-t") == ("negative", 0)
    assert err("t-2*t") == ("negative", 0)
    assert err("t*-1") == ("negative", 0)
    assert err("0s-1ms", {}) == ("negative", 0)


def test_negative_intermediate_is_allowed() -> None:
    assert evaluate("t-2*t+2*t", T) == 60_000
    assert evaluate("-t+2*t", T) == 60_000


def test_too_long_text_at_64() -> None:
    text = "+".join(["t"] * 33)
    assert len(text) == MAX_LENGTH + 1 == 65
    assert err(text) == ("too_long", 64)
    assert evaluate(text[:-2], T) == 32 * 60_000  # 63 characters are fine


def test_too_long_result_at_zero() -> None:
    assert err("t*2000", {"t": HOUR}) == ("too_long", 0)
    assert err("169h", {}) == ("too_long", 0)
    assert err("168h+1ms", {}) == ("too_long", 0)
    assert err("t", {"t": MAX_MS + 1}) == ("too_long", 0)


def test_seven_days_exactly_is_allowed() -> None:
    assert MAX_MS == 7 * DAY == 604_800_000
    assert evaluate("168h", {}) == MAX_MS
    assert evaluate("7*24h", {}) == MAX_MS
    assert evaluate("t", {"t": MAX_MS}) == MAX_MS


def test_too_long_intermediate_at_zero() -> None:
    assert err("t*10000-t*10000", {"t": HOUR}) == ("too_long", 0)
    assert err("169h-2h", {}) == ("too_long", 0)
    assert err("(t*2000)/2000", {"t": HOUR}) == ("too_long", 0)


# --- §2.4 evaluation --------------------------------------------------------------------------


def test_result_is_truncated_toward_zero_to_whole_ms() -> None:
    assert evaluate("t/3", {"t": 1_000}) == 333
    assert evaluate("0.0015s", {}) == 1
    assert evaluate("1.25ms", {}) == 1
    assert evaluate("1.99ms", {}) == 1
    assert evaluate("t/7", {"t": 1_000}) == 142


def test_intermediate_values_are_not_rounded() -> None:
    # 1.5 ms + 1.5 ms = 3 ms exactly; rounding the halves would give 2 or 4.
    assert evaluate("1.5ms+1.5ms", {}) == 3
    # (1000 / 3) * 3 is 1000 (within a double), not 333 * 3.
    assert evaluate("t/3*3", {"t": 1_000}) == 1_000


def test_unit_literal_is_number_times_factor() -> None:
    assert evaluate("1.5m", {}) == int(1.5 * 60_000)
    assert evaluate("0.1h", {}) == int(0.1 * 3_600_000)
    assert evaluate("1.1s", {}) == int(1.1 * 1_000)


def test_zero_result_is_allowed() -> None:
    assert evaluate("t-t", T) == 0
    assert evaluate("0s", {}) == 0
    assert evaluate("0*t", T) == 0


# --- clarifications the ports must match (pinned in the vectors too) -------------------------


def test_the_whole_text_parses_before_anything_evaluates() -> None:
    assert err("x+") == ("syntax", 2)
    assert err("t/0)") == ("syntax", 3)
    assert err("x x") == ("syntax", 2)


def test_evaluation_reports_the_first_error_in_evaluation_order() -> None:
    assert err("t/0+x") == ("div_zero", 1)
    assert err("x+30") == ("unknown_variable", 0)
    assert err("30+x") == ("unknown_variable", 3)
    assert err("t*t+x") == ("type", 1)
    assert err("t*2000+x", {"t": HOUR}) == ("too_long", 0)
    assert err("2/0", {}) == ("div_zero", 1)  # before the bare-number result


def test_the_seven_day_bound_is_on_magnitude() -> None:
    assert err("-t*200", {"t": HOUR}) == ("too_long", 0)
    assert err("-169h", {}) == ("too_long", 0)
    assert err("-168h", {}) == ("negative", 0)


def test_numbers_have_no_bound_of_their_own() -> None:
    assert evaluate("t*(1000000/1000000)", T) == 60_000
    assert evaluate("t*(99999999999999999999/99999999999999999999)", T) == 60_000


def test_checks_are_on_the_untruncated_double() -> None:
    assert err("0s-0.5ms", {}) == ("negative", 0)
    assert err("168h+0.5ms", {}) == ("too_long", 0)
    assert evaluate("-0s", {}) == 0  # -0.0 is not below 0
    assert evaluate("0*-t", T) == 0


def test_whitespace_is_space_tab_cr_lf_only() -> None:
    assert evaluate("t\t+\r\n30s", T) == 90_000
    assert err("t\r\n+x") == ("unknown_variable", 4)
    assert err("t\u00a0+30s") == ("syntax", 1)
    assert err("t\u2003") == ("syntax", 1)


def test_length_and_pos_count_code_points() -> None:
    assert err("\U0001f600" * 33) == ("syntax", 0)  # 66 UTF-16 units, 33 code points
    assert err("\U0001f600" * 65) == ("too_long", 64)
    assert err("t+\U0001f600") == ("syntax", 2)


def test_letters_and_digits_are_ascii() -> None:
    assert err("t+\u0661s") == ("syntax", 2)  # ARABIC-INDIC DIGIT ONE
    assert err("\u00e9") == ("syntax", 0)


def test_the_letters_after_a_number_are_its_unit() -> None:
    assert err("30sec", {}) == ("syntax", 2)
    assert err("2mt") == ("syntax", 1)
    assert err("1m30s", {}) == ("syntax", 2)
    assert err("30s_", {}) == ("syntax", 3)


def test_a_dot_must_be_followed_by_a_digit() -> None:
    assert err("1.s", {}) == ("syntax", 1)
    assert err("t*2.") == ("syntax", 3)


def test_expr_error_carries_code_pos_and_a_message() -> None:
    with pytest.raises(ExprError) as info:
        evaluate("30", {})
    e = info.value
    assert (e.code, e.pos) == ("type", 0)
    assert e.detail
    assert str(e) == f"type at 0: {e.detail}"
    assert "unit" in e.detail  # OQ-5: "add a unit"


# --- property: random well-typed expressions against a direct computation -------------------

UNITS = {"ms": 1, "s": 1_000, "m": 60_000, "h": 3_600_000}
VARIABLES = {"t": 60_000, "work": 1_500_000, "rest": 300_000, "short_1": 750}


@dataclasses.dataclass(frozen=True)
class Node:
    """A typed expression tree; ``kind`` is lit, var, neg or one of ``+ - * /``."""

    kind: str
    duration: bool
    text: str = ""
    value: float = 0.0
    children: tuple[Node, ...] = ()


def lit_number(rng: random.Random) -> Node:
    n = rng.choice([str(rng.randint(1, 9)), f"{rng.randint(0, 9)}.{rng.randint(0, 99)}", "0.5", "2", "10"])
    return Node("lit", False, n, float(n))


def lit_duration(rng: random.Random) -> Node:
    unit = rng.choice(list(UNITS))
    n = rng.choice([str(rng.randint(0, 120)), f"{rng.randint(0, 9)}.{rng.randint(0, 9)}"])
    return Node("lit", True, n + unit, float(n) * UNITS[unit])


def gen_number(rng: random.Random, depth: int) -> Node:
    if depth == 0 or rng.random() < 0.4:
        return lit_number(rng)
    choice = rng.random()
    if choice < 0.15:
        child = gen_number(rng, depth - 1)
        return Node("neg", False, children=(child,))
    op = rng.choice("+-*/")
    return Node(op, False, children=(gen_number(rng, depth - 1), gen_number(rng, depth - 1)))


def gen_duration(rng: random.Random, depth: int) -> Node:
    if depth == 0 or rng.random() < 0.3:
        if rng.random() < 0.5:
            name = rng.choice(list(VARIABLES))
            spelled = name.upper() if rng.random() < 0.3 else name
            return Node("var", True, spelled, float(VARIABLES[name]))
        return lit_duration(rng)
    choice = rng.random()
    if choice < 0.1:
        return Node("neg", True, children=(gen_duration(rng, depth - 1),))
    if choice < 0.45:
        op = rng.choice("+-")
        return Node(op, True, children=(gen_duration(rng, depth - 1), gen_duration(rng, depth - 1)))
    if choice < 0.7:
        return Node("*", True, children=(gen_duration(rng, depth - 1), gen_number(rng, depth - 1)))
    if choice < 0.85:
        return Node("*", True, children=(gen_number(rng, depth - 1), gen_duration(rng, depth - 1)))
    return Node("/", True, children=(gen_duration(rng, depth - 1), gen_number(rng, depth - 1)))


PREC = {"+": 1, "-": 1, "*": 2, "/": 2, "neg": 3, "lit": 4, "var": 4}


def render(node: Node, rng: random.Random) -> str:
    """Spell the tree with the fewest parentheses that keep its shape (equal precedence on the
    right is parenthesised, so left-associativity cannot regroup it) and random spacing."""
    sp = " " if rng.random() < 0.3 else ""
    if node.kind in ("lit", "var"):
        return node.text
    if node.kind == "neg":
        (child,) = node.children
        inner = render(child, rng)
        if PREC[child.kind] < PREC["neg"]:
            inner = f"({inner})"
        return f"-{sp}{inner}"
    left, right = node.children
    ls = render(left, rng)
    rs = render(right, rng)
    if PREC[left.kind] < PREC[node.kind]:
        ls = f"({ls})"
    if PREC[right.kind] <= PREC[node.kind]:
        rs = f"({rs})"
    return f"{ls}{sp}{node.kind}{sp}{rs}"


class Unpinned(Exception):
    """The tree reaches a case whose outcome this test does not pin (div_zero, too_long)."""


def direct(node: Node) -> float:
    """The same operations in the same order as the reference, on doubles."""
    if node.kind in ("lit", "var"):
        value = node.value
    elif node.kind == "neg":
        value = -direct(node.children[0])
    else:
        left = direct(node.children[0])
        right = direct(node.children[1])
        if node.kind == "+":
            value = left + right
        elif node.kind == "-":
            value = left - right
        elif node.kind == "*":
            value = left * right
        else:
            if right == 0:
                raise Unpinned
            value = left / right
    if node.duration and abs(value) > MAX_MS:
        raise Unpinned
    return value


def test_property_random_well_typed_expressions_match_a_direct_computation() -> None:
    rng = random.Random(20261125)
    checked = 0
    negatives = 0
    for _ in range(3000):
        tree = gen_duration(rng, rng.randint(1, 3))
        text = render(tree, rng)
        if len(text) > MAX_LENGTH:
            continue
        try:
            expected = direct(tree)
        except Unpinned:
            continue
        if -1 < expected < 0 or MAX_MS < expected < MAX_MS + 1:
            continue  # sub-ms edges: not pinned here
        if expected < 0:
            assert err(text, VARIABLES) == ("negative", 0), text
            negatives += 1
            continue
        assert evaluate(text, VARIABLES) == int(expected), text
        checked += 1
    assert checked >= 1000
    assert negatives >= 50
