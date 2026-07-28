import NotchBotCore
import SwiftUI

struct NotchCharacterView: View {
    let character: NotchCharacter
    let state: RobotState
    let date: Date

    var body: some View {
        switch character {
        case .retro:
            EmptyView()
        case .blob:
            BlobCharacter(state: state, date: date)
        case .orb:
            OrbCharacter(state: state, date: date)
        }
    }
}

private struct BlobCharacter: View {
    let state: RobotState
    let date: Date

    private var phase: Double {
        date.timeIntervalSinceReferenceDate
    }

    private var isIdle: Bool { state == .idle }

    var body: some View {
        ZStack {
            if isIdle {
                SleepMarks(phase: phase)
                    .offset(x: 8, y: -7)
            }

            arm
            bodyShape
            antenna
            eyes
        }
        .rotationEffect(state == .attention ? .degrees(-10) : .zero)
        .offset(y: bob)
    }

    private var bodyShape: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 9,
            bottomLeadingRadius: 7,
            bottomTrailingRadius: 9,
            topTrailingRadius: 7
        )
        .fill(Color(red: 0.95, green: 0.95, blue: 0.94))
        .frame(width: 18, height: 15)
        .offset(y: 3)
    }

    @ViewBuilder
    private var arm: some View {
        if state == .attention {
            WavingArm(phase: phase)
                .offset(x: 9, y: 1)
        }
    }

    private var antenna: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Color(red: 0.95, green: 0.95, blue: 0.94))
                .frame(width: 3, height: 3)
            Capsule()
                .fill(Color(red: 0.95, green: 0.95, blue: 0.94))
                .frame(width: 1.5, height: 5)
        }
        .rotationEffect(.degrees(state == .working ? sin(phase * 16) * 18 : 0), anchor: .bottom)
        .offset(y: -8)
    }

    private var eyes: some View {
        HStack(spacing: 4) {
            eye
            eye
        }
        .offset(y: 1)
    }

    private var eye: some View {
        Capsule()
            .fill(Color(red: 0.05, green: 0.05, blue: 0.06))
            .frame(width: 3, height: isIdle ? 1 : 4)
    }

    private var bob: CGFloat {
        let speed = state == .working ? 8.0 : (state == .attention ? 12.0 : 2.2)
        let distance = state == .idle ? 0.8 : 1.5
        return CGFloat(sin(phase * speed) * distance)
    }
}

private struct OrbCharacter: View {
    let state: RobotState
    let date: Date

    private var phase: Double {
        date.timeIntervalSinceReferenceDate
    }

    private var isIdle: Bool { state == .idle }

    var body: some View {
        ZStack {
            if isIdle {
                SleepMarks(phase: phase)
                    .offset(x: 8, y: -7)
            }

            hand
            Circle()
                .fill(Color(red: 0.95, green: 0.95, blue: 0.94))
                .frame(width: 19, height: 19)

            HStack(spacing: state == .attention ? 4 : 3) {
                eye
                eye
            }
            .offset(y: -1)
        }
        .scaleEffect(x: stretchX, y: stretchY)
        .rotationEffect(state == .attention ? .degrees(-10) : .zero)
    }

    @ViewBuilder
    private var hand: some View {
        if state == .attention {
            WavingArm(phase: phase)
                .offset(x: 9.5, y: 1)
        }
    }

    private var eye: some View {
        Capsule()
            .fill(Color(red: 0.05, green: 0.05, blue: 0.06))
            .frame(
                width: state == .attention ? 3.5 : 3,
                height: isIdle ? 1 : (state == .attention ? 6 : 4)
            )
    }

    private var stretchX: CGFloat {
        1 - squash * 0.08
    }

    private var stretchY: CGFloat {
        1 + squash * 0.1
    }

    private var squash: CGFloat {
        let speed = state == .working ? 8.0 : (state == .attention ? 10.0 : 2.0)
        return CGFloat(sin(phase * speed))
    }
}

private struct WavingArm: View {
    let phase: Double

    var body: some View {
        HStack(spacing: -1) {
            Capsule()
                .frame(width: 8, height: 3.5)
            Circle()
                .frame(width: 4.5, height: 4.5)
        }
        .foregroundStyle(Color(red: 0.95, green: 0.95, blue: 0.94))
        .frame(width: 12, height: 8, alignment: .leading)
        .rotationEffect(.degrees(-28 + sin(phase * 18) * 42), anchor: .leading)
    }
}

private struct SleepMarks: View {
    let phase: Double

    var body: some View {
        VStack(spacing: -2) {
            Text("z")
            Text("Z")
        }
        .font(.system(size: 5, weight: .bold, design: .rounded))
        .foregroundStyle(.white.opacity(0.55 + sin(phase * 2) * 0.2))
        .offset(y: CGFloat(-sin(phase * 2) * 0.8))
    }
}
