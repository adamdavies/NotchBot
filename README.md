# NotchBot

<p align="center">
  <img src="Packaging/NotchBot.png" alt="NotchBot app icon" width="180">
</p>

NotchBot is a native macOS menu-bar companion for AI coding agents. It extends a MacBook notch with a pixel robot that sleeps with drifting Zs while idle, walks while an agent is working, and jumps with a yellow pulse when an agent needs attention.

Version 0.2.1 supports OpenCode and Claude Code on Apple Silicon Macs running macOS 14 or later.

## Install

Download `NotchBot-0.2.1.dmg` and `NotchBot-0.2.1.dmg.sha256` from the [latest GitHub release](https://github.com/adamdavies/NotchBot/releases/latest), verify the checksum, open the DMG, and move NotchBot into `/Applications`.

```sh
shasum -a 256 -c NotchBot-0.2.1.dmg.sha256
```

Developer ID signing and notarization are preferred. When those credentials are unavailable, an explicitly produced ad-hoc release may require right-clicking NotchBot and selecting **Open**; the release notes identify that status.

Open the fixed robot menu-bar icon and select **Install Integrations** for a first installation. After updating NotchBot, including to v0.2.1, select **Update Integrations** and restart all running OpenCode and Claude Code sessions so they load the current integration.

## Current Features

- Notch-aware, always-on-top AppKit panel across Spaces and full-screen apps
- Selectable **Retro Bot**, **Blob Bot**, and **Orb Bot** characters, with Retro Bot as the default
- A fixed robot menu-bar icon that remains consistent when the notch character changes
- Character preference persistence in `UserDefaults`, storing only a validated `retro`, `blob`, or `orb` identifier
- Concurrent session tracking with attention taking priority over working activity
- Live agent count opposite the robot, with a yellow waiting badge
- Click the compact notch panel to focus Terminal, iTerm2, Warp, Ghostty, or Kitty
- Hover shows a read-only queue of tracked sessions marked Idle, Working, or Needs You, with no done rows or inline actions
- Clicking an attention row marks it Idle; a subsequent agent event moves it back to Working when work actually resumes
- When no sessions are tracked, idle hover falls back to the latest locally retained agent-response summary; response excerpts are disabled by default
- Bounded task labels selected from OpenCode session titles or project metadata and Claude Code's existing `session_title`, `task_subject`, `agent_type`, or project-directory basename
- Local Unix datagram transport with no telemetry, analytics, or intentional Internet requests
- Explicit global OpenCode and Claude Code integration installation and migration

## Run During Development

```sh
swift run NotchBot
```

Open the menu-bar robot and select **Install Integrations** for a first installation. Select **Update Integrations** after updating the app, then restart all running agent sessions. Response excerpts can be enabled with **Include Response Excerpts**; changing this setting may also require restarting running agent sessions.

Use **Preview Idle**, **Preview Working**, and **Preview Attention** in the menu to inspect animations without running an agent. Previews can be cancelled manually and stop automatically after 10 seconds.

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

NotchBot's v0.2.1 integration and local transport use these paths:

- `~/Library/Application Support/NotchBot/bin/notchbot-hook`
- `~/Library/Application Support/NotchBot/bin/notchbot-hook.notchbot-owner`
- `~/Library/Application Support/NotchBot/integration-privacy.json`
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

The integrations send encrypted, authenticated lifecycle events containing source, session identifier, working-directory path, terminal identifier, reason, expiry, and a bounded task label over the local Unix datagram socket at `~/Library/Application Support/NotchBot/notchbot.sock`. OpenCode labels come from its session title or project metadata. Claude Code labels come from the existing `session_title`, `task_subject`, or `agent_type` hook fields, falling back to the project-directory basename. NotchBot does not read prompt fields, transcripts, task descriptions, or response text to construct labels, but OpenCode or Claude Code may themselves generate a session title or task subject from conversation content. Labels are displayed in the hover queue, retained only in process memory, and never written to disk by NotchBot. When response excerpts are opted into, the integrations may also send up to 240 characters from the latest assistant response. Excerpts are disabled by default, handled only in process memory, and never written to disk by NotchBot; the app expires its latest excerpt after 15 minutes. NotchBot uses the working-directory path to display a project name and focus a terminal; it does not traverse or read arbitrary project files.

Claude Code supplies its hook event JSON to `notchbot-hook` on standard input. The helper accepts at most 64 KiB, reading one additional byte only to detect overflow, and its JSON decoder selects `session_id`, `cwd`, `session_title`, `task_subject`, `agent_type`, and `last_assistant_message`, ignoring other keys. When response excerpts are disabled, it discards `last_assistant_message`; it never forwards other stdin fields to the app. This means prompt or tool data present elsewhere in Claude's payload still reaches the helper process as raw stdin even though NotchBot does not select, retain, or forward it. The OpenCode plugin does not pass through raw events: it constructs an allowlisted stdin payload containing `session_id`, `cwd`, `task_label`, and, only after opt-in, `last_assistant_message`.

The socket is readable and writable only by the current macOS user. This protects against other local user accounts, not other processes running as the same user: a same-user process can inspect integration files or forge local events. See [SECURITY.md](SECURITY.md) for the full threat model.

NotchBot 0.2.1 is not App Sandbox enabled. Sandboxing is deferred to v0.3.0; the 0.2.1 signature intentionally requests no entitlements.

## License

NotchBot is available under the [MIT License](LICENSE).
