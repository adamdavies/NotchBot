import SwiftUI

struct EmptyQueueView: View {
    @ObservedObject var model: ActivityModel
    @ObservedObject var navigation: PanelNavigationModel
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Bots")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))

                Text("No bot activity in the queue.")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 420, height: 80, alignment: .topLeading)

            QueueProgressFooter(model: model, navigation: navigation)
        }
        .frame(width: 420, height: 80 + QueueProgressFooter.height)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 4,
                bottomLeadingRadius: 13,
                bottomTrailingRadius: 13,
                topTrailingRadius: 4
            )
            .fill(Color.black.opacity(0.96))
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 4,
                    bottomLeadingRadius: 13,
                    bottomTrailingRadius: 13,
                    topTrailingRadius: 4
                )
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onHover(perform: onHoverChanged)
    }
}
