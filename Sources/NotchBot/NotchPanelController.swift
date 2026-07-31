import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchPanelController {
    private let model: ActivityModel
    private let appearance: AppearanceModel
    private let displaySelection: DisplaySelectionModel
    private var displayPanels: [String: DisplayPanelController] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var isShown = false

    init(
        model: ActivityModel,
        appearance: AppearanceModel,
        displaySelection: DisplaySelectionModel
    ) {
        self.model = model
        self.appearance = appearance
        self.displaySelection = displaySelection

        displaySelection.$selection
            .combineLatest(displaySelection.$screenRevision)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.reconcilePanels()
            }
            .store(in: &cancellables)
    }

    func show() {
        isShown = true
        reconcilePanels()
    }

    private func reconcilePanels() {
        guard isShown else { return }
        let targets = displaySelection.resolvedTargets()
        let targetIDs = Set(targets.map(\.id))

        let removedIDs = displayPanels.keys.filter { !targetIDs.contains($0) }
        for identifier in removedIDs {
            displayPanels.removeValue(forKey: identifier)?.close()
        }

        for target in targets {
            if let controller = displayPanels[target.id] {
                controller.position(on: target.screen)
            } else {
                let controller = DisplayPanelController(model: model, appearance: appearance)
                displayPanels[target.id] = controller
                controller.show(on: target.screen)
            }
        }
    }
}

@MainActor
private final class DisplayPanelController {
    private let panel: NSPanel
    private let summaryPanel: NSPanel
    private var mainPanelHovered = false
    private var summaryPanelHovered = false
    private var hoverTask: Task<Void, Never>?
    private var summaryFrame = NSRect.zero
    private var geometry: NotchGeometry?
    private var maximumIslandHeight: CGFloat?
    private var cancellables: Set<AnyCancellable> = []
    private let model: ActivityModel
    private let appearance: AppearanceModel

    init(model: ActivityModel, appearance: AppearanceModel) {
        self.model = model
        self.appearance = appearance
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
        configure(panel)
        configure(summaryPanel)
        summaryPanel.alphaValue = 0

        panel.contentView = NSHostingView(
            rootView: RobotIslandView(model: model, appearance: appearance) { [weak self] hovering in
                self?.setMainPanelHovered(hovering)
            }
        )
        summaryPanel.contentView = NSHostingView(
            rootView: HoverDetailView(model: model) { [weak self] hovering in
                self?.setSummaryPanelHovered(hovering)
            }
        )

        model.$activeSessions
            .combineLatest(model.$previewState, model.$previewCoolnessTier)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                guard let self else { return }
                self.updateDetailFrame()
                if self.summaryPanel.isVisible, !self.hasDetailContent {
                    self.forceHideDetailPanel()
                } else if self.hasDetailContent, !self.summaryPanel.isVisible, self.mainPanelHovered {
                    self.updateSummaryVisibility()
                }
            }
            .store(in: &cancellables)
    }

    func show(on screen: NSScreen) {
        position(on: screen)
        panel.orderFrontRegardless()
    }

    func position(on screen: NSScreen) {
        let geometry = NotchGeometry(screen: screen)
        self.geometry = geometry
        let updatedMaximumHeight = geometry.hasPhysicalNotch ? nil : geometry.coverageHeight
        if maximumIslandHeight != updatedMaximumHeight {
            maximumIslandHeight = updatedMaximumHeight
            panel.contentView = NSHostingView(
                rootView: RobotIslandView(
                    model: model,
                    appearance: appearance,
                    maximumIslandHeight: updatedMaximumHeight
                ) { [weak self] hovering in
                    self?.setMainPanelHovered(hovering)
                }
            )
        }
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
        updateDetailFrame()
    }

    func close() {
        hoverTask?.cancel()
        mainPanelHovered = false
        forceHideDetailPanel()
        panel.orderOut(nil)
    }

    private func configure(_ panel: NSPanel) {
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
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
        let shouldShow = (mainPanelHovered || summaryPanelHovered) && hasDetailContent
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
        guard hasDetailContent else { return }
        updateDetailFrame()
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
        guard hasDetailContent else {
            forceHideDetailPanel()
            return
        }
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

    private var hasDetailContent: Bool {
        model.previewState == nil
    }

    private var detailSize: NSSize {
        guard !model.activeSessions.isEmpty else {
            return NSSize(width: 420, height: 80 + QueueProgressFooter.height)
        }
        let height = model.activeSessions.prefix(5).reduce(CGFloat(42)) { result, session in
            guard let permission = session.permission else { return result + 71 }
            return result + (permission.context == nil ? 121 : 151)
        }
        return NSSize(width: 420, height: height + QueueProgressFooter.height)
    }

    private func updateDetailFrame() {
        guard let geometry else { return }
        let size = detailSize
        let screenFrame = geometry.screenFrame
        let cardTop = screenFrame.maxY - geometry.coverageHeight - 4
        let notchCenterX = geometry.originX + geometry.width / 2
        let cardX = min(
            max(screenFrame.minX + 8, notchCenterX - size.width / 2),
            screenFrame.maxX - size.width - 8
        )
        summaryFrame = NSRect(
            x: cardX,
            y: cardTop - size.height,
            width: size.width,
            height: size.height
        )
        if summaryPanel.isVisible {
            summaryPanel.contentView?.layer?.removeAllAnimations()
            summaryPanel.setFrame(summaryFrame, display: true)
            let isMouseInsideUpdatedFrame = summaryFrame.contains(NSEvent.mouseLocation)
            if summaryPanelHovered != isMouseInsideUpdatedFrame {
                summaryPanelHovered = isMouseInsideUpdatedFrame
                updateSummaryVisibility()
            }
        }
    }

    private func forceHideDetailPanel() {
        hoverTask?.cancel()
        summaryPanelHovered = false
        summaryPanel.contentView?.layer?.removeAllAnimations()
        summaryPanel.alphaValue = 0
        summaryPanel.orderOut(nil)
    }
}
