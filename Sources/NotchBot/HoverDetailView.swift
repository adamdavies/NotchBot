import SwiftUI

struct HoverDetailView: View {
    static let shadowPadding: CGFloat = 50

    @ObservedObject var model: ActivityModel
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        Group {
            if model.activeSessions.isEmpty {
                EmptyQueueView(model: model, onHoverChanged: onHoverChanged)
            } else {
                AgentQueueView(model: model, onHoverChanged: onHoverChanged)
            }
        }
        .padding(Self.shadowPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
