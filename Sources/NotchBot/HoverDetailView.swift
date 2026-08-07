import SwiftUI

struct HoverDetailView: View {
    static let shadowPadding: CGFloat = 50

    @ObservedObject var model: ActivityModel
    @ObservedObject var navigation: PanelNavigationModel
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        Group {
            switch navigation.page {
            case .today:
                TodayView(model: model, navigation: navigation, onHoverChanged: onHoverChanged)
            case .queue:
                if model.activeSessions.isEmpty {
                    EmptyQueueView(model: model, navigation: navigation, onHoverChanged: onHoverChanged)
                } else {
                    AgentQueueView(model: model, navigation: navigation, onHoverChanged: onHoverChanged)
                }
            }
        }
        .padding(.horizontal, Self.shadowPadding)
        .padding(.bottom, Self.shadowPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
