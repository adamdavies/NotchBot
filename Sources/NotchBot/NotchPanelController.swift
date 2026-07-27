import AppKit
import SwiftUI

@MainActor
final class NotchPanelController {
    private let panel: NSPanel
    private let summaryPanel: NSPanel
    private var mainPanelHovered = false
    private var summaryPanelHovered = false
    private var hoverTask: Task<Void, Never>?
    private var summaryFrame = NSRect.zero

    init(model: ActivityModel) {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        summaryPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        summaryPanel.backgroundColor = .clear
        summaryPanel.isOpaque = false
        summaryPanel.hasShadow = true
        summaryPanel.level = .screenSaver
        summaryPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        summaryPanel.hidesOnDeactivate = false
        summaryPanel.isMovable = false
        summaryPanel.acceptsMouseMovedEvents = true
        summaryPanel.ignoresMouseEvents = false
        summaryPanel.alphaValue = 0

        panel.contentView = NSHostingView(
            rootView: RobotIslandView(model: model) { [weak self] hovering in
                self?.setMainPanelHovered(hovering)
            }
        )
        summaryPanel.contentView = NSHostingView(
            rootView: SummaryCardView(model: model) { [weak self] hovering in
                self?.setSummaryPanelHovered(hovering)
            }
        )

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.positionPanel()
            }
        }
    }

    func show() {
        positionPanel()
        panel.orderFrontRegardless()
    }

    private func positionPanel() {
        guard let screen = preferredScreen else { return }
        let geometry = NotchGeometry(screen: screen)
        let screenFrame = geometry.screenFrame

        let extensionWidth: CGFloat = 38
        let glowSpace: CGFloat = 6
        panel.setFrame(
            NSRect(
                x: geometry.originX - extensionWidth,
                y: screenFrame.maxY - geometry.coverageHeight - glowSpace,
                width: geometry.width + extensionWidth * 2,
                height: geometry.coverageHeight + glowSpace
            ),
            display: true
        )

        let cardSize = NSSize(width: 320, height: 104)
        let cardTop = screenFrame.maxY - geometry.coverageHeight - 4
        let cardX = min(
            max(screenFrame.minX + 8, screenFrame.midX - cardSize.width / 2),
            screenFrame.maxX - cardSize.width - 8
        )
        summaryFrame = NSRect(
            x: cardX,
            y: cardTop - cardSize.height,
            width: cardSize.width,
            height: cardSize.height
        )
        if summaryPanel.isVisible {
            summaryPanel.setFrame(summaryFrame, display: true)
        }
    }

    private func setMainPanelHovered(_ hovering: Bool) {
        mainPanelHovered = hovering
        updateSummaryVisibility()
    }

    private func setSummaryPanelHovered(_ hovering: Bool) {
        summaryPanelHovered = hovering
        updateSummaryVisibility()
    }

    private func updateSummaryVisibility() {
        hoverTask?.cancel()
        let shouldShow = mainPanelHovered || summaryPanelHovered
        hoverTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: shouldShow ? 120_000_000 : 240_000_000)
            } catch {
                return
            }
            guard let self else { return }
            if shouldShow {
                showSummaryPanel()
            } else if !mainPanelHovered && !summaryPanelHovered {
                hideSummaryPanel()
            }
        }
    }

    private func showSummaryPanel() {
        if summaryPanel.isVisible {
            summaryPanel.alphaValue = 1
            return
        }
        var startFrame = summaryFrame
        startFrame.origin.y += 7
        summaryPanel.setFrame(startFrame, display: true)
        summaryPanel.alphaValue = 0
        summaryPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            summaryPanel.animator().setFrame(summaryFrame, display: true)
            summaryPanel.animator().alphaValue = 1
        }
    }

    private func hideSummaryPanel() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            summaryPanel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.mainPanelHovered, !self.summaryPanelHovered else { return }
                self.summaryPanel.orderOut(nil)
            }
        }
    }

    private var preferredScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil }) ?? NSScreen.main ?? NSScreen.screens.first
    }
}
