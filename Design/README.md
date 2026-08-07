# Design Reference

Imported from the Claude Design project **macOS Notch Agent Activity**
(`081fdb17-7850-468f-9c6a-0620355eefea`), file `NotchBot Panel.dc.html`.

Open `NotchBot Panel.dc.html` directly in a browser to render it; `support.js` is the
generated `dc-runtime` harness the project ships and is vendored unmodified so the
mockup renders offline. Neither file is compiled into the app or read at runtime — this
directory is reference material only.

## What the mockup actually specifies

The mockup is the **current** queue panel plus one genuinely new element: a per-row
context-window meter. Header, row anatomy, footer, and card chrome already match what
`Sources/NotchBot/AgentQueueView.swift` ships today, so those are recorded below only to
confirm the design does not ask for a change. Do not churn shipped values to chase the
mockup's approximations.

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
| **Context meter** | see below | `ContextMeterView` and `ContextMeter` | implemented for 0.9.0 |

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

## Known conflict: visibility threshold

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
