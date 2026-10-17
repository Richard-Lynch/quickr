import QuickrUI
import Testing

@Suite struct NumberStepRuleTests {
    let glasses = NumberStepRule(integer: true, min: 0, max: 20)
    let weight = NumberStepRule(integer: false, min: 30, max: 200, decimals: 1)

    @Test func parsesSignsCommasAndExponents() {
        let rule = NumberStepRule(integer: false)
        #expect(rule.parse(" 2.5 ") == 2.5)
        #expect(rule.parse("2,5") == 2.5)
        #expect(rule.parse("-3") == -3)
        #expect(rule.parse(".5") == 0.5)
        #expect(rule.parse("1e3") == 1000)
        #expect(rule.parse("") == nil)
        #expect(rule.parse("1.2.3") == nil)
        #expect(rule.parse("abc") == nil)
    }

    @Test func intsStepByOneAndClamp() {
        #expect(glasses.bumped("3", .up) == "4")
        #expect(glasses.bumped("3", .down) == "2")
        #expect(glasses.bumped("20", .up) == "20")
        #expect(glasses.bumped("0", .down) == "0")
        #expect(glasses.bumped("25", .down) == "20")
    }

    @Test func emptyFieldStartsFromTheBound() {
        #expect(glasses.bumped("", .up) == "0")
        #expect(glasses.bumped("", .down) == "20")
        let open = NumberStepRule(integer: true)
        #expect(open.bumped("", .up) == "0")
        #expect(open.bumped("", .down) == "0")
        let minOnly = NumberStepRule(integer: true, min: 5)
        #expect(minOnly.bumped("", .down) == "5")
    }

    @Test func decimalsStepInTheLastPlaceAndPad() {
        #expect(weight.step == 0.1)
        #expect(weight.bumped("72.5", .up) == "72.6")
        #expect(weight.bumped("72", .down) == "71.9")
        #expect(weight.bumped("199.95", .up) == "200.0")
        #expect(NumberStepRule(integer: false, decimals: 2).bumped("0.1", .up) == "0.11")
    }

    @Test func freePrecisionStepsByOneWithoutFloatNoise() {
        let free = NumberStepRule(integer: false, min: 0)
        #expect(free.step == 1)
        #expect(free.bumped("2.5", .up) == "3.5")
        #expect(free.format(0.1 + 0.2) == "0.3")
        #expect(free.format(-0.0) == "0")
    }

    @Test func intsRoundTypedFractions() {
        #expect(glasses.bumped("2.6", .up) == "4")
    }

    @Test func buttonsDisableAtTheBounds() {
        #expect(!glasses.canBump("0", .down))
        #expect(glasses.canBump("0", .up))
        #expect(!glasses.canBump("20", .up))
        #expect(glasses.canBump("", .down))
        #expect(glasses.canBump("junk", .up))
    }

    @Test func rangeHintAndKeyboard() {
        #expect(glasses.rangeHint == "0–20")
        #expect(NumberStepRule(integer: false, min: 0.5).rangeHint == "≥ 0.5")
        #expect(NumberStepRule(integer: true, max: 10).rangeHint == "≤ 10")
        #expect(NumberStepRule(integer: true).rangeHint == nil)
        #expect(!glasses.allowsNegative)
        #expect(NumberStepRule(integer: true, min: -5).allowsNegative)
        #expect(NumberStepRule(integer: true).allowsNegative)
    }
}
