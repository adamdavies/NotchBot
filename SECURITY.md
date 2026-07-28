# Security Policy

## Reporting A Vulnerability

Use GitHub's **Security > Report a vulnerability** private vulnerability reporting flow when it is available for this repository. If it is unavailable, open a GitHub issue containing no secrets, credentials, private payloads, or exploitable details and ask the maintainers to establish a private disclosure channel.

## Threat Model

NotchBot treats the current macOS user account as its trust boundary. Its Unix datagram socket is mode `0600`, and events are authenticated and encrypted with a key stored as mode `0600`. This excludes other local users and rejects accidental or unauthenticated messages, but it cannot isolate processes owned by the same user because they can potentially read the key. A compromised same-user process can inspect integration files, invoke the helper, or forge lifecycle events. NotchBot does not attempt to isolate or secure OpenCode, Claude Code, terminals, or the projects they operate on.

NotchBot is local-only by design. It includes no telemetry or analytics and makes no intentional Internet requests. The integrated agents have separate network and data-handling behavior outside this threat model.

## Data Flow

The OpenCode plugin and Claude Code hooks invoke `~/Library/Application Support/NotchBot/bin/notchbot-hook`. The helper selects lifecycle state, source, session identifier, optional parent-session identifier, working-directory path, terminal identifier, reason, expiry, a bounded task label, and, only when the user opts in, an assistant-response excerpt of at most 240 characters. It authenticates and encrypts the event to `~/Library/Application Support/NotchBot/notchbot.sock` using the same-user key at `~/Library/Application Support/NotchBot/event.key`. OpenCode hierarchy comes from its session `parentID`; Claude Code hierarchy comes from its documented `agent_id` and parent `session_id` hook fields. OpenCode labels come from its session title or project metadata. Claude Code labels come from the existing `session_title` or `agent_type` hook fields, falling back to the project-directory basename. NotchBot does not select prompt fields, transcripts, task subjects, task descriptions, or response excerpts to construct labels, but the integrated agent may have generated a title from conversation content before exposing that metadata. Labels appear in the hover queue, remain in process memory, and are not written to disk by NotchBot. Response excerpts are disabled by default, remain in process memory, are not written to disk by NotchBot, and expire from the app after 15 minutes. NotchBot uses the working-directory path without traversing or reading arbitrary project files.

Acknowledged or expired attention entries remain in memory as Idle until a subsequent lifecycle event resumes work, the session ends, or stale-session cleanup removes them. A click changes only NotchBot's local presentation state and focuses the terminal application; it does not approve, reject, or execute an agent action.

Claude Code passes its hook JSON on stdin. The shared helper decoder accepts only `session_id`, `agent_id`, `parent_session_id`, `cwd`, `session_title`, `agent_type`, `task_label`, and `last_assistant_message`, ignoring unknown keys; source-specific handling uses `agent_id` only for Claude hierarchy and `parent_session_id` only for OpenCode hierarchy. The helper accepts at most 64 KiB and reads one additional byte only to detect overflow. When excerpts are disabled, `last_assistant_message` is discarded. Other fields are not selected, forwarded, or retained by NotchBot, but the raw payload still reaches the helper process. OpenCode constructs an allowlisted stdin payload containing `session_id`, `parent_session_id`, `cwd`, `task_label`, and, only after opt-in, `last_assistant_message`; it does not pass through its raw events.

The integration uses the helper and its `.notchbot-owner` marker, `integration-privacy.json`, `integration-installation.json`, transactional `integration-backups/claude-settings-<UUID>.backup` files, `event.key`, `instance.lock`, `notchbot.sock`, `~/.config/opencode/plugins/notchbot.js`, and NotchBot handlers in `~/.claude/settings.json`. All relative names are under `~/Library/Application Support/NotchBot/`. Transactional backups are removed after a verified settings update and retained only on failure. A legacy v0.1.0 `~/.claude/settings.json.notchbot-backup` is not modified automatically. NotchBot does not install integration files outside these paths.

## Sandbox Status

NotchBot 0.2.2 is not App Sandbox enabled and requests no signing entitlements. App Sandbox adoption is deferred to v0.3.0.
