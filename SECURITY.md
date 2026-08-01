# Security Policy

## Reporting A Vulnerability

Use GitHub's **Security > Report a vulnerability** private vulnerability reporting flow when it is available for this repository. If it is unavailable, open a GitHub issue containing no secrets, credentials, private payloads, or exploitable details and ask the maintainers to establish a private disclosure channel.

## Threat Model

NotchBot treats the current macOS user account as its trust boundary. Its Unix datagram sockets are mode `0600`, and lifecycle events and permission responses use independently authenticated encrypted envelopes with a key stored as mode `0600`. This excludes other local users and rejects accidental or unauthenticated messages, but it cannot isolate processes owned by the same user because they can potentially read the key. A compromised same-user process can inspect integration files, invoke the helper, forge lifecycle events, or submit permission responses. NotchBot does not attempt to isolate or secure OpenCode, Claude Code, terminals, or the projects they operate on.

NotchBot is local-only by design. It includes no telemetry or analytics and makes no intentional Internet requests. The integrated agents have separate network and data-handling behavior outside this threat model.

## Data Flow

The OpenCode plugin and Claude Code hooks invoke `~/Library/Application Support/NotchBot/bin/notchbot-hook`. The helper selects lifecycle state, source, session identifier, optional parent-session identifier, working-directory path, terminal identifier, reason, expiry, a bounded task label, and optional permission metadata. When the user explicitly enables cost tracking, it also accepts a numeric provider-reported estimated USD cost and an opaque OpenCode process generation identifier used for deduplication. It authenticates and encrypts the event to `~/Library/Application Support/NotchBot/notchbot.sock` using the same-user key at `~/Library/Application Support/NotchBot/event.key`. Outside bounded native permission context, NotchBot does not select prompt fields, transcripts, task subjects, task descriptions, assistant response text, model details, or token details. Labels appear in the hover queue and remain in process memory. NotchBot uses the working-directory path without traversing or reading arbitrary project files.

For an actionable permission, the helper binds a private one-shot `permission-<random-token>.sock` before publishing the event. NotchBot sends an authenticated `allowOnce`, `alwaysAllow`, or `decline` response to the socket derived from that validated token. Responses are single-use in practice because the helper closes and removes the socket after receiving one valid response; tokens and socket paths expire after a bounded four-minute wait. OpenCode retains its native request identifier inside the plugin and maps the response to `once`, `always`, or `reject`. Claude Code retains its native permission suggestion inside the helper. NotchBot offers Claude **Always** only when exactly one suggestion exists, and the helper echoes that suggestion without widening or synthesizing a rule. On timeout, app absence, invalid data, or provider API failure, the native provider permission flow remains available.

Permission rows separate the native permission scope from its command, path, URL, query, pattern, or description context when available. Both fields are sanitized, independently limited to 240 characters and 1 KiB, retained only in process memory, and never written by NotchBot. OpenCode context is selected from an allowlist of native permission metadata fields; Claude context is selected from the existing allowlisted `tool_input` fields. Unknown raw provider fields are not forwarded. Clicking an actionable row or the compact bot only focuses the terminal. Only an explicit permission button sends a provider response. After a response is sent, the controls disappear but attention remains until a provider lifecycle event reports resumed work.

Acknowledged or expired non-permission attention entries remain in memory as Idle until a subsequent lifecycle event resumes work, the session ends, or stale-session cleanup removes them.

Daily coolness persists a local date identifier and aggregate observed top-level completion count in `UserDefaults`. When cost tracking is enabled, estimated daily spend persists the local date, aggregate estimated USD total, and up to 10,000 source-qualified cumulative cost baselines needed to deduplicate provider updates across app restarts and midnight; inactive baselines are pruned. Debug previews do not modify persisted progress or spend.

Claude Code passes its hook JSON on stdin. While cost tracking is enabled, a generated status-line wrapper also passes Claude's documented status-line JSON to the helper and then invokes the complete prior status-line command with the original input. The decoder selects only session ID and numeric estimated cost from that payload. Prompt, transcript, response, model, context-window, rate-limit, and token fields can reach the helper process in raw Claude input, but they are not selected, forwarded, or retained. OpenCode constructs an allowlisted stdin payload and, only after opt-in, selects numeric assistant-message cost estimates; it does not pass through raw events or assistant-message content.

The integration uses the helper and its `.notchbot-owner` marker, `integration-installation.json`, transactional `integration-backups/claude-settings-<UUID>.backup` files, `event.key`, `instance.lock`, `notchbot.sock`, `~/.config/opencode/plugins/notchbot.js`, and NotchBot handlers in `~/.claude/settings.json`. Opt-in cost tracking additionally uses the owned `bin/notchbot-statusline` wrapper and `statusline-state.json`, which stores the prior Claude status-line configuration for restoration. All relative names are under `~/Library/Application Support/NotchBot/`. Transactional backups are removed after a verified settings update and retained only on failure. NotchBot does not install integration files outside these paths.

## Sandbox Status

NotchBot 0.3.2 is not App Sandbox enabled and requests no signing entitlements.
