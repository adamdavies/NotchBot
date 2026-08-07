import NotchBotCore
import SwiftUI

struct QueueProgressFooter: View {
    static let height: CGFloat = 45

    @ObservedObject var model: ActivityModel
    @ObservedObject var navigation: PanelNavigationModel

    /// The pill is the only way into Today, so it appears whenever Today has something to show —
    /// not only when spend was tracked. A user who never enabled cost tracking still has a day of
    /// completed runs to look back on.
    private var showsTodayPill: Bool {
        model.dailyCostTotal > 0 || model.hasTodayHistory
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(.white.opacity(0.07))

            HStack(spacing: 8) {
                if showsTodayPill {
                    Button {
                        navigation.select(.today)
                    } label: {
                        Text(model.todayPillText)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Self.costColor(for: model.dailyCostAlertLevel))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(costAccessibilityLabel)
                    .accessibilityHint("Shows today's completed sessions")
                    .help("Show today's completed sessions")
                }

                Spacer()

                HStack(spacing: 8) {
                    Text("Level: \(model.coolnessTier.displayName)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                        .fixedSize()

                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.white.opacity(0.08))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(red: 0.38, green: 0.58, blue: 0.62))
                            .frame(width: 64 * model.queueCoolnessProgress)
                    }
                    .frame(width: 64, height: 4)

                    Text(model.queueCoolnessProgressText)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.2))
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Level \(model.coolnessTier.displayName), \(model.queueCoolnessProgressText)")
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
        }
        .frame(height: Self.height)
    }

    private var costAccessibilityLabel: String {
        let spend = model.todayPillText
        guard model.dailyCostTotal > 0 else { return spend }
        return switch model.dailyCostAlertLevel {
        case .normal: spend
        case .warning: "\(spend), approaching \(model.dailyCostThresholdDisplayText ?? "")"
        case .exceeded: "\(spend), passed \(model.dailyCostThresholdDisplayText ?? "")"
        }
    }

    private static func costColor(for level: DailyCostAlertLevel) -> Color {
        switch level {
        case .normal: Color(red: 0.3, green: 0.72, blue: 0.48)
        case .warning: Color(red: 0.95, green: 0.71, blue: 0.25)
        case .exceeded: Color(red: 0.93, green: 0.38, blue: 0.35)
        }
    }
}
