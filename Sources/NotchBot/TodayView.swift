import NotchBotCore
import SwiftUI

/// Panel geometry for the Today page, following `Design/NotchBot Today.dc.html`.
///
/// The view and `DisplayPanelController` both size themselves from here. They used to be able to
/// disagree, and a panel frame that is shorter than its content clips the last row.
enum TodayLayout {
    static let headerHeight: CGFloat = 42
    /// 12 top inset + 56 chart + 2 + 11 label row + 8 bottom inset.
    static let chartSectionHeight: CGFloat = 89
    static let emptyStateHeight: CGFloat = 64
    /// The mockup's `max-height: 360px` scroll region.
    static let maximumScrollHeight: CGFloat = 360

    static let groupVerticalPadding: CGFloat = 14
    static let rowSpacing: CGFloat = 3
    static let titleLineHeight: CGFloat = 16
    static let detailLineHeight: CGFloat = 14
    static let subagentTopMargin: CGFloat = 6
    static let subagentTitleLineHeight: CGFloat = 15
    static let subagentDetailLineHeight: CGFloat = 13

    /// Mirrors how `TodayGroupRow` composes: 14pt padding, title line, 3pt gap, timing line, 14pt
    /// padding, then per subagent a 3pt column gap plus its 6pt top margin, title line, 3pt gap, and
    /// timing line. Kept exact rather than generous, so a group's frame matches what it draws.
    static func groupHeight(_ group: SessionTimelineGroup) -> CGFloat {
        let parent = groupVerticalPadding * 2 + titleLineHeight + rowSpacing + detailLineHeight
        let subagent = rowSpacing + subagentTopMargin
            + subagentTitleLineHeight + rowSpacing + subagentDetailLineHeight
        return parent + CGFloat(group.subagents.count) * subagent
    }

    static func scrollHeight(for groups: [SessionTimelineGroup]) -> CGFloat {
        guard !groups.isEmpty else { return emptyStateHeight }
        let content = groups.reduce(CGFloat(0)) { $0 + groupHeight($1) + 1 }
        return min(maximumScrollHeight, content)
    }

    static func height(for groups: [SessionTimelineGroup], showsChart: Bool) -> CGFloat {
        headerHeight + 1
            + (showsChart ? chartSectionHeight + 1 : 0)
            + scrollHeight(for: groups)
            + QueueProgressFooter.height
    }
}

struct TodayView: View {
    @ObservedObject var model: ActivityModel
    @ObservedObject var navigation: PanelNavigationModel
    let onHoverChanged: (Bool) -> Void

    private var groups: [SessionTimelineGroup] { model.completedSessionsToday }

    private var chart: TodaySpendChartData? {
        TodaySpendChartData(groups: groups, now: Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().overlay(.white.opacity(0.07))

            if let chart {
                TodaySpendChartView(data: chart)
                Divider().overlay(.white.opacity(0.07))
            }

            if groups.isEmpty {
                Text("No sessions have finished today yet.")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .frame(height: TodayLayout.emptyStateHeight)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            TodayGroupRow(group: group)
                                .frame(height: TodayLayout.groupHeight(group))

                            if index < groups.count - 1 {
                                Divider().overlay(.white.opacity(0.05))
                            }
                        }
                    }
                }
                .frame(height: TodayLayout.scrollHeight(for: groups))
            }

            QueueProgressFooter(model: model, navigation: navigation)
        }
        .frame(width: 420, height: TodayLayout.height(for: groups, showsChart: chart != nil))
        .background(cardBackground)
        .contentShape(Rectangle())
        .onHover(perform: onHoverChanged)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                navigation.select(.queue)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.75))
            .accessibilityLabel("Back to the queue")
            .help("Back to the queue")

            Text("Today")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))

            Spacer()

            Text("\(model.todayCompletedRowCount) completed")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize()
        }
        .padding(.horizontal, 18)
        .frame(height: TodayLayout.headerHeight)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(Color(red: 0.06, green: 0.06, blue: 0.067).opacity(0.94))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 25, y: 20)
    }
}

private struct TodayGroupRow: View {
    let group: SessionTimelineGroup

    var body: some View {
        VStack(alignment: .leading, spacing: TodayLayout.rowSpacing) {
            HStack(spacing: 8) {
                Text(TodayFormatter.title(for: group.parent))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)

                SourceBadge(source: group.parent.source, prominent: true)

                Spacer(minLength: 8)

                Text(TodayFormatter.cost(for: group.parent))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.32))
                    .fixedSize()
            }
            .frame(height: TodayLayout.titleLineHeight)

            Text(TodayFormatter.timing(for: group.parent))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .frame(height: TodayLayout.detailLineHeight)

            ForEach(group.subagents) { subagent in
                VStack(alignment: .leading, spacing: TodayLayout.rowSpacing) {
                    HStack(spacing: 8) {
                        Text(TodayFormatter.title(for: subagent))
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)

                        SourceBadge(source: subagent.source, prominent: false)

                        Spacer(minLength: 8)

                        Text(TodayFormatter.cost(for: subagent))
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.white.opacity(0.3))
                            .fixedSize()
                    }
                    .frame(height: TodayLayout.subagentTitleLineHeight)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 1)
                    }

                    Text(TodayFormatter.timing(for: subagent))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                        .frame(height: TodayLayout.subagentDetailLineHeight)
                        .padding(.leading, 32)
                }
                .padding(.leading, 14)
                // The mockup's `margin-top: 6px` sits on top of the column's `gap: 3px`, so the
                // separation is 9pt and `groupHeight` charges `subagentTopMargin + rowSpacing`.
                .padding(.top, TodayLayout.subagentTopMargin)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, TodayLayout.groupVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct SourceBadge: View {
    let source: AgentSource
    let prominent: Bool

    var body: some View {
        Text(TodayFormatter.sourceName(source))
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(prominent ? 0.6 : 0.48))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(prominent ? 0.07 : 0.06))
            )
            .fixedSize()
    }
}

/// The cumulative-spend line for today, in the mockup's 384×56 box.
///
/// The mockup hard-codes a 9am–3pm window; a real day has to pick its own domain, so it runs from the
/// first session's start to the later of the last end and now. The flat opening and closing segments
/// carry the same meaning they do in the mockup: no spend yet, and no spend since.
struct TodaySpendChartData: Equatable {
    static let width: CGFloat = 384
    static let height: CGFloat = 56
    /// The line peaks at 85% of the box above a 4pt baseline inset, matching the mockup's scaling.
    static let peakFraction: CGFloat = 0.85
    static let baselineInset: CGFloat = 4

    let linePoints: [CGPoint]
    let axisLabels: [String]

    init?(groups: [SessionTimelineGroup], now: Date, calendar: Calendar = .autoupdatingCurrent) {
        let rows = groups.flatMap { [$0.parent] + $0.subagents }
        // Nothing was tracked, so there is no line to draw — only a flat zero that would imply a day
        // of free work. The section is dropped instead, and the panel shrinks to match.
        guard rows.contains(where: { ($0.costUSD ?? 0) > 0 }),
              let domainStart = rows.map(\.startedAt).min(),
              let lastEnd = rows.map(\.endedAt).max() else { return nil }

        // Rounded out to whole hours so the axis reads in clean hours. An instant already on the hour
        // is left where it is rather than pushed forward into an hour that has not happened yet.
        let start = calendar.dateInterval(of: .hour, for: domainStart)?.start ?? domainStart
        let latest = max(lastEnd, now)
        let end = calendar.dateInterval(of: .hour, for: latest)
            .map { $0.start == latest ? latest : $0.end } ?? latest
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return nil }

        var cumulative: Double = 0
        var samples: [(offset: TimeInterval, total: Double)] = [(0, 0)]
        for row in rows.sorted(by: { $0.endedAt < $1.endedAt }) {
            cumulative += row.costUSD ?? 0
            samples.append((row.endedAt.timeIntervalSince(start), cumulative))
        }
        samples.append((span, cumulative))

        let peak = max(cumulative, 0.01)
        linePoints = samples.map { sample in
            CGPoint(
                x: CGFloat(min(1, max(0, sample.offset / span))) * Self.width,
                y: Self.height
                    - CGFloat(sample.total / peak) * Self.height * Self.peakFraction
                    - Self.baselineInset
            )
        }
        axisLabels = [
            Self.hourLabel(start, calendar: calendar),
            Self.hourLabel(start.addingTimeInterval(span / 2), calendar: calendar),
            Self.hourLabel(end, calendar: calendar),
        ]
    }

    /// The area under the line, closed along the bottom of the box.
    var areaPoints: [CGPoint] {
        guard let first = linePoints.first, let last = linePoints.last else { return [] }
        return [CGPoint(x: first.x, y: Self.height)]
            + linePoints
            + [CGPoint(x: last.x, y: Self.height)]
    }

    /// `9am`, `12pm`, `3pm`. The mockup abbreviates to a single letter; the full meridiem reads
    /// unambiguously at a glance and still fits three labels across the plot at 9pt.
    static func hourLabel(_ date: Date, calendar: Calendar) -> String {
        let hour = calendar.component(.hour, from: date)
        let display = hour % 12 == 0 ? 12 : hour % 12
        return "\(display)\(hour < 12 ? "am" : "pm")"
    }
}

private struct TodaySpendChartView: View {
    let data: TodaySpendChartData

    private static let stroke = Color(red: 0.298, green: 0.620, blue: 0.637)

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                path(data.areaPoints, closed: true)
                    .fill(Self.stroke.opacity(0.12))
                path(data.linePoints, closed: false)
                    .stroke(
                        Self.stroke,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                    )
            }
            .frame(width: TodaySpendChartData.width, height: TodaySpendChartData.height)

            HStack(spacing: 0) {
                ForEach(Array(data.axisLabels.enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                        .fixedSize()
                    if index < data.axisLabels.count - 1 { Spacer(minLength: 0) }
                }
            }
            .frame(height: 11)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(height: TodayLayout.chartSectionHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cumulative spend today")
    }

    private func path(_ points: [CGPoint], closed: Bool) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        if closed { path.closeSubpath() }
        return path
    }
}

/// Presentation strings for Today's rows. Kept out of the views so the formats are directly testable.
enum TodayFormatter {
    static func sourceName(_ source: AgentSource) -> String {
        switch source {
        case .claude: "Claude Code"
        case .opencode: "OpenCode"
        case .preview: "Preview"
        }
    }

    /// Titles are the only presentation text the timeline persists. A row without one falls back to
    /// its source, because the working directory that names a live queue row is deliberately not
    /// stored.
    static func title(for session: CompletedSession) -> String {
        session.title ?? (session.isSubagent ? "Subagent" : sourceName(session.source))
    }

    /// `nil` cost is "no cost data", which is not the same claim as `$0.00`.
    static func cost(for session: CompletedSession) -> String {
        guard let cost = session.costUSD else { return "no cost data" }
        return String(format: "~$%.2f", cost)
    }

    static func timing(for session: CompletedSession, calendar: Calendar = .autoupdatingCurrent) -> String {
        "\(timeRange(from: session.startedAt, to: session.endedAt, calendar: calendar)) · \(duration(session.duration))"
    }

    /// `2:41–2:44pm`. The opening meridiem is shown only when it differs from the closing one, so a
    /// range that straddles noon stays unambiguous without adding noise to one that does not.
    static func timeRange(from start: Date, to end: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let startMeridiem = meridiem(start, calendar: calendar)
        let endMeridiem = meridiem(end, calendar: calendar)
        let opening = clockText(start, calendar: calendar)
            + (startMeridiem == endMeridiem ? "" : startMeridiem)
        return "\(opening)–\(clockText(end, calendar: calendar))\(endMeridiem)"
    }

    static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "0s" }
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    private static func clockText(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 0
        let display = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d", display, components.minute ?? 0)
    }

    private static func meridiem(_ date: Date, calendar: Calendar) -> String {
        calendar.component(.hour, from: date) < 12 ? "am" : "pm"
    }
}
