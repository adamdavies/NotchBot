# NotchBot

<p align="center">
  <img src="Packaging/example.gif" alt="NotchBot app icon" width="520">
</p>

NotchBot is a native macOS menu-bar companion for AI coding agents. It extends a MacBook notch with a pixel robot that sleeps with drifting Zs while idle, walks while an agent is working, and jumps with a yellow pulse when an agent needs attention.

Version 1.0.0 supports OpenCode and Claude Code on Apple Silicon Macs running macOS 14 or later.

## Install

Download `NotchBot-1.0.0.dmg` and `NotchBot-1.0.0.dmg.sha256` from the [latest GitHub release](https://github.com/adamdavies/NotchBot/releases/latest), verify the checksum, open the DMG, and move NotchBot into `/Applications`.

```sh
shasum -a 256 -c NotchBot-1.0.0.dmg.sha256
```

Developer ID signing and notarization are preferred. When those credentials are unavailable, an explicitly produced ad-hoc release may require right-clicking NotchBot and selecting **Open**; the release notes identify that status.

Open the fixed robot menu-bar icon and select **Install Integrations** for a first installation. Once integrations are installed and current, that entry reads **Reinstall Integrations** and rewrites the managed files in place. Version 1.0.0 raises the integration revision to 21. After installing this release, select **Update Integrations** and restart every running OpenCode and Claude Code session.

## Current Features

- Notch-aware, always-on-top AppKit panel across Spaces and full-screen apps
- Automatic, per-display, and all-display placement, including a menu-bar-height synthetic notch for clamshell mode and external displays
- Selectable **Retro Bot**, **Blob Bot**, **Orb Bot**, and **Cat Bot** characters, with Retro Bot as the default
- A fixed robot menu-bar icon that remains consistent when the notch character changes
- Character, display, daily coolness, and opt-in estimated daily spend and cost-alert threshold persistence in `UserDefaults`; context-window usage is held in memory only and is never persisted
- A **Today** view reached by clicking the footer spend pill: completed sessions for the current day only, newest first, with a bounded task label, source, start and end time, duration, optional cost, and subagents grouped under their parent, above a cumulative-spend line for the day
- Concurrent session tracking with attention taking priority over working activity
- Live agent count opposite the robot, with a yellow waiting badge
- Click the compact notch panel to focus Terminal, iTerm2, Warp, Ghostty, or Kitty
- Hover shows a redesigned queue of tracked sessions marked Idle, Working, or Needs You, plus daily level progress even when the queue is empty
- Subagents are grouped beneath their parent task and count as active bots; successful subagent completion removes the child without triggering attention
- Permission rows separate the requested scope from bounded native command, path, or resource context and include **Allow Once**, **Always**, and **Decline** controls; Claude's **Always** control appears only for one unambiguous native suggestion
- Clicking an attention row or the compact bot acknowledges its current attention state, stops the Needs You presentation, and focuses the terminal without submitting or hiding any unresolved request
- A duplicate event for an acknowledged request stays quiet, while a new request restores Needs You; after a permission response is submitted, its controls disappear until the provider reports resolution
- Daily coolness tiers at 25, 50, 100, and 150 observed top-level completions add a cumulative cyan isometric glow plate and neon shades, followed by a gold crown and then a large blue-and-gold tech-bro cap; Cap replaces the crown and progression resets at local midnight
- Optional local **Usage & Cost Tracking** for OpenCode and Claude Code, with per-session estimated spend, a daily total that resets at local midnight, and per-row context-window usage
- A thin context meter on any queue row whose provider reports usage, including OpenCode subagents: hidden below 50%, neutral to 74%, amber from 75%, and red from 90%
- An optional daily cost alert, off by default: set a threshold with **Set Cost Alert…** and NotchBot notifies you once a day the first time today's estimated spend passes it, with the hover-card cost pill turning amber at 80% of the threshold and red once it is crossed
- When no sessions are tracked, idle hover shows an empty queue state instead of retaining completed response text
- Separate bounded session-title and current-activity lines, with provider/project/status details retained beneath them
- Local Unix datagram transport with no telemetry, analytics, or intentional Internet requests
- Explicit global OpenCode and Claude Code integration installation and migration

## Run During Development

```sh
swift run NotchBot
```

Open the menu-bar robot and select **Install Integrations** for a first installation. Select **Update Integrations** and restart running agent sessions only when the app reports that an integration update is available.

Use the **Debug** menu to independently preview robot states and coolness tiers without running an agent. Debug previews remain active until stopped and never change persisted daily progress.

## Manually Test Queue States

With NotchBot running and its integrations installed, set the helper path once in the shell where you will run the commands:

```sh
HOOK="$HOME/Library/Application Support/NotchBot/bin/notchbot-hook"
```

The examples use reserved `notchbot-demo-*` session IDs and do not clear genuine queue entries. Run the cleanup command before switching scenarios if you want to inspect one state at a time.

Show a parent task as **Working**:

```sh
printf '%s\n' '{"session_id":"notchbot-demo-parent","cwd":"/tmp/notchbot-demo","session_title":"Demo parent","activity_description":"Demo parent task"}' \
  | "$HOOK" --source opencode --kind working
```

Show a tracked task as **Idle** by expiring a dummy attention event:

```sh
printf '%s\n' '{"session_id":"notchbot-demo-idle","cwd":"/tmp/notchbot-demo","session_title":"Demo idle session","activity_description":"Demo idle task"}' \
  | "$HOOK" --source opencode --kind working
printf '%s\n' '{"session_id":"notchbot-demo-idle","cwd":"/tmp/notchbot-demo","session_title":"Demo idle session","activity_description":"Demo idle task"}' \
  | "$HOOK" --source opencode --kind attention --reason "Demo finished" --expires-after 0.1
```

Show a completed parent as persistent **Needs You** attention. It remains in attention until you click the bot or its queue row:

```sh
printf '%s\n' '{"session_id":"notchbot-demo-parent","cwd":"/tmp/notchbot-demo","session_title":"Demo parent","activity_description":"Demo parent task"}' \
  | "$HOOK" --source opencode --kind working
printf '%s\n' '{"session_id":"notchbot-demo-parent","cwd":"/tmp/notchbot-demo","session_title":"Demo parent","activity_description":"Demo parent task"}' \
  | "$HOOK" --source opencode --kind attention --reason "OpenCode finished working"
```

Show a working parent with two indented subagents, one Working and one Needs You:

```sh
printf '%s\n' '{"session_id":"notchbot-demo-parent","cwd":"/tmp/notchbot-demo","session_title":"Demo parent","activity_description":"Demo parent task"}' \
  | "$HOOK" --source opencode --kind working
printf '%s\n' '{"session_id":"notchbot-demo-child-working","parent_session_id":"notchbot-demo-parent","cwd":"/tmp/notchbot-demo","session_title":"Working subagent","activity_description":"Exploring the implementation"}' \
  | "$HOOK" --source opencode --kind working
printf '%s\n' '{"session_id":"notchbot-demo-child-attention","parent_session_id":"notchbot-demo-parent","cwd":"/tmp/notchbot-demo","session_title":"Waiting subagent","activity_description":"Checking permissions"}' \
  | "$HOOK" --source opencode --kind attention --reason "OpenCode needs permission"
```

Simulate successful subagent completion. This removes only that child without triggering attention:

```sh
printf '%s\n' '{"session_id":"notchbot-demo-child-working","parent_session_id":"notchbot-demo-parent"}' \
  | "$HOOK" --source opencode --kind cleared
```

Drive the daily cost alert. Set a threshold with **Set Cost Alert…** first, then send rising cumulative totals. `cost_usd` is cumulative per session, so each command replaces the previous value rather than adding to it. Unlike the queue examples, this does add to today's recorded estimated spend:

```sh
for amount in 1.00 8.20 10.40 12.00; do
  printf '{"session_id":"notchbot-demo-cost","cost_usd":%s}\n' "$amount" \
    | "$HOOK" --source opencode --kind metadata
done
```

With a $10.00 threshold that walks the hover-card cost pill from green to amber at $8.20 and red at $10.40, and posts exactly one notification.

Populate the **Today** view. A provider `cleared` event is a session end, so it records a completed cycle; a parent's completion attention records its own. Run these in order, pausing a few seconds between them so the durations differ:

```sh
printf '%s\n' '{"session_id":"notchbot-demo-today","cwd":"/tmp/notchbot-demo","session_title":"Demo timeline parent"}' \
  | "$HOOK" --source opencode --kind working
printf '%s\n' '{"session_id":"notchbot-demo-today-child","parent_session_id":"notchbot-demo-today","session_title":"Demo timeline subagent"}' \
  | "$HOOK" --source opencode --kind working
printf '{"session_id":"notchbot-demo-today-child"}\n' | "$HOOK" --source opencode --kind cleared
printf '%s\n' '{"session_id":"notchbot-demo-today","reason":"OpenCode finished working"}' \
  | "$HOOK" --source opencode --kind attention
```

Then click the footer spend pill. Today should show one group, the subagent indented beneath its parent, each with a time range and duration, and `no cost data` unless usage and cost tracking is on. The back chevron returns to the queue, and the panel resizes on both transitions. Dismissing a row with its ✕ must not add anything to Today, and a cycle already listed there must survive being dismissed from the queue.

Clear every dummy item created by these examples. Clearing the parent also removes any descendants, while the other IDs make cleanup safe if a scenario was run independently.

A `cleared` event is a *provider* session end, so it records a completed cycle in Today — the command below tidies the live queue but leaves demo rows in the Today view. To remove the demo entries from the queue without recording anything, use **Clear All** or a row's ✕ instead, which is manual dismissal. Demo rows already written to Today clear at the local-midnight rollover.

```sh
for id in \
  notchbot-demo-parent \
  notchbot-demo-child-working \
  notchbot-demo-child-attention \
  notchbot-demo-cost \
  notchbot-demo-today \
  notchbot-demo-today-child \
  notchbot-demo-idle; do
  printf '{"session_id":"%s"}\n' "$id" | "$HOOK" --source opencode --kind cleared
done
```

## Regenerate The Sprite Sheet

The checked-in PNG is generated from integer pixel geometry:

```sh
swift Tools/generate-sprites.swift
```

The output is `Sources/NotchBot/Resources/RobotAtlas.png`, the Retro Bot atlas. It contains six columns and three rows of uniform 48×48 px tiles:

- Row 1: sleeping idle and drifting-Z frames
- Row 2: right-facing walk frames
- Row 3: front-facing jump frames

Regenerate the application icon with:

```sh
swift Tools/generate-app-icon.swift
```

## Test

```sh
swift test
```

## Build An App And DMG

The scripts prefer an installed Developer ID Application identity. An ad-hoc build must be explicitly allowed, and DMG creation requires an explicit notarization choice. Trusted Gatekeeper distribution requires full Xcode, a Developer ID Application certificate, and notarization credentials; an ad-hoc fallback must be clearly labeled in its release notes.

For a local ad-hoc build:

```sh
ALLOW_ADHOC_RELEASE=1 scripts/build-app.sh
NOTARIZE=0 scripts/create-dmg.sh
```

For a Developer ID signed and notarized release:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
NOTARIZE=1 NOTARY_PROFILE="notchbot-notary" scripts/create-dmg.sh
```

`SIGNING_IDENTITY` may be omitted when a Developer ID Application identity is installed. The scripts do not silently fall back to ad-hoc signing or silently skip notarization. They verify app and helper signatures, confirm that no entitlements were granted, verify the DMG, and create and check a SHA-256 sidecar. They stop rather than overwrite an existing app, DMG, or checksum.

## Integration Files

NotchBot integration revision 20 and its local transport use these paths:

- `~/Library/Application Support/NotchBot/bin/notchbot-hook`
- `~/Library/Application Support/NotchBot/bin/notchbot-hook.notchbot-owner`
- `~/Library/Application Support/NotchBot/bin/notchbot-statusline` (only while usage and cost tracking is enabled)
- `~/Library/Application Support/NotchBot/statusline-state.json` (only while usage and cost tracking is enabled)
- `~/Library/Application Support/NotchBot/session-timeline.json` (mode `0600`, current day only, created after the first session completes)
- `~/Library/Application Support/NotchBot/integration-installation.json`
- `~/Library/Application Support/NotchBot/integration-backups/claude-settings-<UUID>.backup` (transactional, mode `0600`, normally removed after verification, at most five retained after failures)
- `~/Library/Application Support/NotchBot/event.key`
- `~/Library/Application Support/NotchBot/instance.lock`
- `~/Library/Application Support/NotchBot/notchbot.sock`
- `~/.config/opencode/plugins/notchbot.js`
- `~/.claude/settings.json` (NotchBot handlers are merged into `hooks`; opt-in usage and cost tracking also wraps `statusLine`)

Before changing Claude Code settings, NotchBot creates a mode-`0600` transactional backup under `~/Library/Application Support/NotchBot/integration-backups/`. Managed files are staged in the destination directory with restrictive permissions applied before atomic rename. NotchBot removes a backup after verifying a successful update and retains at most the five newest recognized backups after failures; unrelated files, directories, and symlinks are not pruned. Backups support manual recovery and are not restored automatically. When usage and cost tracking is enabled, NotchBot stores the complete prior status-line configuration, preserves its options and output, and restores it when tracking is disabled. If that recovery state is missing or invalid, disabling tracking stops without changing Claude settings. Removal verifies all generated markers and managed configuration before changing settings or deleting files. These checks reduce accidental replacement but cannot protect against a malicious process running as the same user. A legacy `~/.claude/settings.json.notchbot-backup` created by v0.1.0 is left untouched and can be reviewed or removed manually after migration.

Version 1.0.0 uses integration revision 21 and retains event protocol version 4 unchanged; the session timeline is derived from events NotchBot already receives, so no new provider-facing field was added. The revision rises because removal now also deletes `session-timeline.json`. Integration revision 20 files from v0.9.0, and revision 19 files from v0.6.0 through v0.8.0, are recognized and migrated, but this release does require selecting **Update Integrations** and restarting running Claude Code and OpenCode sessions.

## Privacy

NotchBot is local-only by design. It has no telemetry or analytics and makes no intentional Internet requests. OpenCode and Claude Code have their own network behavior, which is outside NotchBot's control.

The integrations send encrypted, authenticated lifecycle events containing source, session identifier, optional parent-session identifier, working-directory path, terminal identifier, reason, expiry, a bounded session title, a bounded current-activity description, and optional permission metadata over the local Unix datagram socket at `~/Library/Application Support/NotchBot/notchbot.sock`. Current activity is selected only from Claude's native `description` field for Bash and agent tools and OpenCode's native tool-state title; OpenCode uses provider timestamps to reject delayed title and activity updates. When usage and cost tracking is explicitly enabled, events may also contain a provider-reported estimated USD cost, an opaque OpenCode process generation identifier used for deduplication, and a single bounded context-window percentage between 0 and 100. OpenCode hierarchy comes from its session `parentID`; Claude Code hierarchy comes from its documented `agent_id` and parent `session_id` hook fields. Outside bounded native permission context and these narrow activity fields, NotchBot does not select prompt fields, transcripts, task subjects, task descriptions, tool commands or input/output, assistant response text, model details, or token details. Session titles and current activity appear in separate hover-queue lines and remain in memory; they are not used for notifications, permissions, cost attribution, or queue identity. Daily coolness stores a local date and aggregate completion count in `UserDefaults`. Estimated daily spend stores the local date, total, and bounded source-qualified cost baselines needed to process cumulative updates across restarts and midnight; inactive baselines are pruned. The optional cost alert additionally stores the user-entered threshold amount and a day-scoped flag recording that today's notification has been sent; the threshold is a local preference and is never sent anywhere. The Today view is the one place NotchBot writes presentation text to disk. When a session cycle reaches a terminal state, `session-timeline.json` records a stable cycle identifier, source, session identifier, optional parent-session identifier, group identifier, the same bounded session title shown in the queue, the cycle's start and end timestamps, and an optional cost. Nothing else is written: no working directory, activity description, permission data, reason, terminal detail, context usage, prompt, transcript, token count, or model. The file is mode `0600` inside the mode-`0700` support directory, holds the current day only, and is bounded to 400 entries and 64 KiB with the oldest complete parent/subagent groups trimmed first. A cost of zero means the cycle was tracked and cost nothing; an absent cost means none was observed, so a session that ran while tracking was off shows no cost rather than `$0.00`. Each cycle is charged only what it added: a session already running when NotchBot launched starts from the cumulative baseline already persisted for the daily total, so its first recorded cycle is not billed for spend NotchBot never watched accrue. Clearing a row yourself removes it from the live queue without recording it, while a cycle that already completed stays in Today. The file is deleted at the same local-midnight rollover as the daily total, when a stale day is found at startup, and when integrations are removed; turning usage and cost tracking off strips costs from the rows already recorded. Context-window percentages are never persisted: they exist only in the running app's memory, are dropped when a session is cleared or expires, are cleared immediately when usage and cost tracking is turned off, and are absent after a restart until a provider reports them again. NotchBot uses the working-directory path to display a project name and focus a terminal; it does not traverse or read arbitrary project files.

Claude Code supplies its hook JSON, and while usage and cost tracking is enabled its documented status-line JSON, to `notchbot-hook` on standard input. The decoders accept only allowlisted bounded fields, the numeric estimated session cost, and the numeric context-window percentage Claude already reports. Prompt, transcript, response, model, rate-limit, and token fields can reach the helper process in raw Claude input but are not selected, retained, or forwarded. The helper accepts at most 64 KiB, reading one additional byte only to detect overflow. The OpenCode plugin does not pass through raw events or assistant messages: it constructs an allowlisted payload and, only after opt-in, reads numeric assistant-message cost estimates and derives the context percentage itself.

The two providers reach that percentage differently. Claude Code reports it directly, and NotchBot forwards the number unchanged. OpenCode does not expose a percentage, so the generated plugin calculates the same figure OpenCode's own sidebar shows: it briefly reads five numeric token counts from a completed assistant message together with the model's numeric context limit from the documented `chat.params` hook, retains only that limit and the derived percentage in plugin process memory for the session, then divides, rounds, and bounds the result to 0-100. Only the final percentage crosses into the helper and the app. The token counts, context limit, and any model or provider identity are never forwarded, logged, or persisted. The plugin sends an explicit clearing update when a session is compacted or a message is removed, so a percentage that has stopped being true is retracted rather than left on screen.

This figure is context used against the model's full context window, which is what both providers display. It is not a prediction of when automatic compaction will occur, because OpenCode reserves output capacity that its displayed percentage does not account for.

The socket is readable and writable only by the current macOS user. This protects against other local user accounts, not other processes running as the same user: a same-user process can inspect integration files or forge local events. See [SECURITY.md](SECURITY.md) for the full threat model.

NotchBot 1.0.0 is not App Sandbox enabled and requests no signing entitlements.

## License

NotchBot is available under the [MIT License](LICENSE).
