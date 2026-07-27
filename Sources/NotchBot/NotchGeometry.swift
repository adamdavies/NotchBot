import AppKit

struct NotchGeometry {
    let screenFrame: NSRect
    let originX: CGFloat
    let width: CGFloat
    let coverageHeight: CGFloat

    init(screen: NSScreen) {
        screenFrame = screen.frame
        let scale = max(1, screen.backingScaleFactor)
        let pixel = 1 / scale

        if
            let leftArea = screen.auxiliaryTopLeftArea,
            let rightArea = screen.auxiliaryTopRightArea,
            rightArea.minX > leftArea.maxX
        {
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
            let menuBarHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
            width = 160
            originX = screen.frame.midX - width / 2
            coverageHeight = max(32, menuBarHeight)
        }
    }
}
