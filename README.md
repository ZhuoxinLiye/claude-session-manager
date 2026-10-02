# Claude Session Manager

Native macOS SwiftUI app for browsing remote Claude Code conversations and opening them in Ghostty-backed tmux sessions.

The app is designed for a workflow where one Claude Code conversation maps to one durable remote tmux session:

1. Choose an SSH host from the hosts discovered in `~/.ssh/config`.
2. Browse that host's Claude Code history.
3. Open a conversation in a new Ghostty tab.
4. Close the tab whenever needed; the remote tmux and Claude Code process keep running.
5. Re-enter or explicitly end the session from the sidebar later.

The project is macOS-first and intentionally uses the system OpenSSH client instead of storing connection credentials in the app.

## Current behavior

- Stores multiple SSH targets locally under `~/Library/Application Support/ClaudeSessionManager/servers.json`.
- Imports concrete `Host` aliases from `~/.ssh/config` on launch and refresh, including common `Include` files.
- Uses the system `/usr/bin/ssh`, so existing `~/.ssh/config`, SSH agents, keys, and `ProxyJump` settings remain available.
- Overrides a profile's `RemoteCommand` for app-managed commands, while preserving the rest of the profile (including `ProxyJump` and identity settings).
- Reads only the currently selected server; switching servers or pressing refresh performs a fresh read for that server.
- Keeps a per-server cache in `~/Library/Application Support/ClaudeSessionManager/history-cache.json`; unchanged history files are served from cache, and append-only changes are read with `tail -c` from the previous byte offset.
- Starts with no server selected, so opening the app does not initiate a remote connection until the user chooses one.
- Reads `~/.claude/history.jsonl` by default.
- Falls back to scanning `~/.claude/projects/**/*.jsonl` when the history index is absent.
- Maps one Claude session ID to one managed tmux session on the remote host. The visible tmux name is `cc-<title-slug>-<session-hash>`; the session hash keeps equal titles collision-free.
- Uses Ghostty's AppleScript dictionary to open a tab and attach to tmux. Before creating one, it scans existing Ghostty tabs and selects the tab already associated with that Claude session.
- Sets the Ghostty tab title to the selected Claude conversation title and keeps that title override after remote terminal updates. A short invisible marker in the title lets the app recognize the tab without displaying an internal ID.
- Closing the Ghostty tab only detaches SSH; the tmux session remains.
- The sidebar can reattach to active sessions or explicitly end them.
- Active tmux entries use the matching Claude conversation title as their primary label. If the history no longer contains a session, the deterministic internal tmux name is shown as a fallback.
- A pencil action or the conversation context menu changes a title. The app appends Claude Code's `custom-title` transcript event, updates the tmux title metadata and open Ghostty tab, and migrates the tmux name.
- The current server view can create a new Claude session with an optional title and remote project path. The directory field opens a remote, one-level-at-a-time browser with VS Code-style double-click navigation, path entry, hidden-directory filtering, and per-server bookmarks. New sessions use `claude --session-id` and an ASCII-safe `--name` seed, then append the exact app title as Claude's `custom-title` event before opening a new Ghostty tab.
- Managed tmux sessions carry `@ccsm_session_id`, `@ccsm_project`, and `@ccsm_title` user options. These options let the app find a session by Claude session ID even after a title change or an SSH alias change.
- Claude processes launched by the app receive a per-session `SessionStart` hook through `--settings`. When Claude switches with `/resume`, `/clear`/new, compaction, or a fork, the hook updates the tmux session to the actual Claude session ID and records the previous ID for Ghostty tab migration. Opening the new conversation then reuses the existing tmux and tab instead of creating a second connection.
- Ships with a native macOS icon generated from the terminal conversation mark in `Resources/AppIcon.icns`.

## Requirements

- macOS 14 or newer
- Swift 5.9 or newer, or the macOS Command Line Tools
- [Ghostty](https://ghostty.org/) 1.3.0 or newer installed locally (the AppleScript API was introduced in 1.3.0)
- `tmux` and `claude` installed on each remote host
- A Claude Code version that supports `--session-id`, `--name`, `--settings`, `SessionStart` hooks, and the `custom-title` session event
- SSH access configured for each host, preferably through `~/.ssh/config`

The first Ghostty tab opened by the app may require macOS Automation permission. The app invokes `/usr/bin/ssh` and does not read or store private keys.

## Build

The project currently builds with the macOS Command Line Tools:

```bash
swift build
```

The resulting executable is at `.build/debug/ClaudeSessionManager`.

To rebuild the icon and app bundle:

```bash
swift scripts/render-icon.swift
scripts/build-icon.sh
scripts/build-app.sh
```

The generated app bundle is written to `outputs/ClaudeSessionManager.app`. Build output is intentionally ignored by Git.

## Architecture

- `SSHConfigReader` discovers concrete `Host` aliases, including common `Include` files.
- `SSHClient` runs non-interactive inspection commands over OpenSSH and lists only the selected host.
- `ClaudeHistoryAdapter` parses `~/.claude/history.jsonl`, with a fallback scan of `~/.claude/projects/**/*.jsonl`.
- `LocalStore` caches history signatures and parsed conversations under `~/Library/Application Support/ClaudeSessionManager/`.
- `RemoteDirectoryReader` lists only the selected directory's direct children over SSH; `directory-bookmarks.json` stores favorites locally, grouped by SSH target.
- `GhosttyBridge` finds or creates a Ghostty tab and attaches to the managed tmux session for the selected conversation. Its session marker is derived from the Claude session ID, so title changes do not create another tab.

No telemetry or cloud service is required. Remote history is fetched only after a host is selected or refreshed.

## Naming and duplicate sessions

The current naming scheme uses the Claude session ID as the identity and the title only as a readable prefix. Renaming a conversation therefore does not create a second logical session. The app also uses a tmux `wait-for` lock while it finds, migrates, or creates a session, so two quick clicks or two app windows cannot pass the check and create steps at the same time.

Older releases used a hash of the local server profile ID, SSH target, project path, and session ID. The same Claude conversation could consequently get different tmux names when it was opened through an SSH alias and a literal host, after SSH profiles were re-imported, or from different project paths. Older sessions are checked by their previous hash names when a conversation is opened; managed sessions created by the current release additionally expose their Claude session ID through tmux metadata.

If duplicate sessions already exist, the refresh warning lists every duplicate so that the stale entry can be ended from the active tmux panel. The app does not automatically kill a session because it cannot infer which attached terminal the user wants to keep. A duplicate without `@ccsm_session_id` may come from an older app release or from a manually created `cc-*` tmux session and has to be inspected before ending.

When a managed Claude process runs `/resume`, `/clear` (new conversation), or a fork inside its existing tmux tab, the app updates the tmux binding from the hook's `session_id`. The old Ghostty tab marker is migrated to the new conversation when the app refreshes or opens that conversation. A process launched by an older app version has no hook; when its pane title uniquely matches the selected conversation, the app can still migrate it by title. If there are multiple matching panes or no reliable match, it stops instead of guessing which transcript is active.

Ghostty tabs created before the session marker was introduced do not carry the marker. When there is no marker, the app reuses only an unambiguous tab whose visible title exactly matches the conversation title; if several tabs have that title, it creates a new marked tab rather than guessing which session to select.

## Contributing

Issues and pull requests are welcome. Please include the macOS version, Swift version, remote shell, Claude Code version, and a redacted reproduction when reporting SSH or history parsing problems.

## Known MVP limits

- The history adapter is intentionally tolerant and currently uses the fields commonly present in Claude Code JSONL (`sessionId`, `display`, `project`/`cwd`, and timestamps). Title metadata is read from `custom-title`, `ai-title`, and `agent-name` events.
- The exact Claude Code version on each server may require a small adapter adjustment.
- Ghostty automation is currently implemented through its scripting dictionary. The app prefers an existing matching tab, otherwise creates a tab in the front window and falls back to a new window when Ghostty has no open window.
- Title editing writes Claude Code's JSONL transcript event directly. This is the format used by Claude Code today; a future Claude Code release could change its internal event schema.
- If a user manually replaces a managed tab's title through another Ghostty action, the invisible association marker is removed; opening that conversation from the app once restores the marker.
- mosh transport is reserved for a later iteration; the current MVP uses OpenSSH plus tmux.

## License

This project is released under the [MIT License](LICENSE).
