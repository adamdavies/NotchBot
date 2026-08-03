# NotchBot Agent Guide

## Product Context

NotchBot is a native macOS menu-bar companion for Claude Code and OpenCode. It extends the notch or menu-bar area with an animated character that communicates whether agents are idle, working, or need attention.

The core product behavior includes:

- Notch-aware panels across Spaces, full-screen apps, and multiple displays.
- Selectable Retro, Blob, Orb, and Cat characters.
- Concurrent parent and subagent queues, with attention taking priority over working state.
- Terminal focusing for Terminal, iTerm2, Warp, Ghostty, and Kitty.
- Actionable permission requests using bounded provider-native context.
- Notifications, persistent completion attention, daily progression, and opt-in estimated cost tracking.
- Explicit installation, migration, update, and removal of Claude Code and OpenCode integrations.
- Local-only communication with no telemetry, analytics, or intentional network traffic.

Supported systems are Apple Silicon Macs running macOS 14 or later.

## Architecture

This is a Swift Package Manager project with five main targets:

- `NotchBot`: SwiftUI/AppKit menu-bar application, panels, preferences, notifications, and integration installer.
- `notchbot-hook`: provider-facing helper executable; a thin shim over `NotchBotHookCore`.
- `NotchBotHookCore`: helper argument handling, event construction, and permission-response flow, with injected side effects so it is testable.
- `NotchBotCore`: events, reducer, transport, security, cost, progression, and preferences.
- `NotchBotIntegrationCore`: generated OpenCode plugin, Claude hooks, decoding, ownership markers, and status-line wrapper.

The provider integrations invoke `notchbot-hook`. The helper allowlists and validates fields, builds an `AgentEvent`, and sends it through an encrypted, authenticated Unix datagram. `EventServer` validates the envelope and passes the event to `ActivityModel`; `ActivityReducer` owns queue ordering, hierarchy, request state, deduplication, limits, clearing, and expiry.

Important source areas:

- `Sources/NotchBot/NotchBotApp.swift`: application lifecycle and event-server startup.
- `Sources/NotchBot/ActivityModel.swift`: application state, expiry, notifications, cost, and progression.
- `Sources/NotchBotCore/ActivityReducer.swift`: queue and lifecycle state transitions.
- `Sources/NotchBotCore/AgentEvent.swift`: wire event model, validation, and protocol version.
- `Sources/NotchBotCore/EventSecurity.swift`: local envelope authentication and encryption.
- `Sources/NotchBot/IntegrationInstaller.swift`: coordinates installation, update, and removal.
- `Sources/NotchBot/ManagedFileStore.swift`: bounded reads and permission-preserving writes for every managed file.
- `Sources/NotchBot/IntegrationOwnership.swift`: marker-based ownership and revision checks.
- `Sources/NotchBot/ClaudeSettingsManager.swift`: transactional `~/.claude/settings.json` replacement and backups.
- `Sources/NotchBot/CostTrackingManager.swift`: opt-in status-line wrapper lifecycle.
- `Sources/NotchBot/IntegrationPaths.swift`: the managed path set and shared integration errors.
- `Sources/NotchBotIntegrationCore/`: provider integration generation and decoding.
- `Sources/NotchBotHookCore/HookRunner.swift`: helper entry logic and permission-response handling.

## Engineering Expectations

- Prefer the smallest correct change and follow existing Swift and Swift Testing patterns.
- Preserve the current macOS 14 minimum and local-only architecture unless the user explicitly changes those requirements.
- Keep prompt, transcript, assistant-response, token, and model data out of NotchBot. Provider payloads must be reduced to explicitly allowlisted, bounded fields.
- Preserve authenticated encrypted transport, restrictive file permissions, replay protection, rate limiting, and permission-response validation.
- Never broaden an `Always` permission rule. Claude's `Always` response is valid only for exactly one unambiguous provider-supplied suggestion.
- Treat task labels and permission context as bounded presentation data. Do not persist them or use them to inspect project files.
- Update `README.md` and `SECURITY.md` whenever behavior, retained data, installation paths, permissions, transport, or the threat model changes.
- Do not hand-edit installed files under `~/.config/opencode`, `~/.claude`, or `~/Library/Application Support/NotchBot`. Change their generators or installer in this repository.
- Do not copy project-local permissions from `.claude/settings.local.json` into shared instructions.
- Do not replace the installed app, alter user integrations, commit, tag, push, or publish a release without explicit user authorization.

## Development Workflow

Run the app during development with:

```sh
swift run NotchBot
```

Run focused tests while iterating when practical, followed by the complete suite before declaring a code change complete:

```sh
swift test
```

Use the app's **Debug** menu to preview character states and progression tiers without changing persisted progress. The manual queue-state commands in `README.md` cover working, idle, persistent attention, parent/subagent hierarchy, child completion, and cleanup.

Do not require an installed-app replacement for every development change. A fresh release build, app replacement, and full manual smoke test are release-candidate requirements.

## Integration Changes

An integration update is required when a change affects generated provider behavior, provider input decoding, the helper contract, status-line handling, integration installation, migration, ownership, or provider-facing event semantics. UI-only or reducer-only changes do not require an integration revision unless they also change that contract.

For an integration-affecting change, review and amend all applicable files:

- `Sources/NotchBotIntegrationCore/OpenCodePlugin.swift`
- `Sources/NotchBotIntegrationCore/OpenCodePluginSource.swift`
- `Sources/NotchBotIntegrationCore/ClaudeHooks.swift`
- `Sources/NotchBotIntegrationCore/HookInput.swift`
- `Sources/NotchBotIntegrationCore/StatusLineWrapper.swift`
- `Sources/NotchBotHookCore/HookRunner.swift`
- `Sources/NotchBot/IntegrationInstaller.swift` and the types it coordinates
- `Sources/NotchBotIntegrationCore/IntegrationPrivacy.swift`
- `Tests/NotchBotIntegrationCoreTests/IntegrationPrivacyTests.swift`
- Relevant tests in `Tests/NotchBotIntegrationCoreTests/`
- `Sources/NotchBotCore/AgentEvent.swift` if wire compatibility or event semantics change
- `README.md` and `SECURITY.md` if behavior, data flow, or retained data changes

When bumping the integration revision:

1. Move the former `generatedMarker` into `previousGeneratedMarkers`.
2. Move the former `helperOwnershipMarker` into `previousHelperOwnershipMarkers`.
3. Set new current markers with the app version and next integration revision.
4. Increment `IntegrationInstallStatus.currentVersion`.
5. Update marker/version assertions and generated integration tests.
6. Run the complete test suite.
7. Tell the user that the new app must be built and installed, then explicitly prompt them to select **Update Integrations** and restart all running Claude Code and OpenCode sessions.

Do not remove previous ownership markers. They are required to recognize and safely migrate files generated by older releases.

## Generated Assets

The generated OpenCode plugin is a JavaScript template in
`Sources/NotchBotIntegrationCore/OpenCodePluginSource.swift`. Syntax-check it after any edit:

```sh
Tools/check-plugin-js.sh
```

The same check runs as part of `swift test` when `node` is available.

The Retro sprite atlas is generated with:

```sh
swift Tools/generate-sprites.swift
```

This updates `Sources/NotchBot/Resources/RobotAtlas.png`. Keep its checked-in metadata aligned when atlas geometry changes.

The app icon is generated with:

```sh
swift Tools/generate-app-icon.swift
```

`scripts/build-app.sh` runs the icon generator and may rewrite checked-in `Packaging/NotchBot.png` and `Packaging/NotchBot.icns`. Inspect those diffs and include them only when intentional.

## Build Strategy

Development uses SwiftPM debug builds. Distribution uses a fresh release build assembled by `scripts/build-app.sh` and packaged by `scripts/create-dmg.sh`.

The scripts intentionally refuse to overwrite existing app, DMG, or checksum artifacts. Move old artifacts aside before a fresh build; do not weaken this guard.

For a local ad-hoc candidate:

```sh
ALLOW_ADHOC_RELEASE=1 scripts/build-app.sh
NOTARIZE=0 scripts/create-dmg.sh
```

For public distribution, prefer a Developer ID signed and notarized build:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
NOTARIZE=1 NOTARY_PROFILE="notchbot-notary" scripts/create-dmg.sh
```

Do not silently fall back to ad-hoc signing or skip notarization. The release notes must state the actual signing and notarization status.

## Release Candidate Testing

After `swift test` passes and a fresh app and DMG have been produced:

1. Verify app and helper signatures, absence of unexpected entitlements, DMG integrity, and the SHA-256 sidecar.
2. Quit the running NotchBot app.
3. Replace `/Applications/NotchBot.app` with the fresh build and reopen it.
4. If the integration revision changed, select **Update Integrations** and restart all running Claude Code and OpenCode sessions.
5. Confirm menu-bar startup, panel placement, selected displays, all character choices, preferences, launch at login, and terminal focusing.
6. Use Debug previews to inspect idle, working, attention, queue, notification, and progression presentation.
7. Run the documented queue-state scenarios, including parent/subagent grouping, child completion, persistent attention, acknowledgement, and cleanup.
8. Exercise affected live Claude Code and OpenCode flows. For integration releases, verify installation/update detection, lifecycle events, permissions, completion, errors, and opt-in cost tracking where applicable.
9. Confirm existing Claude settings and status-line configuration are preserved through integration update and removal where the change touches those paths.
10. Inspect the final Git diff and confirm generated assets and all version references are intentional.

Record manual test results in the release notes, pull request, or task summary. Do not claim manual checks that were not performed.

## Release Process

The application version and build number are authoritative in `Packaging/Info.plist`. The integration revision is independent and lives in `Sources/NotchBotIntegrationCore/IntegrationPrivacy.swift`.

For every release:

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in `Packaging/Info.plist`.
2. Search the repository for the previous app version and update current-version references in `README.md`, `SECURITY.md`, packaging, and other user-facing documentation. Preserve intentional historical markers and migration tests.
3. Decide whether the change requires an integration revision using the integration criteria above. Apply the complete integration checklist when it does.
4. Run `swift test` and complete release-candidate testing using a freshly installed build.
5. Build the final signed/notarized app and versioned DMG, then verify the generated `.sha256` sidecar.
6. Review the complete release diff and included commits before creating the tag or GitHub release.
7. Obtain explicit user approval before committing release preparation, tagging, pushing, replacing the installed app, or publishing GitHub assets.

A GitHub release must attach the versioned DMG and its `.sha256` sidecar. Its notes must include these sections when applicable:

- **Highlights**: all user-visible features and improvements.
- **Fixes**: issues and regressions resolved.
- **Upgrade**: app replacement steps, migration concerns, and compatibility changes.
- **Integration Update**: the new revision plus explicit **Update Integrations** and provider-session restart instructions, or a statement that no integration update is required.
- **Requirements**: supported architecture and minimum macOS version.
- **Key Information**: known limitations, breaking changes, privacy/security implications, or data migrations.
- **Distribution Notice**: Developer ID signing and notarization status, or clear ad-hoc/Gatekeeper instructions.
- **Checksums**: the SHA-256 value for the attached DMG.

Release notes must describe only verified behavior and must not omit upgrade instructions for a patch release.
