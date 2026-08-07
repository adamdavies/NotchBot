import Foundation
import NotchBotCore
import Testing
@testable import NotchBot

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}

private let noon = Date(timeIntervalSince1970: 1_780_012_800)

private func todayRow(
    _ sessionID: String,
    source: AgentSource = .claude,
    parent: String? = nil,
    title: String? = nil,
    hour: Int,
    minute: Int = 0,
    minutes: Double,
    cost: Double? = nil
) -> CompletedSession {
    // Whole minutes, so a fractional-hour rounding error cannot shift a formatted clock time.
    let dayStart = calendar.startOfDay(for: noon)
    let startedAt = dayStart.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
    return CompletedSession(
        cycleID: CompletedSession.cycleID(source: source, sessionID: sessionID, startedAt: startedAt),
        source: source,
        sessionID: sessionID,
        parentSessionID: parent,
        groupID: parent ?? sessionID,
        title: title,
        startedAt: startedAt,
        endedAt: startedAt.addingTimeInterval(minutes * 60),
        costUSD: cost
    )
}

// MARK: - Navigation

@Test @MainActor func navigationStartsOnTheQueueAndSwitchesToToday() {
    let navigation = PanelNavigationModel()
    #expect(navigation.page == .queue)

    navigation.select(.today)
    #expect(navigation.page == .today)

    navigation.select(.queue)
    #expect(navigation.page == .queue)
}

@Test @MainActor func closingThePanelReturnsItToTheQueue() {
    let navigation = PanelNavigationModel(page: .today)

    navigation.reset()
    #expect(navigation.page == .queue)
}

@Test @MainActor func eachDisplayNavigatesIndependently() {
    // Two panels, as two displays have: selecting Today on one leaves the other on the queue.
    let first = PanelNavigationModel()
    let second = PanelNavigationModel()

    first.select(.today)

    #expect(first.page == .today)
    #expect(second.page == .queue)
}

// MARK: - Row formatting

@Test func aRowWithoutATitleFallsBackToItsSourceRatherThanAPath() {
    #expect(TodayFormatter.title(for: todayRow("s", hour: 9, minutes: 5)) == "Claude Code")
    #expect(TodayFormatter.title(for: todayRow("s", source: .opencode, hour: 9, minutes: 5)) == "OpenCode")
    #expect(TodayFormatter.title(for: todayRow("c", parent: "p", hour: 9, minutes: 5)) == "Subagent")
    #expect(TodayFormatter.title(for: todayRow("s", title: "Refactor auth", hour: 9, minutes: 5))
        == "Refactor auth")
}

@Test func anAbsentCostReadsAsUntrackedAndAZeroReadsAsFree() {
    #expect(TodayFormatter.cost(for: todayRow("a", hour: 9, minutes: 5)) == "no cost data")
    #expect(TodayFormatter.cost(for: todayRow("b", hour: 9, minutes: 5, cost: 0)) == "~$0.00")
    #expect(TodayFormatter.cost(for: todayRow("c", hour: 9, minutes: 5, cost: 1.5)) == "~$1.50")
}

@Test func aTimeRangeShowsTheOpeningMeridiemOnlyWhenItDiffers() {
    let morning = todayRow("a", hour: 9, minute: 14, minutes: 8)
    #expect(TodayFormatter.timeRange(from: morning.startedAt, to: morning.endedAt, calendar: calendar)
        == "9:14–9:22am")

    let afternoon = todayRow("b", hour: 14, minute: 41, minutes: 3)
    #expect(TodayFormatter.timeRange(from: afternoon.startedAt, to: afternoon.endedAt, calendar: calendar)
        == "2:41–2:44pm")

    // Straddling noon is spelled out on both sides so it cannot be misread.
    let straddling = todayRow("c", hour: 11, minute: 50, minutes: 40)
    #expect(TodayFormatter.timeRange(from: straddling.startedAt, to: straddling.endedAt, calendar: calendar)
        == "11:50am–12:30pm")

    // Midnight and noon read as 12, not 0.
    let midnight = todayRow("d", hour: 0, minute: 5, minutes: 5)
    #expect(TodayFormatter.timeRange(from: midnight.startedAt, to: midnight.endedAt, calendar: calendar)
        == "12:05–12:10am")
}

@Test func durationsScaleFromSecondsToHours() {
    #expect(TodayFormatter.duration(0) == "0s")
    #expect(TodayFormatter.duration(-5) == "0s")
    #expect(TodayFormatter.duration(.nan) == "0s")
    #expect(TodayFormatter.duration(45) == "45s")
    #expect(TodayFormatter.duration(59.6) == "1m")
    #expect(TodayFormatter.duration(180) == "3m")
    #expect(TodayFormatter.duration(33 * 60) == "33m")
    #expect(TodayFormatter.duration(3_600) == "1h")
    #expect(TodayFormatter.duration(3_600 + 24 * 60) == "1h 24m")
}

@Test func timingJoinsTheRangeAndDuration() {
    let row = todayRow("a", hour: 14, minute: 41, minutes: 3)
    #expect(TodayFormatter.timing(for: row, calendar: calendar) == "2:41–2:44pm · 3m")
}

// MARK: - Spend chart

@Test func theChartIsOmittedWhenNothingWasTracked() {
    let untracked = [SessionTimelineGroup(parent: todayRow("a", hour: 9, minutes: 10))]
    #expect(TodaySpendChartData(groups: untracked, now: noon, calendar: calendar) == nil)

    // An observed zero is still no line to draw.
    let free = [SessionTimelineGroup(parent: todayRow("a", hour: 9, minutes: 10, cost: 0))]
    #expect(TodaySpendChartData(groups: free, now: noon, calendar: calendar) == nil)

    #expect(TodaySpendChartData(groups: [], now: noon, calendar: calendar) == nil)
}

@Test func theChartAccumulatesSpendAcrossTheDayAndStaysInsideItsBox() throws {
    let groups = [
        SessionTimelineGroup(parent: todayRow("late", hour: 14, minutes: 30, cost: 2)),
        SessionTimelineGroup(parent: todayRow("early", hour: 9, minutes: 30, cost: 1)),
    ]
    let chart = try #require(TodaySpendChartData(groups: groups, now: noon, calendar: calendar))

    // Opens at zero on the left edge and closes flat at the right edge.
    #expect(chart.linePoints.count == 4)
    #expect(chart.linePoints.first?.x == 0)
    #expect(chart.linePoints.first?.y == TodaySpendChartData.height - TodaySpendChartData.baselineInset)
    #expect(chart.linePoints.last?.x == TodaySpendChartData.width)
    #expect(chart.linePoints.last?.y == chart.linePoints[2].y)

    // The peak sits at the scaled top, and every point stays within the box.
    let peakY = TodaySpendChartData.height
        - TodaySpendChartData.height * TodaySpendChartData.peakFraction
        - TodaySpendChartData.baselineInset
    #expect(abs((chart.linePoints.last?.y ?? 0) - peakY) < 0.001)
    #expect(chart.linePoints.allSatisfy { $0.x >= 0 && $0.x <= TodaySpendChartData.width })
    #expect(chart.linePoints.allSatisfy { $0.y >= 0 && $0.y <= TodaySpendChartData.height })
    // Cumulative, so the line only ever descends on screen.
    #expect(zip(chart.linePoints, chart.linePoints.dropFirst()).allSatisfy { $1.y <= $0.y })
}

@Test func theChartAreaClosesAlongTheBaseline() throws {
    let groups = [SessionTimelineGroup(parent: todayRow("a", hour: 9, minutes: 30, cost: 1))]
    let chart = try #require(TodaySpendChartData(groups: groups, now: noon, calendar: calendar))

    let area = chart.areaPoints
    #expect(area.count == chart.linePoints.count + 2)
    #expect(area.first?.y == TodaySpendChartData.height)
    #expect(area.last?.y == TodaySpendChartData.height)
}

@Test func theChartAxisLabelsSpanTheDomain() throws {
    let groups = [SessionTimelineGroup(parent: todayRow("a", hour: 9, minute: 15, minutes: 30, cost: 1))]
    let chart = try #require(TodaySpendChartData(
        groups: groups,
        now: calendar.startOfDay(for: noon).addingTimeInterval(15 * 3_600),
        calendar: calendar
    ))

    // 9am floor through a 3pm ceiling, with the midpoint between them.
    #expect(chart.axisLabels == ["9am", "12pm", "3pm"])
}

@Test func theChartDomainExtendsToNowSoAQuietStretchIsVisible() throws {
    let groups = [SessionTimelineGroup(parent: todayRow("a", hour: 9, minutes: 30, cost: 1))]
    let now = calendar.startOfDay(for: noon).addingTimeInterval(17 * 3_600)
    let chart = try #require(TodaySpendChartData(groups: groups, now: now, calendar: calendar))

    #expect(chart.axisLabels.first == "9am")
    #expect(chart.axisLabels.last == "5pm")
    // The session's own point lands well left of the closing flat segment.
    #expect((chart.linePoints[1].x) < TodaySpendChartData.width / 2)
}

@Test func subagentSpendCountsTowardsTheChart() throws {
    let group = SessionTimelineGroup(
        parent: todayRow("p", hour: 9, minutes: 60, cost: 1),
        subagents: [todayRow("c", parent: "p", hour: 9, minute: 15, minutes: 20, cost: 3)]
    )
    let chart = try #require(TodaySpendChartData(groups: [group], now: noon, calendar: calendar))

    // Two sessions plus the opening and closing points.
    #expect(chart.linePoints.count == 4)
}

// MARK: - Layout

@Test func theTodayCardGrowsWithItsGroupsAndCapsAtTheScrollHeight() {
    let one = [SessionTimelineGroup(parent: todayRow("a", hour: 9, minutes: 5))]
    let two = one + [SessionTimelineGroup(parent: todayRow("b", hour: 10, minutes: 5))]

    #expect(TodayLayout.height(for: two, showsChart: false)
        > TodayLayout.height(for: one, showsChart: false))
    // The chart section only costs height when it is actually drawn.
    #expect(TodayLayout.height(for: one, showsChart: true)
        == TodayLayout.height(for: one, showsChart: false) + TodayLayout.chartSectionHeight + 1)

    let many = (0..<40).map {
        SessionTimelineGroup(parent: todayRow("s\($0)", hour: 9, minutes: 5))
    }
    #expect(TodayLayout.scrollHeight(for: many) == TodayLayout.maximumScrollHeight)
}

@Test func aGroupWithSubagentsIsTallerThanOneWithout() {
    let alone = SessionTimelineGroup(parent: todayRow("p", hour: 9, minutes: 5))
    let withChild = SessionTimelineGroup(
        parent: todayRow("p", hour: 9, minutes: 5),
        subagents: [todayRow("c", parent: "p", hour: 9, minute: 6, minutes: 2)]
    )

    #expect(TodayLayout.groupHeight(withChild) > TodayLayout.groupHeight(alone))
}

@Test func anEmptyTodayStillHasAReadableCardHeight() {
    let height = TodayLayout.height(for: [], showsChart: false)

    #expect(TodayLayout.scrollHeight(for: []) == TodayLayout.emptyStateHeight)
    #expect(height == TodayLayout.headerHeight + 1
        + TodayLayout.emptyStateHeight
        + QueueProgressFooter.height)
}
