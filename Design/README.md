# Design Reference

Imported from the Claude Design project **macOS Notch Agent Activity**
(`081fdb17-7850-468f-9c6a-0620355eefea`), files `NotchBot Panel.dc.html` and
`NotchBot Today.dc.html`.

Open either `.dc.html` directly in a browser to render it; `support.js` is the generated
`dc-runtime` harness the project ships and is vendored unmodified so the mockups render
offline. None of these files are compiled into the app or read at runtime — this directory
is reference material only.

The two mockups overlap. `NotchBot Today.dc.html` is the authoritative spec for the Today
page itself; `NotchBot Panel.dc.html` shows the same page inside the panel and specifies
how it is reached. Where they differ, the difference is only that the standalone file's back
control is an `<a href>` to the other file rather than in-panel navigation.

## Panel mockup: the queue

The queue half of `NotchBot Panel.dc.html` is the shipped panel plus the per-row context-window
meter added in 0.9.0. Header, row anatomy, footer, and card chrome already match
`Sources/NotchBot/AgentQueueView.swift`, so those are recorded below only to confirm the design
does not ask for a change. Do not churn shipped values to chase the mockup's approximations.

| Element | Mockup | `AgentQueueView.swift` | Status |
| --- | --- | --- | --- |
| Card | 420 wide, radius 22, `rgba(15,15,17,0.94)`, 1px `white/0.08`, shadow y20 b50 `black/0.45` | `cardBackground`, `.frame(width: 420)` | matches |
| Header | "Bots" 14/700; summary 11; "Clear All" pill radius 8 on `white/0.09` | lines 10–30 | matches |
| Status dot | 8×8 circle | `Circle().frame(width: 8, height: 8)` | matches |
| Row title | 13/600 | `.system(size: 13, weight: .semibold)` | matches |
| Status + cost | trailing stack, 11 over 10 | lines 124–133 | matches |
| Dismiss | 22×22 circle on `white/0.07` | lines 136–141 | matches |
| Task line | 12, indent 18 | `activityDescription`, `.padding(.leading, 18)` | matches |
| Row padding | 12 vertical / 18 horizontal | `.padding(.horizontal, 18).padding(.vertical, 12)` | matches |
| Context meter | see below | `ContextMeterView` and `ContextMeter` | implemented for 0.9.0 |
| Footer spend pill | `onClick` opens Today, `cursor:pointer` | `QueueProgressFooter`, `navigation.select(.today)` | implemented for 1.0.0 |

The mockup's action row reads Approve / Reject / Reply against a green
`oklch(0.6 0.15 150)`. The shipped buttons are Allow Once / Always / Decline. The mockup
labels are placeholder concept copy; the shipped labels carry the real permission
semantics and should stay.

## Context meter spec

Structure, below the task line and above nothing else in the row:

```
HStack(spacing: 6)            // .padding(.leading, 18), .padding(.top, 2)
├─ track   height 3, cornerRadius 2, fill white/0.08
│   └─ fill   width = pct%, height 3, cornerRadius 2, tinted
└─ label   9pt, "<pct>% ctx", trailing, no wrap
```

OKLCH tokens converted to the sRGB form used elsewhere in this file:

| Token | OKLCH | sRGB | Hex |
| --- | --- | --- | --- |
| Neutral fill | `oklch(0.65 0.08 200)` | `Color(red: 0.298, green: 0.620, blue: 0.637)` | `#4B9EA2` |
| Warning fill | `oklch(0.72 0.16 45)` | `Color(red: 0.958, green: 0.499, blue: 0.276)` | `#F47F46` |
| Meter label | `oklch(0.5 0.01 90)` | ≈ `.white.opacity(0.35)` | `#65625C` |

The mockup shows only two fill colours (neutral, and warning on the 84% row). The
0.9.0 plan calls for a third **strong-warning** band at 90–100% that the mockup does not
define. Derived to sit in the same family at matching lightness:

| Token | OKLCH | sRGB | Hex |
| --- | --- | --- | --- |
| Strong warning (derived, not from mockup) | `oklch(0.62 0.19 25)` | `Color(red: 0.885, green: 0.285, blue: 0.280)` | `#E14847` |

### Known conflict: visibility threshold

**The mockup and the 0.9.0 plan disagree, and the plan was followed.**

The mockup renders a meter on every row, including rows at 19% and 38%. The 0.9.0 plan
specifies the meter is hidden below 50%, neutral 50–74, warning 75–89, strong 90–100,
with no reserved space and no row-height increase when hidden.

The plan's thresholds are implemented, because a meter that is present and near-empty on
every idle row is noise — it costs vertical space in a panel capped at five visible rows
to say "there is plenty of context left." The mockup's five rows are all populated sample
data; it does not show the resting state of a mostly-idle queue.

If the always-visible treatment is wanted instead, the change is confined to the
visibility guard in the row body and `rowHeight(for:)` — the colour bands and geometry
above are unaffected.

## Today page spec

Implemented for 1.0.0 in `Sources/NotchBot/TodayView.swift`, with geometry in `TodayLayout`,
chart maths in `TodaySpendChartData`, and row strings in `TodayFormatter`.

Header, matching the queue header's 42pt height and 18pt gutters:

```
HStack(spacing: 10)
├─ back    22×22 circle on white/0.07, chevron.left            // navigation.select(.queue)
├─ "Today" 14/700
└─ "<N> completed" 11, trailing                                 // parents + subagents
```

Chart section — 12pt top inset, 56pt plot, 2pt gap, 11pt label row, 8pt bottom inset
(`chartSectionHeight` 89):

| Element | Mockup | Implementation |
| --- | --- | --- |
| Plot box | `viewBox 0 0 384 56` (420 − 36 gutters) | `TodaySpendChartData.width/.height` |
| Area | `oklch(0.65 0.08 200)` at 0.12 | same stroke colour at `opacity(0.12)` |
| Line | same colour, 1.5 stroke, round cap/join | `StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)` |
| Scaling | `y = 56 − (c/max)·56·0.85 − 4` | `peakFraction` 0.85, `baselineInset` 4 |
| Axis labels | three 9pt labels, space-between (`9a`/`12p`/`3p`; see deviation 1) | `axisLabels`, `.white.opacity(0.35)` |

Rows — 14pt vertical padding, 18pt gutters, 3pt line spacing:

```
VStack(spacing: 3)
├─ HStack(spacing: 8)
│  ├─ title  13/600
│  ├─ badge  9/700 on white/0.07, radius 5, padding 2×5
│  └─ cost   10, trailing
├─ "<range> · <duration>"  11
└─ per subagent, indented 14 with a 1px white/0.1 left rule at 10:
   ├─ HStack(spacing: 8): title 12 · badge 9/700 on white/0.06 · cost 10 trailing
   └─ "<range> · <duration>"  10, indented 32
```

The scroll region caps at the mockup's `max-height: 360px` (`maximumScrollHeight`).

### Deviations from the Today mockup

Five, each deliberate:

1. **Meridiems are spelled out.** The mockup abbreviates to a single letter — `9a`, `12p`,
   `2:41–2:44p`. Reviewed on a real panel, `10p` reads as a truncation rather than a time, so both
   the axis labels and the row time ranges use `am`/`pm`. No space before the meridiem, keeping the
   mockup's compactness; three `12pm`-width labels still fit across the 384pt plot at 9pt.
2. **The chart is omitted when nothing was tracked.** The mockup always draws it. A day with
   no observed cost would render a flat line at zero, which reads as "a day of free work"
   rather than "cost tracking was off". `TodaySpendChartData.init` returns `nil` in that case
   and the panel shrinks by `chartSectionHeight + 1`.
3. **The chart domain is derived, not fixed.** The mockup hard-codes a 360-minute 9a–3p window.
   The implementation runs from the first session's start hour to the later of the last end and
   now, rounded out to whole hours, with the three axis labels at the start, midpoint, and end.
   An instant already on the hour is not pushed forward into an hour that has not happened yet.
4. **Costs keep the app's `~$` estimate prefix.** The mockup shows `$0.70`. Every other cost in
   NotchBot is written `~$0.70` because the figure is a provider estimate, and Today should not
   be the one place that presents it as exact. The mockup's `no cost data` is used verbatim.
5. **The footer stays visible, and its pill falls back to a run count.** The panel mockup keeps
   the footer on both pages, so Today keeps it too — it is where the entry point lives. The
   mockup's pill always shows spend; the implementation shows `N runs today` when a day has
   completed sessions but no tracked spend, so the only way into Today does not disappear for
   users who never enabled cost tracking.

The mockup's subagent sample name is `refactor-auth · migrate-tests`, i.e. parent · child.
The implementation shows the subagent's own bounded title, because the parent's title is already
on the row directly above it.
