import NotchBotCore
import SwiftUI

struct NotchCharacterView: View {
    let character: NotchCharacter
    let state: RobotState
    let date: Date
    let frameIndex: Int

    var body: some View {
        switch character {
        case .retro:
            Image(nsImage: RobotAtlas.shared.frame(state: state, index: frameIndex))
                .interpolation(.none)
                .resizable()
                .offset(y: jumpOffset)
        case .blob:
            BlobCharacter(state: state, date: date)
        case .orb:
            OrbCharacter(state: state, date: date)
        case .cat:
            CatCharacter(state: state, date: date)
        }
    }

    private var jumpOffset: CGFloat {
        guard state == .attention else { return 0 }
        let offsets: [CGFloat] = [2, 1, -1, -3, -4, -3, -1, 1]
        return offsets[Int(date.timeIntervalSinceReferenceDate * 8) % offsets.count]
    }
}

private struct CatCharacter: View {
    let state: RobotState
    let date: Date

    private var phase: Double { date.timeIntervalSinceReferenceDate }

    var body: some View {
        switch state {
        case .idle:
            sleepingCat
        case .working:
            activeCat
        case .attention:
            attentionCat
        }
    }

    private var sleepingCat: some View {
        ZStack {
            CatTail()
                .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 10, height: 9)
                .offset(x: 9, y: -1)

            UnevenRoundedRectangle(
                topLeadingRadius: 8,
                bottomLeadingRadius: 7,
                bottomTrailingRadius: 8,
                topTrailingRadius: 7
            )
            .fill(.white)
            .frame(width: 21, height: 11)
            .offset(y: 3)

            CatEars()
                .fill(.white)
                .frame(width: 13, height: 7)
                .offset(x: -4, y: -5)

            CatFace(sleeping: true)
                .offset(x: -3, y: 2)

            SleepMarks(phase: phase)
                .offset(x: 9, y: -10)
        }
        .offset(y: CGFloat(sin(phase * 2) * 0.5))
    }

    private var activeCat: some View {
        ZStack {
            CatTail()
                .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 10, height: 11)
                .rotationEffect(.degrees(sin(phase * 6) * 12), anchor: .bottomLeading)
                .offset(x: 9, y: 2)

            CatEars()
                .fill(.white)
                .frame(width: 16, height: 8)
                .offset(y: -7)

            UnevenRoundedRectangle(
                topLeadingRadius: 8,
                bottomLeadingRadius: 8,
                bottomTrailingRadius: 9,
                topTrailingRadius: 8
            )
            .fill(.white)
            .frame(width: 18, height: 16)
            .offset(y: 2)

            CatFace(sleeping: false)
                .offset(y: -1)
        }
        .scaleEffect(x: 1 - squash * 0.08, y: 1 + squash * 0.1)
    }

    private var attentionCat: some View {
        ZStack {
            CatTail()
                .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 10, height: 11)
                .rotationEffect(.degrees(sin(phase * 10) * 16), anchor: .bottomLeading)
                .offset(x: 9, y: 3)

            WavingArm(phase: phase)
                .offset(x: 9.5, y: 1)

            CatEars()
                .fill(.white)
                .frame(width: 16, height: 8)
                .offset(y: -7)

            UnevenRoundedRectangle(
                topLeadingRadius: 8,
                bottomLeadingRadius: 8,
                bottomTrailingRadius: 9,
                topTrailingRadius: 8
            )
            .fill(.white)
            .frame(width: 18, height: 16)
            .offset(y: 2)

            CatFace(sleeping: false)
                .offset(y: -1)
        }
        .rotationEffect(.degrees(-8))
    }

    private var squash: CGFloat {
        CGFloat(sin(phase * 8))
    }
}

private struct CatFace: View {
    let sleeping: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 4) {
                Capsule().frame(width: 3, height: sleeping ? 1 : 4)
                Capsule().frame(width: 3, height: sleeping ? 1 : 4)
            }
            .offset(y: -1)

            Circle()
                .frame(width: 2, height: 2)
                .offset(y: 3)
        }
        .foregroundStyle(Color(red: 0.05, green: 0.05, blue: 0.06))
    }
}

private struct CatEars: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 1, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + 3.5, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX - 1, y: rect.maxY))
        path.closeSubpath()
        path.move(to: CGPoint(x: rect.midX + 1, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - 3.5, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct CatTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + 1),
            control1: CGPoint(x: rect.maxX * 0.55, y: rect.maxY),
            control2: CGPoint(x: rect.maxX, y: rect.midY)
        )
        return path
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
                    .offset(x: 9, y: -8)
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
                    .offset(x: 9, y: -8)
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
        VStack(spacing: -3) {
            Text("z")
            Text("Z")
        }
        .font(.system(size: 7, weight: .black, design: .rounded))
        .foregroundStyle(.white.opacity(0.78 + sin(phase * 2) * 0.17))
        .offset(y: CGFloat(-sin(phase * 2) * 1.2))
    }
}
