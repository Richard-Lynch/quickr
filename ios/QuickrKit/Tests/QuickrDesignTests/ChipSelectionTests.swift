import QuickrUI
import Testing

@Suite(.timeLimit(.minutes(2))) struct ChipSelectionTests {
    let order = ["run", "strength", "yoga", "swim"]

    @Test func singleSelectReplacesAndOnlyClearsWhenOptional() {
        #expect(ChipSelection.toggle(nil, tapped: "mild", required: true) == "mild")
        #expect(ChipSelection.toggle("none", tapped: "mild", required: true) == "mild")
        #expect(ChipSelection.toggle("mild", tapped: "mild", required: true) == "mild")
        #expect(ChipSelection.toggle("mild", tapped: "mild", required: false) == nil)
    }

    @Test func multiSelectTogglesAndKeepsOptionOrder() {
        var value: [String] = []
        value = ChipSelection.toggle(value, tapped: "yoga", max: nil, order: order)
        value = ChipSelection.toggle(value, tapped: "run", max: nil, order: order)
        #expect(value == ["run", "yoga"])
        value = ChipSelection.toggle(value, tapped: "run", max: nil, order: order)
        #expect(value == ["yoga"])
    }

    @Test func multiSelectStopsAtTheLimit() {
        let full = ["run", "yoga"]
        #expect(ChipSelection.toggle(full, tapped: "swim", max: 2, order: order) == full)
        // Deselecting still works at the limit.
        #expect(ChipSelection.toggle(full, tapped: "run", max: 2, order: order) == ["yoga"])
        #expect(ChipSelection.isFull(count: 2, max: 2))
        #expect(!ChipSelection.isFull(count: 1, max: 2))
        #expect(!ChipSelection.isFull(count: 9, max: nil))
    }

    @Test func dimsOnlyUnselectedChipsAtTheLimit() {
        #expect(ChipSelection.isDimmed("swim", in: ["run", "yoga"], max: 2))
        #expect(!ChipSelection.isDimmed("run", in: ["run", "yoga"], max: 2))
        #expect(!ChipSelection.isDimmed("swim", in: ["run"], max: 2))
        #expect(!ChipSelection.isDimmed("swim", in: ["run", "yoga"], max: nil))
    }

    @Test func layouts() {
        #expect(ChipSelection.isWide(index: 2, count: 3))
        #expect(!ChipSelection.isWide(index: 4, count: 5))
        #expect(!ChipSelection.isWide(index: 1, count: 2))
        #expect(ChipSelection.isWide(index: 0, count: 1))
        #expect(ChipSelection.quickColumns(count: 1) == 1)
        #expect(ChipSelection.quickColumns(count: 3) == 2)
        #expect(ChipSelection.quickColumns(count: 4) == 2)
        #expect(ChipSelection.quickColumns(count: 5) == 2)
        #expect(ChipSelection.quickColumns(count: 6) == 3)
    }
}

@Suite(.timeLimit(.minutes(2))) struct ChipSummaryTests {
    @Test func hintsMatchThePWA() {
        #expect(ChipSelection.hint(min: 2, max: 2) == "Pick 2")
        #expect(ChipSelection.hint(min: 1, max: 3) == "Pick 1–3")
        #expect(ChipSelection.hint(min: 0, max: 3) == "Pick up to 3")
        #expect(ChipSelection.hint(min: 2, max: nil) == "Pick at least 2")
        #expect(ChipSelection.hint(min: 1, max: nil) == "Pick any")
    }

    @Test func spokenSummaryReachingAndLeavingTheLimit() {
        #expect(ChipSelection.summary(count: 0, min: 0, max: 3) == "0 selected, pick up to 3")
        #expect(ChipSelection.summary(count: 2, min: 0, max: 3) == "2 selected, pick up to 3")
        #expect(ChipSelection.summary(count: 3, min: 0, max: 3) == "3 selected, pick up to 3, limit reached")
        #expect(ChipSelection.summary(count: 2, min: 1, max: nil) == "2 selected, pick any")
    }
}
