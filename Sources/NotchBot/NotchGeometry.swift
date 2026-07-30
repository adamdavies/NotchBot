import AppKit

struct NotchGeometry {
    let screenFrame: NSRect
    let originX: CGFloat
    let width: CGFloat
    let coverageHeight: CGFloat
    let hasPhysicalNotch: Bool

    static func hasPhysicalNotch(screen: NSScreen) -> Bool {
        guard
            let leftArea = screen.auxiliaryTopLeftArea,
            let rightArea = screen.auxiliaryTopRightArea
        else {
            return false
        }
        return rightArea.minX > leftArea.maxX
    }

    static func syntheticCoverageHeight(
        screenFrame: NSRect,
        visibleFrame: NSRect,
        fallbackMenuBarHeight: CGFloat
    ) -> CGFloat {
        let reportedMenuBarHeight = max(0, screenFrame.maxY - visibleFrame.maxY)
        let menuBarHeight = reportedMenuBarHeight > 0 ? reportedMenuBarHeight : fallbackMenuBarHeight
        return min(max(0, menuBarHeight), screenFrame.height)
    }

    init(screen: NSScreen) {
        screenFrame = screen.frame
        let scale = max(1, screen.backingScaleFactor)
        let pixel = 1 / scale

        if
            let leftArea = screen.auxiliaryTopLeftArea,
            let rightArea = screen.auxiliaryTopRightArea,
            rightArea.minX > leftArea.maxX
        {
            hasPhysicalNotch = true
            let minX = floor(leftArea.maxX * scale) / scale
            let maxX = ceil(rightArea.minX * scale) / scale
            let reportedHeight = max(
                screen.safeAreaInsets.top,
                leftArea.height,
                rightArea.height
            )
            let menuBarHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
            let coverage = reportedHeight + max(0, menuBarHeight - reportedHeight) / 2

            originX = minX
            width = maxX - minX
            coverageHeight = ceil(coverage * scale) / scale + pixel
        } else {
            hasPhysicalNotch = false
            width = 160
            originX = screen.frame.midX - width / 2
            coverageHeight = Self.syntheticCoverageHeight(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                fallbackMenuBarHeight: NSStatusBar.system.thickness
            )
        }
    }
}
