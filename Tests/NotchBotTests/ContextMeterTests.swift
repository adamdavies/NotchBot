import Testing
@testable import NotchBot

/// The meter's banding is the whole of its meaning, so the boundaries are pinned exactly. Values
/// sit either side of each threshold rather than on round numbers alone.
@Test(arguments: [
    (percentage: 0.0, visible: false),
    (percentage: 49.9, visible: false),
    (percentage: 50.0, visible: true),
    (percentage: 74.9, visible: true),
    (percentage: 75.0, visible: true),
    (percentage: 89.9, visible: true),
    (percentage: 90.0, visible: true),
    (percentage: 100.0, visible: true),
])
func contextMeterVisibilityStartsAtFiftyPercent(percentage: Double, visible: Bool) {
    #expect(ContextMeter.isVisible(percentage) == visible)
}

@Test func contextMeterHidesWhenThereIsNoReading() {
    #expect(!ContextMeter.isVisible(nil))
    #expect(!ContextMeter.isVisible(.nan))
}

@Test func contextMeterBandsMatchTheDesignThresholds() {
    let neutral = ContextMeter.tint(for: 50)
    let warning = ContextMeter.tint(for: 75)
    let strong = ContextMeter.tint(for: 90)

    #expect(ContextMeter.tint(for: 74.9) == neutral)
    #expect(ContextMeter.tint(for: 89.9) == warning)
    #expect(ContextMeter.tint(for: 100) == strong)
    #expect(neutral != warning)
    #expect(warning != strong)
    #expect(neutral != strong)
}

/// The bar tracks the unrounded value while only the text rounds, so a reading just under a
/// threshold cannot show a number that contradicts the colour it is drawn in.
@Test func contextMeterFillUsesTheUnroundedValueAndOnlyTheLabelRounds() {
    #expect(ContextMeter.fillFraction(for: 74.6) == 0.746)
    #expect(ContextMeter.tint(for: 74.6) == ContextMeter.tint(for: 50))
    #expect(ContextMeter.label(for: 74.6) == "75% ctx")

    #expect(ContextMeter.fillFraction(for: 0) == 0)
    #expect(ContextMeter.fillFraction(for: 100) == 1)
    #expect(ContextMeter.label(for: 82) == "82% ctx")
    #expect(ContextMeter.accessibilityValue(for: 82) == "82% context used")
}
