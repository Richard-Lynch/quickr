import QuickrUI
import Testing

@Suite struct ChipSelectionTests {
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
