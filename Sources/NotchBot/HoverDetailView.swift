import SwiftUI

struct HoverDetailView: View {
    @ObservedObject var model: ActivityModel
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        Group {
            if model.activeSessions.isEmpty {
                EmptyQueueView(onHoverChanged: onHoverChanged)
            } else {
                AgentQueueView(model: model, onHoverChanged: onHoverChanged)
            }
        }
    }
}
