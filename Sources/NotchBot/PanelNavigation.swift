import Combine
import SwiftUI

/// Which page the hover panel is showing.
enum HoverDetailPage: Equatable, Sendable {
    case queue
    case today
}

/// The hover panel's current page.
///
/// Owned by each `DisplayPanelController` rather than by `ActivityModel`, so a user reading Today on
/// one display does not move the panel on every other display out from under itself.
@MainActor
final class PanelNavigationModel: ObservableObject {
    @Published private(set) var page: HoverDetailPage = .queue

    init(page: HoverDetailPage = .queue) {
        self.page = page
    }

    func select(_ page: HoverDetailPage) {
        guard self.page != page else { return }
        self.page = page
    }

    /// Returns the panel to the queue when it closes, so the next hover opens on the live view
    /// rather than wherever the last one was left.
    func reset() {
        select(.queue)
    }
}
