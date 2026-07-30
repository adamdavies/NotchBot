# NotchBot

<p align="center">
  <img src="Packaging/NotchBot.png" alt="NotchBot app icon" width="180">
</p>

NotchBot is a native macOS menu-bar companion for AI coding agents. It extends a MacBook notch with a pixel robot that sleeps with drifting Zs while idle, walks while an agent is working, and jumps with a yellow pulse when an agent needs attention.

Version 0.2.4 supports OpenCode and Claude Code on Apple Silicon Macs running macOS 14 or later.

## Install

Download `NotchBot-0.2.4.dmg` and `NotchBot-0.2.4.dmg.sha256` from the [latest GitHub release](https://github.com/adamdavies/NotchBot/releases/latest), verify the checksum, open the DMG, and move NotchBot into `/Applications`.

```sh
shasum -a 256 -c NotchBot-0.2.4.dmg.sha256
```

Developer ID signing and notarization are preferred. When those credentials are unavailable, an explicitly produced ad-hoc release may require right-clicking NotchBot and selecting **Open**; the release notes identify that status.

Open the fixed robot menu-bar icon and select **Install Integrations** for a first installation. After updating NotchBot, including to v0.2.4, select **Update Integrations** and restart all running OpenCode and Claude Code sessions so they load the current integration.

## Current Features

- Notch-aware, always-on-top AppKit panel across Spaces and full-screen apps
- Automatic, per-display, and all-display placement, including a menu-bar-height synthetic notch for clamshell mode and external displays
- Selectable **Retro Bot**, **Blob Bot**, **Orb Bot**, and **Cat Bot** characters, with Retro Bot as the default
- A fixed robot menu-bar icon that remains consistent when the notch character changes
- Character and display preference persistence in `UserDefaults`, storing a validated character identifier and either a display mode or system display UUID
- Concurrent session tracking with attention taking priority over working activity
- Live agent count opposite the robot, with a yellow waiting badge
- Click the compact notch panel to focus Terminal, iTerm2, Warp, Ghostty, or Kitty
- Hover shows a queue of tracked sessions marked Idle, Working, or Needs You
- Subagents are grouped beneath their parent task and count as active bots; successful subagent completion removes the child without triggering attention
- Permission rows separate the requested scope from bounded native command, path, or resource context and include **Allow Once**, **Always**, and **Decline** controls; Claude's **Always** control appears only for one unambiguous native suggestion
- Questions, completion, and errors remain presentation-only attention; clicking a permission row or the compact bot focuses the terminal without submitting or hiding the request
- After a permission response is submitted, its controls disappear while Needs You remains until the provider reports that work resumed
- When no sessions are tracked, idle hover shows an empty queue state instead of retaining completed response text
- Bounded task labels selected from OpenCode session titles or project metadata and Claude Code's existing `session_title`, `agent_type`, or project-directory basename
- Local Unix datagram transport with no telemetry, analytics, or intentional Internet requests
- Explicit global OpenCode and Claude Code integration installation and migration

## Run During Development

```sh
swift run NotchBot
```

Open the menu-bar robot and select **Install Integrations** for a first installation. Select **Update Integrations** after updating the app, then restart all running agent sessions.

Use **Preview Idle**, **Preview Working**, and **Preview Attention** in the menu to inspect animations without running an agent. Previews can be cancelled manually and stop automatically after 10 seconds.

## Manually Test Queue States

With NotchBot running and its integrations installed, set the helper path once in the shell where you will run the commands:

```sh
HOOK="$HOME/Library/Application Support/NotchBot/bin/notchbot-hook"
```

The examples use reserved `notchbot-demo-*` session IDs and do not clear genuine queue entries. Run the cleanup command before switching scenarios if you want to inspect one state at a time.

Show a parent task as **Working**:

```sh
printf '%s\n' '{"session_id":"notchbot-demo-parent","cwd":"/tmp/notchbot-demo","task_label":"Demo parent task"}' \
  | "$HOOK" --source opencode --kind working
```

Show a tracked task as **Idle** by expiring a dummy attention event:

```sh
printf '%s\n' '{"session_id":"notchbot-demo-idle","cwd":"/tmp/notchbot-demo","task_label":"Demo idle task"}' \
  | "$HOOK" --source opencode --kind working
printf '%s\n' '{"session_id":"notchbot-demo-idle","cwd":"/tmp/notchbot-demo","task_label":"Demo idle task"}' \
  | "$HOOK" --source opencode --kind attention --reason "Demo finished" --expires-after 0.1
```

Show a completed parent as persistent **Needs You** attention. It remains in attention until you click the bot or its queue row:

```sh
printf '%s\n' '{"session_id":"notchbot-demo-parent","cwd":"/tmp/notchbot-demo","task_label":"Demo parent task"}' \
  | "$HOOK" --source opencode --kind working
printf '%s\n' '{"session_id":"notchbot-demo-parent","cwd":"/tmp/notchbot-demo","task_label":"Demo parent task"}' \
  | "$HOOK" --source opencode --kind attention --reason "OpenCode finished working"
```

Show a working parent with two indented subagents, one Working and one Needs You:

```sh
printf '%s\n' '{"session_id":"notchbot-demo-parent","cwd":"/tmp/notchbot-demo","task_label":"Demo parent task"}' \
  | "$HOOK" --source opencode --kind working
printf '%s\n' '{"session_id":"notchbot-demo-child-working","parent_session_id":"notchbot-demo-parent","cwd":"/tmp/notchbot-demo","task_label":"Working subagent"}' \
  | "$HOOK" --source opencode --kind working
printf '%s\n' '{"session_id":"notchbot-demo-child-attention","parent_session_id":"notchbot-demo-parent","cwd":"/tmp/notchbot-demo","task_label":"Waiting subagent"}' \
  | "$HOOK" --source opencode --kind attention --reason "OpenCode needs permission"
```

Simulate successful subagent completion. This removes only that child without triggering attention:

```sh
printf '%s\n' '{"session_id":"notchbot-demo-child-working","parent_session_id":"notchbot-demo-parent"}' \
  | "$HOOK" --source opencode --kind cleared
```

Clear every dummy item created by these examples. Clearing the parent also removes any descendants, while the other IDs make cleanup safe if a scenario was run independently:

```sh
for id in \
  notchbot-demo-parent \
  notchbot-demo-child-working \
  notchbot-demo-child-attention \
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

NotchBot's v0.2.4 integration and local transport use these paths:

- `~/Library/Application Support/NotchBot/bin/notchbot-hook`
- `~/Library/Application Support/NotchBot/bin/notchbot-hook.notchbot-owner`
- `~/Library/Application Support/NotchBot/integration-installation.json`
- `~/Library/Application Support/NotchBot/integration-backups/claude-settings-<UUID>.backup` (transactional, normally removed after verification)
- `~/Library/Application Support/NotchBot/event.key`
- `~/Library/Application Support/NotchBot/instance.lock`
- `~/Library/Application Support/NotchBot/notchbot.sock`
- `~/.config/opencode/plugins/notchbot.js`
- `~/.claude/settings.json` (NotchBot command handlers are merged into its `hooks` object)

Before changing Claude Code settings, NotchBot creates a restrictive transactional backup under `~/Library/Application Support/NotchBot/integration-backups/`. It removes the backup after verifying a successful update and leaves it for recovery if the update fails. Removal verifies generated markers and exact managed hook definitions before deleting files. These checks reduce accidental replacement but cannot protect against a malicious process running as the same user. A legacy `~/.claude/settings.json.notchbot-backup` created by v0.1.0 is left untouched and can be reviewed or removed manually after migration.

## Privacy

NotchBot is local-only by design. It has no telemetry or analytics and makes no intentional Internet requests. OpenCode and Claude Code have their own network behavior, which is outside NotchBot's control.

The integrations send encrypted, authenticated lifecycle events containing source, session identifier, optional parent-session identifier, working-directory path, terminal identifier, reason, expiry, a bounded task label, and optional permission metadata over the local Unix datagram socket at `~/Library/Application Support/NotchBot/notchbot.sock`. OpenCode hierarchy comes from its session `parentID`; Claude Code hierarchy comes from its documented `agent_id` and parent `session_id` hook fields. OpenCode labels come from its session title or project metadata. Claude Code labels come from the existing `session_title` or `agent_type` hook fields, falling back to the project-directory basename. Outside bounded native permission context, NotchBot does not select prompt fields, transcripts, task subjects, task descriptions, or assistant response text. OpenCode or Claude Code may themselves generate a session title from conversation content before exposing that metadata. Labels are displayed in the hover queue, retained only in process memory, and never written to disk by NotchBot. NotchBot uses the working-directory path to display a project name and focus a terminal; it does not traverse or read arbitrary project files.

Claude Code supplies its hook event JSON to `notchbot-hook` on standard input. The shared decoder accepts bounded lifecycle, task-label, and OpenCode request/permission fields while ignoring other keys; Claude permission handling separately selects bounded native permission fields. Source-specific handling uses `agent_id` only for Claude hierarchy and `parent_session_id` only for OpenCode hierarchy. The helper accepts at most 64 KiB, reading one additional byte only to detect overflow. Prompt, transcript, and response fields can still reach the helper process as part of Claude's raw stdin, but NotchBot does not select, retain, or forward them. The OpenCode plugin does not pass through raw events or assistant messages: it constructs an allowlisted stdin payload containing lifecycle, task-label, request, and bounded permission metadata only.

The socket is readable and writable only by the current macOS user. This protects against other local user accounts, not other processes running as the same user: a same-user process can inspect integration files or forge local events. See [SECURITY.md](SECURITY.md) for the full threat model.

NotchBot 0.2.4 is not App Sandbox enabled. Sandboxing is deferred to v0.3.0; the 0.2.4 signature intentionally requests no entitlements.

## License

NotchBot is available under the [MIT License](LICENSE).
