import QuickrCore
import Testing

@Suite struct JSNumberTests {
    /// Expected values are what `String(x)` prints in V8.
    @Test(arguments: [
        (0.0, "0"), (-0.0, "0"), (7.0, "7"), (-3.0, "-3"), (7.5, "7.5"), (0.1 + 0.2, "0.30000000000000004"),
        (1e-6, "0.000001"), (1.5e-7, "1.5e-7"), (1e-7, "1e-7"), (123_456_789.125, "123456789.125"),
        (1e20, "100000000000000000000"), (1.2345678901234568e20, "123456789012345680000"), (1e21, "1e+21"),
        (-1.5e300, "-1.5e+300"), (9_007_199_254_740_992, "9007199254740992"), (0.001, "0.001"), (100.0, "100"),
        (5e-324, "5e-324"), (Double.greatestFiniteMagnitude, "1.7976931348623157e+308"), (.infinity, "Infinity"),
        (-.infinity, "-Infinity"), (.nan, "NaN"),
    ])
    func string(_ value: Double, _ expected: String) {
        #expect(JSNumber.string(value) == expected)
    }

    @Test func trimMatchesJavaScript() {
        #expect(JSNumber.trim("\u{FEFF}\t a b \n\u{A0}\u{2028}") == "a b")
        #expect(JSNumber.trim("   ") == "")
        // NEL (U+0085) isn't JS whitespace.
        #expect(JSNumber.trim("\u{85}x") == "\u{85}x")
    }

    @Test func numberGrammar() {
        for good in ["1", "+1", "-1", "1.", "1,", ".5", ",5", "1.5e3", "1,5E-3", "007"] {
            #expect(NumberInput.isNumber(good), "\(good)")
        }
        for bad in ["", "+", "-", ".", "e3", "1e", "1e+", "1.5.5", "1,5,5", "1 5", "١", "Infinity", "NaN", "0x1"] {
            #expect(!NumberInput.isNumber(bad), "\(bad)")
        }
        #expect(NumberInput.isWholeNumber("-12") && !NumberInput.isWholeNumber("1.0") && !NumberInput.isWholeNumber(""))
    }
}
