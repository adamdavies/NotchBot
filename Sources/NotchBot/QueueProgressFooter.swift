import SwiftUI

struct QueueProgressFooter: View {
    static let height: CGFloat = 45

    @ObservedObject var model: ActivityModel

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(.white.opacity(0.09))

            HStack(spacing: 12) {
                Text("Level: \(model.coolnessTier.displayName)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize()

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.12))
                        Capsule()
                            .fill(Color(red: 0.05, green: 0.72, blue: 0.76))
                            .frame(width: geometry.size.width * model.queueCoolnessProgress)
                    }
                }
                .frame(height: 5)

                Text(model.queueCoolnessProgressText)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Level \(model.coolnessTier.displayName), \(model.queueCoolnessProgressText)")
        }
        .frame(height: Self.height)
    }
}
