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
- Opens a stable tmux session per server/project/Claude session ID.
- Uses Ghostty's AppleScript dictionary to open a new tab and attach to tmux.
- Sets the Ghostty tab title to the selected Claude conversation title and keeps that title override after remote terminal updates.
- Closing the Ghostty tab only detaches SSH; the tmux session remains.
- The sidebar can reattach to active sessions or explicitly end them.
- Active tmux entries use the matching Claude conversation title as their primary label. If the history no longer contains a session, the deterministic internal tmux name is shown as a fallback.
- Ships with a native macOS icon generated from the terminal conversation mark in `Resources/AppIcon.icns`.

## Requirements

- macOS 14 or newer
- Swift 5.9 or newer, or the macOS Command Line Tools
- [Ghostty](https://ghostty.org/) installed locally
- `tmux` and `claude` installed on each remote host
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
- `GhosttyBridge` opens a new Ghostty tab and attaches to the deterministic tmux session for the selected conversation.

No telemetry or cloud service is required. Remote history is fetched only after a host is selected or refreshed.

## Contributing

Issues and pull requests are welcome. Please include the macOS version, Swift version, remote shell, Claude Code version, and a redacted reproduction when reporting SSH or history parsing problems.

## Known MVP limits

- The history adapter is intentionally tolerant and currently uses the fields commonly present in Claude Code JSONL (`sessionId`, `display`, `project`/`cwd`, and timestamps).
- The exact Claude Code version on each server may require a small adapter adjustment.
- Ghostty automation is currently implemented through its scripting dictionary. The app prefers a new tab in the front window and falls back to a new window when Ghostty has no open window.
- mosh transport is reserved for a later iteration; the current MVP uses OpenSSH plus tmux.

## License

This project is released under the [MIT License](LICENSE).
