import AppKit
import Testing
@testable import NotchBot

@Test func syntheticNotchUsesReportedMenuBarHeight() {
    let screen = NSRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
    let visible = NSRect(x: -1_920, y: 0, width: 1_920, height: 1_055)

    let height = NotchGeometry.syntheticCoverageHeight(
        screenFrame: screen,
        visibleFrame: visible,
        fallbackMenuBarHeight: 24
    )

    #expect(height == 25)
}

@Test func syntheticNotchUsesFallbackForAutoHiddenMenuBar() {
    let screen = NSRect(x: 0, y: 0, width: 1_512, height: 982)

    let height = NotchGeometry.syntheticCoverageHeight(
        screenFrame: screen,
        visibleFrame: screen,
        fallbackMenuBarHeight: 24
    )

    #expect(height == 24)
}

@Test func syntheticNotchHeightCannotExceedDisplay() {
    let screen = NSRect(x: 0, y: 0, width: 100, height: 20)

    let height = NotchGeometry.syntheticCoverageHeight(
        screenFrame: screen,
        visibleFrame: screen,
        fallbackMenuBarHeight: 24
    )

    #expect(height == 20)
}
