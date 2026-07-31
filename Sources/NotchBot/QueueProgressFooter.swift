import SwiftUI

struct QueueProgressFooter: View {
    static let height: CGFloat = 45

    @ObservedObject var model: ActivityModel

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(.white.opacity(0.07))

            HStack(spacing: 8) {
                if model.dailyCostTotal > 0 {
                    Text(model.dailyCostDisplayText)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.3, green: 0.72, blue: 0.48))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }

                Spacer()

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
            .padding(.horizontal, 18)
            .frame(height: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Level \(model.coolnessTier.displayName), \(model.queueCoolnessProgressText)")
        }
        .frame(height: Self.height)
    }
}
