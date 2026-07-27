# NotchBot

<p align="center">
  <img src="Packaging/NotchBot.png" alt="NotchBot app icon" width="180">
</p>

NotchBot is a native macOS menu-bar companion for AI coding agents. It extends a MacBook notch with a pixel robot that sleeps with drifting Zs while idle, walks while an agent is working, and jumps with a yellow pulse when an agent needs attention.

The first release supports OpenCode and Claude Code on Apple Silicon Macs running macOS 14 or later.

## Install

Download `NotchBot-0.1.0.dmg` from the [latest GitHub release](https://github.com/adamdaviesme/NotchBot/releases/latest), open it, and move NotchBot into `/Applications`.

The current release is ad-hoc signed rather than notarized. On first launch, right-click NotchBot and select **Open**. If macOS still blocks it, use **System Settings > Privacy & Security > Open Anyway**.

Open the robot menu-bar icon, select **Install Integrations**, and restart any running OpenCode or Claude Code sessions.

## Current Features

- Notch-aware, always-on-top AppKit panel across Spaces and full-screen apps
- Reproducible 48 px tiled sprite atlas with nearest-neighbor rendering
- Concurrent session tracking with attention taking priority over working activity
- Live agent count opposite the robot, with a yellow waiting badge
- Continuous jumping robot with a sweeping amber attention glow
- Click-to-focus for Terminal, iTerm2, Warp, Ghostty, and Kitty
- Hover card with the latest locally retained agent-response excerpt
- User-only Unix datagram socket; prompts and source-code content never enter NotchBot
- One-click global OpenCode and Claude Code integration installation

## Run During Development

```sh
swift run NotchBot
```

Open the menu-bar robot and select **Install Integrations**. Restart any running OpenCode session after installing the plugin. Claude Code normally reloads settings automatically.

Use **Preview Idle**, **Preview Working**, and **Preview Attention** in the menu to inspect animations without running an agent. Previews can be cancelled manually and stop automatically after 10 seconds.

## Regenerate The Sprite Sheet

The checked-in PNG is generated from integer pixel geometry:

```sh
swift Tools/generate-sprites.swift
```

The output is `Sources/NotchBot/Resources/RobotAtlas.png`. It contains six columns and three rows of uniform 48×48 px tiles:

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

The local build can be produced with Command Line Tools. A public release requires full Xcode, a Developer ID Application certificate, and notarization credentials.

```sh
scripts/build-app.sh
scripts/create-dmg.sh
```

For Developer ID signing:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
NOTARY_PROFILE="notchbot-notary" scripts/create-dmg.sh
```

The scripts intentionally stop if an existing app or DMG is present so they cannot overwrite a previous build.

## Integration Files

NotchBot installs only these files and settings:

- `~/Library/Application Support/NotchBot/bin/notchbot-hook`
- `~/.config/opencode/plugins/notchbot.js`
- NotchBot command handlers merged into `~/.claude/settings.json`

Before changing Claude Code settings, NotchBot saves `~/.claude/settings.json.notchbot-backup`. Removing integrations deletes only handlers whose command points to NotchBot's installed helper.

## Privacy

Integrations send the source, lifecycle state, session identifier, working directory, terminal identifier, and a response excerpt of at most 240 characters over a user-only local socket. The excerpt is retained in memory only so it can be displayed on hover. NotchBot does not send prompt text, source code, tool arguments, API keys, or any data over the network.

## License

NotchBot is available under the [MIT License](LICENSE).
