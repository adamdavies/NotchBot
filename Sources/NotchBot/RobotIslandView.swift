import NotchBotCore
import SwiftUI

struct RobotIslandView: View {
    @ObservedObject var model: ActivityModel
    @ObservedObject var appearance: AppearanceModel
    let maximumIslandHeight: CGFloat?
    let onHoverChanged: (Bool) -> Void

    init(
        model: ActivityModel,
        appearance: AppearanceModel,
        maximumIslandHeight: CGFloat? = nil,
        onHoverChanged: @escaping (Bool) -> Void
    ) {
        self.model = model
        self.appearance = appearance
        self.maximumIslandHeight = maximumIslandHeight
        self.onHoverChanged = onHoverChanged
    }

    var body: some View {
        TimelineView(.animation(
            minimumInterval: model.displayedWaitingAgentCount > 0 ? 1.0 / 30.0 : 1.0 / 8.0
        )) { timeline in
            let frame = frameIndex(at: timeline.date)
            let pulse = pulseAmount(at: timeline.date)
            let sweep = sweepAmount(at: timeline.date)
            HStack(spacing: 0) {
                ZStack {
                    if model.displayedRobotState == .attention {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [.yellow.opacity(0.42), .yellow.opacity(0.06), .clear],
                                    center: .center,
                                    startRadius: 2,
                                    endRadius: 17
                                )
                            )
                            .frame(width: 34, height: 34)
                            .scaleEffect(0.9 + pulse * 0.12)
                    }
                    NotchCharacterView(
                        character: appearance.character,
                        state: model.displayedRobotState,
                        date: timeline.date,
                        frameIndex: frame,
                        coolnessTier: model.displayedCoolnessTier
                    )
                    .frame(width: 24, height: 24)
                }
                .frame(width: 38)

                Color.clear.frame(maxWidth: .infinity)

                Text(model.displayedAgentCount > 99 ? "99+" : "\(model.displayedAgentCount)")
                    .font(.system(size: model.displayedAgentCount > 99 ? 8 : 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(model.displayedWaitingAgentCount > 0 ? Color.black : Color.white)
                    .frame(width: 22, height: 22)
                    .background {
                        Circle()
                            .fill(
                                model.displayedWaitingAgentCount > 0
                                    ? AnyShapeStyle(
                                        LinearGradient(
                                            colors: [.yellow, Color(red: 1, green: 0.68, blue: 0.08)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    : AnyShapeStyle(Color.white.opacity(0.14))
                            )
                            .scaleEffect(model.displayedWaitingAgentCount > 0 ? 0.92 + pulse * 0.1 : 1)
                    }
                    .frame(width: 38)
            }
            .background(.black)
            .clipShape(.rect(bottomLeadingRadius: 9, bottomTrailingRadius: 9))
            .overlay {
                if model.displayedWaitingAgentCount > 0 {
                    ZStack {
                        NotchPulseBorder()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color(red: 1, green: 0.52, blue: 0.02).opacity(0.58),
                                        .yellow.opacity(0.92),
                                        Color(red: 1, green: 0.52, blue: 0.02).opacity(0.58),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                lineWidth: 1.8
                            )
                            .opacity(0.48 + pulse * 0.46)

                        NotchPulseBorder()
                            .trim(from: sweep.start, to: sweep.end)
                            .stroke(
                                LinearGradient(
                                    colors: [.yellow, .white.opacity(0.95), .yellow],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                            )
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                model.focusPrimaryTerminal()
            }
            .onHover(perform: onHoverChanged)
            .frame(height: maximumIslandHeight, alignment: .top)
            .clipped()
            .padding(.bottom, 6)
        }
    }

    private func frameIndex(at date: Date) -> Int {
        let elapsed = date.timeIntervalSinceReferenceDate
        switch model.displayedRobotState {
        case .idle:
            return Int(elapsed * 2) % 4
        case .working:
            return Int(elapsed * 8) % 6
        case .attention:
            return Int(elapsed * 6) % 4
        }
    }

    private func pulseAmount(at date: Date) -> CGFloat {
        CGFloat((sin(date.timeIntervalSinceReferenceDate * .pi * 1.5) + 1) / 2)
    }

    private func sweepAmount(at date: Date) -> (start: CGFloat, end: CGFloat) {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) / 6
        let progress = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        let start = min(max(CGFloat(progress) - 0.11, 0), 0.78)
        return (start, start + 0.22)
    }
}

private struct NotchPulseBorder: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(9, rect.height / 2)
        var path = Path()
        let topInset: CGFloat = 2
        path.move(to: CGPoint(x: rect.minX + 0.6, y: rect.minY + topInset))
        path.addLine(to: CGPoint(x: rect.minX + 0.6, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.maxY - 0.6),
            control: CGPoint(x: rect.minX + 0.6, y: rect.maxY - 0.6)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY - 0.6))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - 0.6, y: rect.maxY - radius),
            control: CGPoint(x: rect.maxX - 0.6, y: rect.maxY - 0.6)
        )
        path.addLine(to: CGPoint(x: rect.maxX - 0.6, y: rect.minY + topInset))
        return path
    }
}
