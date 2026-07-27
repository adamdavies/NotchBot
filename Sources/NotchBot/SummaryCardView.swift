import NotchBotCore
import SwiftUI

struct SummaryCardView: View {
    @ObservedObject var model: ActivityModel
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(sourceColor)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 8)
                if let updatedAt = model.latestSummary?.updatedAt {
                    Text(updatedAt, style: .relative)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.48))
                }
            }

            if let projectName = model.latestSummary?.projectName {
                Text(projectName)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.yellow.opacity(0.78))
                    .lineLimit(1)
            }

            Text(model.latestSummary?.text ?? "No completed agent response yet.")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(width: 320, height: 104, alignment: .topLeading)
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

    private var title: String {
        guard let summary = model.latestSummary else { return "NotchBot" }
        return summary.source == .claude ? "Latest Claude Code update" : "Latest OpenCode update"
    }

    private var sourceColor: Color {
        guard let summary = model.latestSummary else { return .secondary }
        return summary.source == .claude ? Color(red: 0.82, green: 0.5, blue: 0.34) : .green
    }
}
