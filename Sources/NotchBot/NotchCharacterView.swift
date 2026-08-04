import NotchBotCore
import SwiftUI

struct NotchCharacterView: View {
    let character: NotchCharacter
    let state: RobotState
    let date: Date
    let frameIndex: Int
    let coolnessTier: CoolnessTier

    var body: some View {
        ZStack {
            if coolnessTier >= .glow {
                CoolnessPlate(date: date)
            }

            ZStack {
                characterBody
                    .scaleEffect(x: retroBodyScale.width, y: retroBodyScale.height)
                CharacterAccessoryView(
                    tier: coolnessTier,
                    character: character,
                    state: state
                )
            }
            .scaleEffect(x: characterScale.width, y: characterScale.height)
            .rotationEffect(characterRotation)
            .offset(y: characterOffsetY)
        }
    }

    @ViewBuilder
    private var characterBody: some View {
        switch character {
        case .retro:
            Image(nsImage: RobotAtlas.shared.frame(state: state, index: frameIndex))
                .interpolation(.none)
                .resizable()
        case .blob:
            BlobCharacter(state: state, date: date)
        case .orb:
            OrbCharacter(state: state, date: date)
        case .cat:
            CatCharacter(state: state, date: date)
        }
    }

    private var phase: Double {
        date.timeIntervalSinceReferenceDate
    }

    private var retroBodyScale: CGSize {
        character == .retro && state == .attention
            ? CGSize(width: 0.9, height: 1)
            : CGSize(width: 1, height: 1)
    }

    private var characterScale: CGSize {
        let squash: CGFloat
        switch character {
        case .orb:
            let speed = state == .working ? 8.0 : (state == .attention ? 10.0 : 2.0)
            squash = CGFloat(sin(phase * speed))
        case .cat where state == .working:
            squash = CGFloat(sin(phase * 8))
        default:
            return CGSize(width: 1, height: 1)
        }
        return CGSize(width: 1 - squash * 0.08, height: 1 + squash * 0.1)
    }

    private var characterRotation: Angle {
        guard state == .attention else { return .zero }
        return switch character {
        case .retro: .zero
        case .blob, .orb: .degrees(-10)
        case .cat: .degrees(-8)
        }
    }

    private var characterOffsetY: CGFloat {
        switch character {
        case .retro where state == .attention:
            let offsets: [CGFloat] = [2, 1, -1, -3, -4, -3, -1, 1]
            return offsets[Int(phase * 8) % offsets.count]
        case .blob:
            let speed = state == .working ? 8.0 : (state == .attention ? 12.0 : 2.2)
            let distance = state == .idle ? 0.8 : 1.5
            return CGFloat(sin(phase * speed) * distance)
        case .cat where state == .idle:
            return CGFloat(sin(phase * 2) * 0.5)
        default:
            return 0
        }
    }
}

private struct CharacterAccessoryView: View {
    let tier: CoolnessTier
    let character: NotchCharacter
    let state: RobotState

    var body: some View {
        ZStack {
            if tier >= .shades {
                NeonShades()
                    .offset(shadesOffset)
            }

            if tier == .crown {
                NeonCrown()
                    .rotationEffect(.degrees(-20))
                    .offset(crownOffset)
            } else if tier == .cap {
                TechBroCap()
                    .rotationEffect(.degrees(-6))
                    .offset(capOffset)
            }
        }
        .allowsHitTesting(false)
    }

    private var shadesOffset: CGSize {
        switch (character, state) {
        case (.retro, .idle): CGSize(width: -3, height: -2)
        case (.retro, .working): CGSize(width: 3, height: -3)
        case (.retro, .attention): CGSize(width: 0, height: -3)
        case (.blob, _): CGSize(width: 0, height: 0)
        case (.orb, _): CGSize(width: 0, height: -1)
        case (.cat, .idle): CGSize(width: -3, height: 1)
        case (.cat, _): CGSize(width: 0, height: -1)
        }
    }

    private var crownOffset: CGSize {
        switch (character, state) {
        case (.retro, .attention): CGSize(width: -4, height: -7)
        case (.blob, .attention): CGSize(width: -4, height: -8)
        case (.orb, .attention): CGSize(width: -4, height: -8)
        case (.cat, .attention): CGSize(width: -4, height: -8)
        case (.retro, _): CGSize(width: -4, height: -11)
        case (.blob, _): CGSize(width: -4, height: -11)
        case (.orb, _): CGSize(width: -4, height: -11)
        case (.cat, .idle): CGSize(width: -5, height: -11)
        case (.cat, .working): CGSize(width: -4, height: -11)
        }
    }

    private var capOffset: CGSize {
        switch (character, state) {
        case (.retro, .attention): CGSize(width: -1, height: -8)
        case (.blob, .attention), (.orb, .attention): CGSize(width: -1, height: -9)
        case (.cat, .attention): CGSize(width: -1, height: -10)
        case (.retro, _), (.blob, _), (.orb, _): CGSize(width: -1, height: -10)
        case (.cat, .idle): CGSize(width: -2, height: -10)
        case (.cat, .working): CGSize(width: -1, height: -11)
        }
    }
}

private struct CoolnessPlate: View {
    let date: Date

    private var pulse: CGFloat {
        CGFloat((sin(date.timeIntervalSinceReferenceDate * 2.6) + 1) / 2)
    }

    var body: some View {
        ZStack {
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.08, green: 0.82, blue: 1).opacity(0.34 + pulse * 0.18),
                            Color(red: 0.05, green: 0.45, blue: 0.72).opacity(0.2),
                            Color.black.opacity(0.75),
                        ],
                        center: .center,
                        startRadius: 1,
                        endRadius: 13
                    )
                )
                .frame(width: 27, height: 7)

            Ellipse()
                .fill(Color(red: 0.08, green: 0.9, blue: 1).opacity(0.12 + pulse * 0.1))
                .frame(width: 19, height: 3)

            Ellipse()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.2, green: 0.96, blue: 1),
                            Color(red: 0.16, green: 0.54, blue: 1),
                            Color(red: 0.2, green: 0.96, blue: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1.2
                )
                .frame(width: 27, height: 7)

            Ellipse()
                .trim(from: 0.04, to: 0.46)
                .stroke(
                    Color.white.opacity(0.38 + pulse * 0.22),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round)
                )
                .frame(width: 23, height: 5)
        }
        .scaleEffect(0.97 + pulse * 0.04)
        .offset(y: 9)
        .shadow(
            color: Color(red: 0.08, green: 0.88, blue: 1).opacity(0.38 + pulse * 0.2),
            radius: 4,
            y: 1
        )
        .allowsHitTesting(false)
    }
}

private struct NeonShades: View {
    private let lensColor = Color(red: 0.16, green: 0.88, blue: 1)
    private let frameColor = Color(red: 0.34, green: 0.08, blue: 0.52)

    var body: some View {
        HStack(spacing: 0) {
            lens
            Rectangle()
                .fill(frameColor)
                .frame(width: 3, height: 1.5)
            lens
        }
        .frame(width: 15, height: 6)
    }

    private var lens: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(lensColor)
            .frame(width: 6, height: 5)
            .overlay {
                RoundedRectangle(cornerRadius: 1.5)
                    .stroke(frameColor, lineWidth: 1.5)
            }
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(Color(red: 1, green: 0.16, blue: 0.72))
                    .frame(width: 1.5, height: 1.5)
                    .padding(1)
            }
    }
}

private struct NeonCrown: View {
    var body: some View {
        CrownShape()
            .fill(Color(red: 1, green: 0.76, blue: 0.02))
            .frame(width: 13, height: 8)
            .overlay {
                CrownShape().stroke(.black.opacity(0.9), lineWidth: 1.4)
            }
    }
}

private struct TechBroCap: View {
    private let capColor = Color(red: 0.08, green: 0.3, blue: 0.78)
    private let accentColor = Color(red: 1, green: 0.72, blue: 0.04)

    var body: some View {
        ZStack {
            CapCrownShape()
                .fill(capColor)
                .frame(width: 16, height: 10)
                .overlay {
                    CapCrownShape().stroke(accentColor, lineWidth: 1.3)
                }

            Capsule()
                .fill(capColor)
                .frame(width: 11, height: 3)
                .overlay {
                    Capsule().stroke(accentColor, lineWidth: 1)
                }
                .offset(x: 7, y: 3.5)

            Circle()
                .fill(accentColor)
                .frame(width: 3, height: 3)
                .offset(y: -1.5)
        }
        .frame(width: 22, height: 11)
    }
}

private struct CapCrownShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + 1, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - 1, y: rect.midY),
            control: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct CrownShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.28))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.28, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.28))
        path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + 1, y: rect.maxY))
        path.closeSubpath()
        return path
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
