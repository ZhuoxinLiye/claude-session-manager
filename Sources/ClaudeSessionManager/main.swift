import AppKit
import CryptoKit
import Foundation
import SwiftUI

// MARK: - Models

struct ServerProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var sshTarget: String
    var historyPath: String

    init(
        id: UUID = UUID(),
        name: String,
        sshTarget: String,
        historyPath: String = "~/.claude/history.jsonl"
    ) {
        self.id = id
        self.name = name
        self.sshTarget = sshTarget
        self.historyPath = historyPath
    }
}

enum ConversationTitleSource: String, Codable, Hashable {
    case inferred
    case custom
}

struct Conversation: Identifiable, Hashable, Codable {
    let id: String
    let serverID: UUID
    let serverName: String
    let sshTarget: String
    let sessionID: String
    let projectPath: String
    var title: String
    var titleSource: ConversationTitleSource
    let updatedAt: Date?
    let source: String

    init(
        id: String,
        serverID: UUID,
        serverName: String,
        sshTarget: String,
        sessionID: String,
        projectPath: String,
        title: String,
        titleSource: ConversationTitleSource = .inferred,
        updatedAt: Date?,
        source: String
    ) {
        self.id = id
        self.serverID = serverID
        self.serverName = serverName
        self.sshTarget = sshTarget
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.title = title
        self.titleSource = titleSource
        self.updatedAt = updatedAt
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, serverID, serverName, sshTarget, sessionID, projectPath, title
        case titleSource, updatedAt, source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        serverID = try container.decode(UUID.self, forKey: .serverID)
        serverName = try container.decode(String.self, forKey: .serverName)
        sshTarget = try container.decode(String.self, forKey: .sshTarget)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        title = try container.decode(String.self, forKey: .title)
        titleSource = try container.decodeIfPresent(ConversationTitleSource.self, forKey: .titleSource) ?? .inferred
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        source = try container.decode(String.self, forKey: .source)
    }

    var tmuxName: String {
        Self.preferredTmuxName(title: title, sessionID: sessionID)
    }

    static func stableTmuxName(forSessionID sessionID: String) -> String {
        // The session ID is the stable identity on one remote tmux server.
        // This name is used as a collision-free fallback and as migration key.
        let input = sessionID.lowercased()
        let digest = SHA256.hash(data: Data(input.utf8))
        return "cc-" + digest.map { String(format: "%02x", $0) }.joined().prefix(18)
    }

    static func lockName(forSessionID sessionID: String) -> String {
        "ccsm-lock-" + String(stableTmuxName(forSessionID: sessionID).dropFirst(3))
    }

    static func preferredTmuxName(title: String, sessionID: String) -> String {
        let digest = SHA256.hash(data: Data(sessionID.lowercased().utf8))
        let suffix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        let slug = titleSlug(title)
        return "cc-\(slug)-\(suffix)"
    }

    static func claudeCLIName(for title: String) -> String? {
        let candidate = title
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        return String(candidate.prefix(64))
    }

    private static func titleSlug(_ title: String) -> String {
        let normalized = title
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var result = ""
        var lastWasSeparator = false
        for scalar in normalized.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.append(String(scalar))
                lastWasSeparator = false
            } else if !lastWasSeparator {
                result.append("-")
                lastWasSeparator = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((trimmed.isEmpty ? "session" : trimmed).prefix(48))
    }

    static func legacyTmuxName(
        serverID: UUID,
        sshTarget: String,
        projectPath: String,
        sessionID: String
    ) -> String {
        let input = "\(serverID.uuidString)|\(sshTarget)|\(projectPath)|\(sessionID)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return "cc-" + digest.map { String(format: "%02x", $0) }.joined().prefix(18)
    }

    var legacyTmuxName: String {
        Self.legacyTmuxName(
            serverID: serverID,
            sshTarget: sshTarget,
            projectPath: projectPath,
            sessionID: sessionID
        )
    }

    func renamed(to newTitle: String) -> Conversation {
        Conversation(
            id: id,
            serverID: serverID,
            serverName: serverName,
            sshTarget: sshTarget,
            sessionID: sessionID,
            projectPath: projectPath,
            title: newTitle,
            titleSource: .custom,
            updatedAt: updatedAt,
            source: source
        )
    }
}

struct ActiveSession: Identifiable, Hashable {
    let id: String
    let serverID: UUID
    let serverName: String
    let name: String
    let attachedClients: Int
    let created: String
    let sessionID: String?
    let previousSessionID: String?
    let title: String?
}

struct RemoteHistoryResult {
    let conversations: [Conversation]
    let warning: String?
}

struct RemoteFileSignature: Codable, Equatable {
    let byteCount: Int
    let modifiedAt: Int64
}

struct HistoryCacheEntry: Codable {
    let signature: RemoteFileSignature?
    let byteOffset: Int
    let conversations: [Conversation]
    let warning: String?
}

struct ServerRefreshResult {
    let conversations: [Conversation]
    let sessions: [ActiveSession]
    let warning: String?
    let error: String?
    let cache: HistoryCacheEntry?
}

// MARK: - Persistence

enum LocalStore {
    private static let directoryName = "ClaudeSessionManager"

    private static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    private static var serversURL: URL {
        directoryURL.appendingPathComponent("servers.json")
    }

    private static var historyCacheURL: URL {
        directoryURL.appendingPathComponent("history-cache.json")
    }

    private static var directoryBookmarksURL: URL {
        directoryURL.appendingPathComponent("directory-bookmarks.json")
    }

    static func loadDirectoryBookmarks() -> [String: [String]] {
        guard let data = try? Data(contentsOf: directoryBookmarksURL),
              let bookmarks = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return bookmarks
    }

    static func saveDirectoryBookmarks(_ bookmarks: [String: [String]]) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(bookmarks).write(to: directoryBookmarksURL, options: .atomic)
    }

    static func loadServers() -> [ServerProfile] {
        guard let data = try? Data(contentsOf: serversURL),
              let servers = try? JSONDecoder().decode([ServerProfile].self, from: data) else {
            return []
        }
        return servers
    }

    static func saveServers(_ servers: [ServerProfile]) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(servers).write(to: serversURL, options: .atomic)
    }

    static func loadHistoryCache() -> [UUID: HistoryCacheEntry] {
        guard let data = try? Data(contentsOf: historyCacheURL),
              let cache = try? JSONDecoder().decode([UUID: HistoryCacheEntry].self, from: data) else {
            return [:]
        }
        return cache
    }

    static func saveHistoryCache(_ cache: [UUID: HistoryCacheEntry]) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(cache).write(to: historyCacheURL, options: .atomic)
    }
}

// MARK: - OpenSSH config discovery

enum SSHConfigReader {
    static func discoverAliases() -> [String] {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        var aliases: [String] = []
        var seenAliases = Set<String>()
        var visitedFiles = Set<String>()
        read(configURL, aliases: &aliases, seenAliases: &seenAliases, visitedFiles: &visitedFiles)
        return aliases
    }

    private static func read(
        _ url: URL,
        aliases: inout [String],
        seenAliases: inout Set<String>,
        visitedFiles: inout Set<String>
    ) {
        let normalizedURL = url.standardizedFileURL
        let path = normalizedURL.path
        guard !visitedFiles.contains(path),
              let contents = try? String(contentsOf: normalizedURL, encoding: .utf8) else {
            return
        }
        visitedFiles.insert(path)

        let baseDirectory = normalizedURL.deletingLastPathComponent()
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let directive = tokens.first?.lowercased() else { continue }

            if directive == "include" {
                for pattern in tokens.dropFirst() {
                    for includedURL in expandInclude(String(pattern), relativeTo: baseDirectory) {
                        read(includedURL, aliases: &aliases, seenAliases: &seenAliases, visitedFiles: &visitedFiles)
                    }
                }
            } else if directive == "host" {
                for alias in tokens.dropFirst() where isConcreteAlias(alias) && seenAliases.insert(alias).inserted {
                    aliases.append(alias)
                }
            }
        }
    }

    private static func isConcreteAlias(_ alias: String) -> Bool {
        !alias.isEmpty && !alias.contains("*") && !alias.contains("?") && !alias.contains("!")
    }

    private static func expandInclude(_ pattern: String, relativeTo baseDirectory: URL) -> [URL] {
        let expanded = (pattern as NSString).expandingTildeInPath
        let path = expanded.hasPrefix("/")
            ? expanded
            : baseDirectory.appendingPathComponent(expanded).path
        guard path.contains("*") || path.contains("?") else {
            return [URL(fileURLWithPath: path)]
        }

        let wildcardRange = path.rangeOfCharacter(from: CharacterSet(charactersIn: "*?"))
        guard let wildcardRange else { return [] }
        let prefix = String(path[..<wildcardRange.lowerBound])
        let directory = URL(fileURLWithPath: prefix).deletingLastPathComponent()
        let filenamePattern = URL(fileURLWithPath: path).lastPathComponent
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return false }
            return matches(filename: url.lastPathComponent, pattern: filenamePattern)
        }
    }

    private static func matches(filename: String, pattern: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return filename.range(of: "^\(escaped)$", options: .regularExpression) != nil
    }
}

// MARK: - Process execution

struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ProcessRunner {
    static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> ProcessResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: stdout, encoding: .utf8) ?? "",
            stderr: String(data: stderr, encoding: .utf8) ?? ""
        )
    }
}

enum SSHError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message
        }
    }
}

enum ShellQuoting {
    static func singleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func remotePath(_ value: String) -> String {
        if value == "~" {
            return "\"$HOME\""
        }
        if value.hasPrefix("~/") {
            let suffix = String(value.dropFirst(2))
            return "\"$HOME\"/\(singleQuote(suffix))"
        }
        return singleQuote(value)
    }
}

struct SSHClient {
    let server: ServerProfile

    func execute(_ remoteCommand: String, allocateTTY: Bool = false) throws -> String {
        var arguments: [String] = []
        if allocateTTY {
            arguments.append("-tt")
        } else {
            arguments.append("-T")
        }
        arguments.append(contentsOf: ["-o", "RemoteCommand=none"])
        arguments.append(server.sshTarget)
        arguments.append(remoteCommand)

        let result = try ProcessRunner.run("/usr/bin/ssh", arguments: arguments)
        guard result.status == 0 else {
            let details = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHError.commandFailed(details.isEmpty ? "SSH 命令失败（退出码 \(result.status)）" : details)
        }
        return result.stdout
    }

    func readHistory() throws -> String {
        let path = ShellQuoting.remotePath(server.historyPath)
        let fallback = "find \"$HOME/.claude/projects\" -type f -name '*.jsonl' -print0 2>/dev/null | xargs -0 cat 2>/dev/null || true"
        let titleEvents = "find \"$HOME/.claude/projects\" -type f -name '*.jsonl' -print0 | xargs -0 grep -hE '\"type\"[[:space:]]*:[[:space:]]*\"(custom-title|ai-title|agent-name)\"' 2>/dev/null || true"
        return try execute("if [ -f \(path) ]; then cat \(path); printf '\\n'; \(titleEvents); else \(fallback); fi")
    }

    func readSessionMetadata(for sessionIDs: [String]) throws -> String {
        let safeIDs = sessionIDs.filter { !$0.isEmpty && !$0.contains("'") }
        guard !safeIDs.isEmpty else { return "" }
        let nameExpression = safeIDs
            .map { "-name \(ShellQuoting.singleQuote("\($0).jsonl"))" }
            .joined(separator: " -o ")
        let command = "find \"$HOME/.claude/projects\" -type f \\( \(nameExpression) \\) -print0 | xargs -0 grep -hE '\"type\"[[:space:]]*:[[:space:]]*\"(custom-title|ai-title|agent-name)\"' 2>/dev/null || true"
        return try execute(command)
    }

    func historySignature() throws -> RemoteFileSignature? {
        let path = ShellQuoting.remotePath(server.historyPath)
        let command = "if [ -f \(path) ]; then if stat -c '%s %Y' \(path) 2>/dev/null; then :; else stat -f '%z %m' \(path) 2>/dev/null; fi; fi"
        let output = try execute(command).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2,
              let byteCount = Int(fields[0]),
              let modifiedAt = Int64(fields[1]) else {
            return nil
        }
        return RemoteFileSignature(byteCount: byteCount, modifiedAt: modifiedAt)
    }

    func readHistoryAppending(fromByteOffset offset: Int) throws -> String {
        let path = ShellQuoting.remotePath(server.historyPath)
        let start = max(1, offset + 1)
        return try execute("tail -c +\(start) \(path) 2>/dev/null || true")
    }

    func listSessions() throws -> [ActiveSession] {
        let format = ShellQuoting.singleQuote("#{session_name}\t#{session_attached}\t#{session_created_string}\t#{@ccsm_session_id}\t#{@ccsm_previous_session_id}\t#{@ccsm_title}")
        let output = try execute("tmux list-sessions -F \(format) 2>/dev/null || true")
        return output
            .split(whereSeparator: \ .isNewline)
            .compactMap { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 5, fields[0].hasPrefix("cc-") else { return nil }
                let previousSessionID: String?
                let titleIndex: Int
                if fields.count >= 6 {
                    previousSessionID = fields[4].isEmpty ? nil : fields[4]
                    titleIndex = 5
                } else {
                    previousSessionID = nil
                    titleIndex = 4
                }
                return ActiveSession(
                    id: fields[0],
                    serverID: server.id,
                    serverName: server.name,
                    name: fields[0],
                    attachedClients: Int(fields[1]) ?? 0,
                    created: fields[2],
                    sessionID: fields[3].isEmpty ? nil : fields[3],
                    previousSessionID: previousSessionID,
                    title: fields.count > titleIndex && !fields[titleIndex].isEmpty ? fields[titleIndex] : nil
                )
            }
    }

    func ensureSession(
        for conversation: Conversation,
        additionalLegacyNames: [String] = []
    ) throws -> String {
        let legacyNames = ([conversation.legacyTmuxName, Conversation.stableTmuxName(forSessionID: conversation.sessionID)] + additionalLegacyNames)
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { names, value in
                if !names.contains(value) {
                    names.append(value)
                }
            }
        return try ensureManagedSession(
            name: conversation.tmuxName,
            legacyNames: legacyNames,
            sessionID: conversation.sessionID,
            title: conversation.title,
            projectPath: conversation.projectPath,
            launch: resumeCommand(for: conversation)
        )
    }

    private func resumeCommand(for conversation: Conversation) -> String {
        "exec claude --settings \(ShellQuoting.singleQuote(sessionTrackingSettings())) --resume \(ShellQuoting.singleQuote(conversation.sessionID))"
    }

    func startSession(sessionID: String, title: String?, projectPath: String) throws -> String {
        let launch: String
        let settings = ShellQuoting.singleQuote(sessionTrackingSettings())
        if let title, let cliName = Conversation.claudeCLIName(for: title) {
            launch = "exec claude --settings \(settings) --session-id \(ShellQuoting.singleQuote(sessionID)) --name \(ShellQuoting.singleQuote(cliName))"
        } else {
            launch = "exec claude --settings \(settings) --session-id \(ShellQuoting.singleQuote(sessionID))"
        }
        return try ensureManagedSession(
            name: title.map { Conversation.preferredTmuxName(title: $0, sessionID: sessionID) }
                ?? Conversation.stableTmuxName(forSessionID: sessionID),
            legacyNames: [],
            sessionID: sessionID,
            title: title,
            projectPath: projectPath,
            launch: launch
        )
    }

    private func sessionTrackingSettings() -> String {
        // Claude Code sends the actual session ID to SessionStart hooks on startup,
        // /resume, /clear, compaction, and fork. Store that ID in tmux so the app
        // follows a session when the user switches conversations inside the tab.
        let hookCommand = #"""
        input=$(cat)
        session_id=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        case "$session_id" in
            "") exit 0 ;;
            *[!A-Za-z0-9_-]*) exit 0 ;;
        esac
        pane="${TMUX_PANE:-}"
        [ -n "$pane" ] || exit 0
        session_name=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null || true)
        [ -n "$session_name" ] || exit 0
        old_id=$(tmux display-message -p -t "$session_name" '#{@ccsm_session_id}' 2>/dev/null || true)
        if [ -n "$old_id" ] && [ "$old_id" != "$session_id" ]; then
            tmux set-option -t "$session_name" @ccsm_previous_session_id "$old_id" 2>/dev/null || true
        fi
        tmux set-option -t "$session_name" @ccsm_session_id "$session_id" 2>/dev/null || true
        tmux set-option -t "$session_name" @ccsm_project "$PWD" 2>/dev/null || true
        exit 0
        """#
        let settings: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    [
                        "hooks": [
                            [
                                "type": "command",
                                "command": hookCommand,
                                "timeout": 5
                            ]
                        ]
                    ]
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]),
              let result = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return result
    }

    private func ensureManagedSession(
        name: String,
        legacyNames: [String],
        sessionID: String,
        title: String?,
        projectPath: String,
        launch: String
    ) throws -> String {
        let session = ShellQuoting.singleQuote(name)
        let project = ShellQuoting.remotePath(projectPath)
        let command = "cd -- \(project) && exec ${SHELL:-/bin/sh} -lic \(ShellQuoting.singleQuote(launch))"
        let quotedCommand = ShellQuoting.singleQuote(command)
        let titleOption = title.map(ShellQuoting.singleQuote) ?? "''"
        let titleLookup = title.map(ShellQuoting.singleQuote) ?? "''"
        let titleMatch = title == nil
            ? "0"
            : "$3 == \"claude\" && ($2 == title || $2 == \"✳ \" title)"
        let lock = ShellQuoting.singleQuote(Conversation.lockName(forSessionID: sessionID))
        let expectedID = ShellQuoting.singleQuote(sessionID)
        let legacyCase = legacyNames
            .filter { !$0.isEmpty && $0 != name }
            .map { ShellQuoting.singleQuote($0) }
            .joined(separator: "|")
        let legacyCasePattern = legacyCase.isEmpty ? "__never_legacy_name__" : legacyCase
        let legacyLookup = legacyNames
            .filter { !$0.isEmpty && $0 != name }
            .map { legacyName in
                "if tmux has-session -t \(ShellQuoting.singleQuote(legacyName)) 2>/dev/null; then tmux rename-session -t \(ShellQuoting.singleQuote(legacyName)) \(session) 2>/dev/null || true; fi"
            }
            .joined(separator: "\n")
        let legacyLookupCommand = legacyLookup.isEmpty ? ":" : legacyLookup
        let commandLine = """
        lock_name=\(lock)
        tmux wait-for -L "$lock_name"
        release_lock() {
            tmux wait-for -U "$lock_name" 2>/dev/null || true
        }
        trap release_lock EXIT
        session_name=\(session)
        expected_id=\(expectedID)
        if tmux has-session -t "$session_name" 2>/dev/null; then
            current_id=$(tmux display-message -p -t "$session_name" '#{@ccsm_session_id}' 2>/dev/null || true)
            if [ -n "$current_id" ] && [ "$current_id" != "$expected_id" ]; then
                printf 'tmux 会话名已被另一个 Claude session 占用：%s\\n' "$session_name" >&2
                exit 17
            fi
            case "$session_name" in
                \(legacyCasePattern)) legacy_name=1 ;;
                *) legacy_name=0 ;;
            esac
            if [ -z "$current_id" ] && [ "$legacy_name" -eq 0 ]; then
                printf 'tmux 会话名已被未标记的会话占用：%s\\n' "$session_name" >&2
                exit 17
            fi
        fi
        if ! tmux has-session -t \"$session_name\" 2>/dev/null; then
            existing=$(tmux list-sessions -F '#{session_name}\t#{@ccsm_session_id}' 2>/dev/null | awk -F '\t' -v id=\(ShellQuoting.singleQuote(sessionID)) '$2 == id {print $1; exit}')
            if [ -n \"$existing\" ]; then
                tmux rename-session -t \"$existing\" \"$session_name\" 2>/dev/null || session_name=\"$existing\"
            else
                \(legacyLookupCommand)
                if ! tmux has-session -t \"$session_name\" 2>/dev/null; then
                    # Older app versions did not install the SessionStart hook. Claude
                    # still exposes its current display title as the tmux pane title,
                    # so reuse one unambiguous Claude pane after /resume or /new.
                    pane_matches=$(tmux list-panes -a -F '#{session_name}\t#{pane_title}\t#{pane_current_command}' 2>/dev/null | awk -F '\t' -v title=\(titleLookup) '\(titleMatch) {print $1}')
                    pane_count=$(printf '%s\\n' \"$pane_matches\" | awk 'NF {count++} END {print count + 0}')
                    if [ \"$pane_count\" -gt 1 ]; then
                        printf '多个活跃 Claude pane 使用了相同标题，无法安全判断要复用哪个 tmux：%s\\n' \(titleOption) >&2
                        exit 18
                    elif [ \"$pane_count\" -eq 1 ]; then
                        existing=$(printf '%s\\n' \"$pane_matches\" | awk 'NF {print; exit}')
                        current_id=$(tmux display-message -p -t \"$existing\" '#{@ccsm_session_id}' 2>/dev/null || true)
                        if [ -n \"$current_id\" ] && [ \"$current_id\" != \"$expected_id\" ]; then
                            tmux set-option -t \"$existing\" @ccsm_previous_session_id \"$current_id\" 2>/dev/null || true
                        fi
                        tmux rename-session -t \"$existing\" \"$session_name\" 2>/dev/null || session_name=\"$existing\"
                    else
                        tmux new-session -d -s \"$session_name\" \(quotedCommand) 2>/dev/null || tmux has-session -t \"$session_name\" 2>/dev/null || exit 1
                    fi
                fi
            fi
        fi
        tmux set-option -t \"$session_name\" @ccsm_session_id \(ShellQuoting.singleQuote(sessionID))
        tmux set-option -t \"$session_name\" @ccsm_project \(ShellQuoting.singleQuote(projectPath))
        tmux set-option -t \"$session_name\" @ccsm_title \(titleOption)
        printf '%s' \"$session_name\"
        """
        return try execute(commandLine).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func renameConversation(_ conversation: Conversation, to title: String) throws {
        let transcriptName = ShellQuoting.singleQuote("\(conversation.sessionID).jsonl")
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "custom-title",
            "customTitle": title,
            "sessionId": conversation.sessionID
        ], options: [.sortedKeys])
        guard let line = String(data: json, encoding: .utf8) else {
            throw SSHError.commandFailed("无法生成 Claude 标题记录")
        }
        let quotedLine = ShellQuoting.singleQuote(line)
        let newTmuxName = conversation.renamed(to: title).tmuxName
        let lock = ShellQuoting.singleQuote(Conversation.lockName(forSessionID: conversation.sessionID))
        let command = """
        lock_name=\(lock)
        tmux wait-for -L "$lock_name"
        release_lock() {
            tmux wait-for -U "$lock_name" 2>/dev/null || true
        }
        trap release_lock EXIT
        transcript=''
        attempt=0
        while [ -z \"$transcript\" ] && [ \"$attempt\" -lt 50 ]; do
            transcript=$(find \"$HOME/.claude/projects\" -type f -name \(transcriptName) -print -quit)
            if [ -z \"$transcript\" ]; then
                sleep 0.1
            fi
            attempt=$((attempt + 1))
        done
        if [ -z \"$transcript\" ]; then
            exit 3
        fi
        printf '%s\\n' \(quotedLine) >> \"$transcript\"
        existing=$(tmux list-sessions -F '#{session_name}\t#{@ccsm_session_id}' 2>/dev/null | awk -F '\t' -v id=\(ShellQuoting.singleQuote(conversation.sessionID)) '$2 == id {print $1; exit}')
        if [ -n \"$existing\" ]; then
            session_name=\"$existing\"
            if tmux rename-session -t \"$session_name\" \(ShellQuoting.singleQuote(newTmuxName)) 2>/dev/null; then
                session_name=\(ShellQuoting.singleQuote(newTmuxName))
            fi
            tmux set-option -t \"$session_name\" @ccsm_title \(ShellQuoting.singleQuote(title))
        fi
        printf '%s' \"$transcript\"
        """
        _ = try execute(command)
    }

    func killSession(named name: String) throws {
        _ = try execute("tmux kill-session -t \(ShellQuoting.singleQuote(name)) 2>/dev/null || true")
    }
}

// MARK: - Claude history adapter

enum ClaudeHistoryAdapter {
    static func parse(
        text: String,
        server: ServerProfile
    ) -> RemoteHistoryResult {
        var conversations: [String: Conversation] = [:]
        var titleOverrides: [String: (title: String, source: ConversationTitleSource)] = [:]
        var malformedLines = 0

        for line in text.split(whereSeparator: \ .isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                malformedLines += 1
                continue
            }

            let sessionID = stringValue(object, keys: ["sessionId", "session_id", "sessionID"])
            guard let sessionID, !sessionID.isEmpty else { continue }

            let type = stringValue(object, keys: ["type"])
            if let metadata = metadataTitle(object, type: type) {
                let shouldReplace = metadata.source == .custom || titleOverrides[sessionID] == nil
                if shouldReplace {
                    titleOverrides[sessionID] = metadata
                }
                continue
            }

            let display = stringValue(object, keys: ["display", "title", "summary", "prompt"])
                ?? messageText(object["message"])
            let project = stringValue(object, keys: ["project", "cwd", "projectPath", "project_path"]) ?? "~"
            let timestamp = dateValue(object, keys: ["timestamp", "updatedAt", "updated_at", "createdAt"])
            let title = normalizedTitle(display) ?? "未命名对话"

            let candidate = Conversation(
                id: "\(server.id.uuidString):\(sessionID)",
                serverID: server.id,
                serverName: server.name,
                sshTarget: server.sshTarget,
                sessionID: sessionID,
                projectPath: project,
                title: title,
                titleSource: .inferred,
                updatedAt: timestamp,
                source: server.historyPath
            )

            if let existing = conversations[sessionID] {
                let existingDate = existing.updatedAt ?? .distantPast
                let candidateDate = candidate.updatedAt ?? .distantPast
                if candidateDate >= existingDate {
                    conversations[sessionID] = candidate
                }
            } else {
                conversations[sessionID] = candidate
            }
        }

        for (sessionID, override) in titleOverrides {
            guard var conversation = conversations[sessionID] else { continue }
            conversation.title = override.title
            conversation.titleSource = override.source
            conversations[sessionID] = conversation
        }

        let result = conversations.values.sorted {
            ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
        let warning: String?
        if text.isEmpty {
            warning = "没有读取到 \(server.historyPath)。请确认服务器上的 Claude Code 记录路径。"
        } else if malformedLines > 0 {
            warning = "有 \(malformedLines) 行记录无法解析，已跳过。"
        } else {
            warning = nil
        }
        return RemoteHistoryResult(conversations: result, warning: warning)
    }

    static func applyTitleOverrides(
        from text: String,
        to conversations: [Conversation]
    ) -> [Conversation] {
        let overrides = titleOverrides(from: text)
        guard !overrides.isEmpty else { return conversations }
        return conversations.map { conversation in
            guard let override = overrides[conversation.sessionID] else { return conversation }
            var updated = conversation
            updated.title = override.title
            updated.titleSource = override.source
            return updated
        }
    }

    static func merge(
        cached: [Conversation],
        incremental: [Conversation]
    ) -> [Conversation] {
        var bySession = Dictionary(uniqueKeysWithValues: cached.map { ($0.sessionID, $0) })
        for conversation in incremental {
            guard let previous = bySession[conversation.sessionID] else {
                bySession[conversation.sessionID] = conversation
                continue
            }
            let previousDate = previous.updatedAt ?? .distantPast
            let newDate = conversation.updatedAt ?? .distantPast
            if conversation.titleSource == .custom
                || (previous.titleSource != .custom && (newDate >= previousDate || previous.title == "未命名对话")) {
                bySession[conversation.sessionID] = conversation
            }
        }
        return bySession.values.sorted {
            ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
    }

    private static func titleOverrides(
        from text: String
    ) -> [String: (title: String, source: ConversationTitleSource)] {
        var overrides: [String: (title: String, source: ConversationTitleSource)] = [:]
        for line in text.split(whereSeparator: \ .isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionID = stringValue(object, keys: ["sessionId", "session_id", "sessionID"]),
                  let metadata = metadataTitle(object, type: stringValue(object, keys: ["type"])) else {
                continue
            }
            if metadata.source == .custom || overrides[sessionID] == nil {
                overrides[sessionID] = metadata
            }
        }
        return overrides
    }

    private static func metadataTitle(
        _ object: [String: Any],
        type: String?
    ) -> (title: String, source: ConversationTitleSource)? {
        let normalizedType = type?.lowercased()
        let keys: [String]
        let source: ConversationTitleSource
        switch normalizedType {
        case "custom-title":
            keys = ["customTitle", "custom_title", "title", "display"]
            source = .custom
        case "ai-title":
            keys = ["aiTitle", "ai_title", "title", "display"]
            source = .inferred
        case "agent-name":
            keys = ["agentName", "agent_name", "name", "title", "display"]
            source = .inferred
        default:
            return nil
        }
        guard let title = normalizedTitle(stringValue(object, keys: keys)) else { return nil }
        return (title, source)
    }

    private static func stringValue(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func messageText(_ value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        if let message = value as? [String: Any] {
            if let content = message["content"] {
                return messageText(content)
            }
        }
        if let blocks = value as? [[String: Any]] {
            let text = blocks.compactMap { block -> String? in
                guard let type = block["type"] as? String, type == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: " ")
            return text.isEmpty ? nil : text
        }
        if let values = value as? [Any] {
            let text = values.compactMap(messageText).joined(separator: " ")
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func dateValue(_ object: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let number = object[key] as? NSNumber {
                let raw = number.doubleValue
                return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
            }
            if let string = object[key] as? String {
                if let numeric = Double(string) {
                    return Date(timeIntervalSince1970: numeric > 10_000_000_000 ? numeric / 1000 : numeric)
                }
                if let date = ISO8601DateFormatter().date(from: string) {
                    return date
                }
            }
        }
        return nil
    }

    static func normalizedTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let title = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return String(title.prefix(140))
    }
}

// MARK: - Ghostty bridge

enum GhosttyBridgeError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        }
    }
}

enum GhosttyTabOpenResult {
    case created
    case reused
}

struct GhosttyBridge {
    func openAttachTab(
        server: ServerProfile,
        tmuxName: String,
        title: String,
        sessionID: String? = nil
    ) throws -> GhosttyTabOpenResult {
        let remote = "tmux attach-session -t \(ShellQuoting.singleQuote(tmuxName))"
        // Many servers do not have Ghostty's xterm-ghostty terminfo entry yet.
        // Keep Ghostty unchanged locally, but send a widely available TERM value
        // to the remote PTY so tmux and ncurses applications can start.
        let command = "/usr/bin/env TERM=xterm-256color /usr/bin/ssh -tt -o RemoteCommand=none \(ShellQuoting.singleQuote(server.sshTarget)) \(ShellQuoting.singleQuote(remote))"
        let cleanTitle = title
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleTitle = String((cleanTitle.isEmpty ? "Claude 对话" : cleanTitle).prefix(80))
        let markerIdentity: String
        if let sessionID, !sessionID.isEmpty {
            markerIdentity = "session:\(sessionID.lowercased())"
        } else {
            // Old untagged tmux sessions may not expose a Claude session ID.
            // Including the SSH target keeps those fallback markers local to one profile.
            markerIdentity = "tmux:\(server.sshTarget.lowercased()):\(tmuxName)"
        }
        let marker = tabMarker(for: markerIdentity)
        let action = "set_tab_title:\(visibleTitle)\(marker)"
        let markerLiteral = appleScriptString(marker)
        let visibleTitleLiteral = appleScriptString(visibleTitle)
        let script = """
        tell application "Ghostty"
            -- A tab created by this app carries an invisible stable marker in its title.
            -- Select it instead of creating a second SSH client for the same tmux session.
            repeat with windowItem in windows
                repeat with tabItem in tabs of windowItem
                    try
                        set candidateTitle to name of tabItem
                        if candidateTitle contains \(markerLiteral) then
                            select tab tabItem
                            focus (focused terminal of tabItem)
                            perform action \(appleScriptString(action)) on focused terminal of tabItem
                            return "reused"
                        end if
                    end try
                end repeat
            end repeat

            -- Tabs created by versions before the marker was introduced only have the
            -- visible title. Reuse an unambiguous exact match as a compatibility fallback.
            set exactTitleCount to 0
            set exactTitleTab to missing value
            repeat with windowItem in windows
                repeat with tabItem in tabs of windowItem
                    try
                        if (name of tabItem) is \(visibleTitleLiteral) then
                            set exactTitleCount to exactTitleCount + 1
                            set exactTitleTab to tabItem
                        end if
                    end try
                end repeat
            end repeat
            if exactTitleCount is 1 then
                select tab exactTitleTab
                focus (focused terminal of exactTitleTab)
                perform action \(appleScriptString(action)) on focused terminal of exactTitleTab
                return "reused"
            end if

            set configuration to new surface configuration
            set command of configuration to \(appleScriptString(command))
            if (count of windows) > 0 then
                set createdTab to new tab in front window with configuration configuration
            else
                set createdWindow to new window with configuration configuration
                set createdTab to selected tab of createdWindow
            end if
            perform action \(appleScriptString(action)) on focused terminal of createdTab
            select tab createdTab
            focus (focused terminal of createdTab)
            return "created"
        end tell
        """

        let result = try ProcessRunner.run("/usr/bin/osascript", arguments: ["-e", script])
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GhosttyBridgeError.unavailable(detail.isEmpty ? "无法通过 AppleScript 打开 Ghostty。" : detail)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "reused" ? .reused : .created
    }

    private func tabMarker(for identity: String) -> String {
        let digest = SHA256.hash(data: Data(identity.utf8))
        // Two invisible code points encode one bit. Twelve digest bytes keep the
        // marker short while making collisions impractical for local tabs.
        var bits = ""
        for byte in digest.prefix(12) {
            for shift in 0..<8 {
                bits.append(((byte >> (7 - shift)) & 1) == 0 ? "\u{200B}" : "\u{200C}")
            }
        }
        return "\u{2063}\u{2062}" + bits + "\u{2062}\u{2063}"
    }

    @discardableResult
    func updateExistingTab(
        sessionID: String,
        title: String,
        previousTitle: String? = nil
    ) throws -> Bool {
        guard !sessionID.isEmpty else { return false }
        let cleanTitle = title
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleTitle = String((cleanTitle.isEmpty ? "Claude 对话" : cleanTitle).prefix(80))
        let marker = tabMarker(for: "session:\(sessionID.lowercased())")
        let action = "set_tab_title:\(visibleTitle)\(marker)"
        let markerLiteral = appleScriptString(marker)
        let previousMatch: String
        if let previousTitle {
            let oldTitle = previousTitle
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let oldVisibleTitle = String((oldTitle.isEmpty ? "Claude 对话" : oldTitle).prefix(80))
            previousMatch = """
            repeat with windowItem in windows
                repeat with tabItem in tabs of windowItem
                    try
                        if (name of tabItem) is \(appleScriptString(oldVisibleTitle)) then
                            perform action \(appleScriptString(action)) on focused terminal of tabItem
                            return "updated"
                        end if
                    end try
                end repeat
            end repeat
            """
        } else {
            previousMatch = ""
        }
        let script = """
        tell application "Ghostty"
            repeat with windowItem in windows
                repeat with tabItem in tabs of windowItem
                    try
                        if (name of tabItem) contains \(markerLiteral) then
                            perform action \(appleScriptString(action)) on focused terminal of tabItem
                            return "updated"
                        end if
                    end try
                end repeat
            end repeat
            \(previousMatch)
            return "missing"
        end tell
        """
        let result = try ProcessRunner.run("/usr/bin/osascript", arguments: ["-e", script])
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GhosttyBridgeError.unavailable(detail.isEmpty ? "无法更新 Ghostty tab 标题。" : detail)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "updated"
    }

    @discardableResult
    func rebindExistingTab(
        from oldSessionID: String,
        to newSessionID: String,
        title: String
    ) throws -> Bool {
        guard !oldSessionID.isEmpty, !newSessionID.isEmpty, oldSessionID != newSessionID else {
            return false
        }
        let cleanTitle = title
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleTitle = String((cleanTitle.isEmpty ? "Claude 对话" : cleanTitle).prefix(80))
        let oldMarkerLiteral = appleScriptString(tabMarker(for: "session:\(oldSessionID.lowercased())"))
        let newMarker = tabMarker(for: "session:\(newSessionID.lowercased())")
        let action = "set_tab_title:\(visibleTitle)\(newMarker)"
        let script = """
        tell application "Ghostty"
            repeat with windowItem in windows
                repeat with tabItem in tabs of windowItem
                    try
                        if (name of tabItem) contains \(oldMarkerLiteral) then
                            select tab tabItem
                            focus (focused terminal of tabItem)
                            perform action \(appleScriptString(action)) on focused terminal of tabItem
                            return "updated"
                        end if
                    end try
                end repeat
            end repeat
            return "missing"
        end tell
        """
        let result = try ProcessRunner.run("/usr/bin/osascript", arguments: ["-e", script])
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GhosttyBridgeError.unavailable(detail.isEmpty ? "无法更新 Ghostty tab 标题。" : detail)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "updated"
    }

    private func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

// MARK: - App state

@MainActor
final class AppState: ObservableObject {
    @Published var servers: [ServerProfile] = []
    @Published var selectedServerID: UUID?
    @Published var conversations: [Conversation] = []
    @Published var activeSessions: [ActiveSession] = []
    @Published var selectedConversationID: String?
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var statusMessage: String?
    @Published var lastError: String?
    @Published var showingAddServer = false
    @Published var showingNewConversation = false
    @Published var renameTarget: Conversation?
    @Published private(set) var directoryBookmarks = LocalStore.loadDirectoryBookmarks()

    private let ghostty = GhosttyBridge()
    private var historyCache: [UUID: HistoryCacheEntry] = LocalStore.loadHistoryCache()

    init() {
        servers = LocalStore.loadServers()
        importFromSSHConfig()
        selectedServerID = nil
    }

    var selectedServer: ServerProfile? {
        guard let selectedServerID else { return nil }
        return servers.first(where: { $0.id == selectedServerID })
    }

    var selectedConversation: Conversation? {
        guard let selectedConversationID else { return nil }
        return conversations.first(where: { $0.id == selectedConversationID })
    }

    var filteredConversations: [Conversation] {
        let serverConversations: [Conversation]
        if let selectedServerID {
            serverConversations = conversations.filter { $0.serverID == selectedServerID }
        } else {
            serverConversations = []
        }
        guard !searchText.isEmpty else { return serverConversations }
        return serverConversations.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.projectPath.localizedCaseInsensitiveContains(searchText)
                || $0.serverName.localizedCaseInsensitiveContains(searchText)
                || $0.sessionID.localizedCaseInsensitiveContains(searchText)
        }
    }

    var selectedActiveSessions: [ActiveSession] {
        guard let selectedServerID else { return [] }
        return activeSessions.filter { $0.serverID == selectedServerID }
    }

    func conversation(for session: ActiveSession) -> Conversation? {
        conversations.first { conversation in
            isManagedSession(session, for: conversation)
        }
    }

    func isManagedSession(_ session: ActiveSession, for conversation: Conversation) -> Bool {
        let names = [
            conversation.tmuxName,
            conversation.legacyTmuxName,
            Conversation.stableTmuxName(forSessionID: conversation.sessionID)
        ] + servers.map {
            Conversation.legacyTmuxName(
                serverID: $0.id,
                sshTarget: $0.sshTarget,
                projectPath: conversation.projectPath,
                sessionID: conversation.sessionID
            )
        }
        return names.contains(session.name)
            || (session.sessionID == conversation.sessionID && session.sessionID != nil)
    }

    func title(for session: ActiveSession) -> String {
        conversation(for: session)?.title ?? session.title ?? session.name
    }

    func beginRename(_ conversation: Conversation) {
        renameTarget = conversation
    }

    func bookmarkedDirectories(for server: ServerProfile) -> [String] {
        directoryBookmarks[server.sshTarget] ?? []
    }

    func toggleDirectoryBookmark(_ path: String, for server: ServerProfile) throws {
        var updated = directoryBookmarks
        var paths = updated[server.sshTarget] ?? []
        if paths.contains(path) {
            paths.removeAll { $0 == path }
        } else {
            paths.append(path)
        }
        updated[server.sshTarget] = paths
        try LocalStore.saveDirectoryBookmarks(updated)
        directoryBookmarks = updated
    }

    func rename(_ conversation: Conversation, to rawTitle: String) {
        guard let title = ClaudeHistoryAdapter.normalizedTitle(rawTitle) else {
            lastError = "聊天标题不能为空"
            return
        }
        statusMessage = "正在重命名聊天…"
        lastError = nil
        Task {
            do {
                guard let server = servers.first(where: { $0.id == conversation.serverID }) else {
                    throw SSHError.commandFailed("找不到服务器配置")
                }
                try await Task.detached(priority: .userInitiated) {
                    try SSHClient(server: server).renameConversation(conversation, to: title)
                }.value
                let renamed = conversation.renamed(to: title)
                replaceConversation(renamed)
                _ = try? ghostty.updateExistingTab(
                    sessionID: conversation.sessionID,
                    title: title,
                    previousTitle: conversation.title
                )
                statusMessage = "已重命名：\(title)"
                await refreshSelectedServer()
            } catch {
                lastError = error.localizedDescription
                statusMessage = nil
            }
        }
    }

    func startNewConversation(
        title rawTitle: String?,
        projectPath rawProjectPath: String,
        on server: ServerProfile
    ) {
        let title = rawTitle.flatMap(ClaudeHistoryAdapter.normalizedTitle)
        let projectPath = rawProjectPath.isEmpty ? "~" : rawProjectPath
        let sessionID = UUID().uuidString.lowercased()
        statusMessage = "正在创建新的 Claude 会话…"
        lastError = nil
        Task {
            do {
                let tmuxName = try await Task.detached(priority: .userInitiated) {
                    try SSHClient(server: server).startSession(
                        sessionID: sessionID,
                        title: title,
                        projectPath: projectPath
                    )
                }.value
                let tabResult = try ghostty.openAttachTab(
                    server: server,
                    tmuxName: tmuxName,
                    title: title ?? "新建 Claude 对话",
                    sessionID: sessionID
                )
                switch tabResult {
                case .created:
                    statusMessage = title.map { "已在 Ghostty 中打开：\($0)" } ?? "已在 Ghostty 中打开新对话"
                case .reused:
                    statusMessage = title.map { "已切换到已打开的 Ghostty tab：\($0)" } ?? "已切换到已打开的新对话"
                }
                await refreshSelectedServer()
            } catch {
                lastError = error.localizedDescription
                statusMessage = nil
            }
        }
    }

    func addServer(_ server: ServerProfile) {
        servers.append(server)
        selectedServerID = server.id
        persistServers()
    }

    func importFromSSHConfig() {
        let aliases = SSHConfigReader.discoverAliases()
        let knownTargets = Set(servers.map(\.sshTarget))
        let imported = aliases.filter { !knownTargets.contains($0) }.map {
            ServerProfile(name: $0, sshTarget: $0)
        }
        guard !imported.isEmpty else { return }
        servers.append(contentsOf: imported)
        persistServers()
        statusMessage = "已从 SSH config 导入 \(imported.count) 台服务器"
    }

    func removeServer(_ server: ServerProfile) {
        servers.removeAll { $0.id == server.id }
        if selectedServerID == server.id {
            selectedServerID = servers.first?.id
        }
        conversations.removeAll { $0.serverID == server.id }
        historyCache.removeValue(forKey: server.id)
        try? LocalStore.saveHistoryCache(historyCache)
        if selectedServerID == nil {
            conversations = []
            activeSessions = []
            selectedConversationID = nil
        }
        persistServers()
    }

    func refresh() async {
        importFromSSHConfig()
        await refreshSelectedServer()
    }

    func serverSelectionChanged() {
        conversations = []
        activeSessions = []
        selectedConversationID = nil
        lastError = nil
        Task { await refreshSelectedServer() }
    }

    func refreshSelectedServer() async {
        guard let server = selectedServer else {
            conversations = []
            activeSessions = []
            return
        }
        isLoading = true
        lastError = nil
        statusMessage = "正在读取 \(server.name) 的 Claude Code 记录…"

        let cachedEntry = historyCache[server.id]
        let result = await Task.detached(priority: .userInitiated) { () -> ServerRefreshResult in
            do {
                let client = SSHClient(server: server)
                let signature = try client.historySignature()
                let parsedConversations: [Conversation]
                let warning: String?

                if let signature,
                   let cachedEntry,
                   cachedEntry.signature == signature {
                    parsedConversations = cachedEntry.conversations
                    warning = cachedEntry.warning
                } else if let signature,
                          let cachedEntry,
                          let cachedSignature = cachedEntry.signature,
                          signature.byteCount > cachedEntry.byteOffset,
                          signature.modifiedAt >= cachedSignature.modifiedAt {
                    let suffix = try client.readHistoryAppending(fromByteOffset: cachedEntry.byteOffset)
                    let parsed = ClaudeHistoryAdapter.parse(text: suffix, server: server)
                    parsedConversations = ClaudeHistoryAdapter.merge(cached: cachedEntry.conversations, incremental: parsed.conversations)
                    warning = parsed.warning
                } else {
                    let history = try client.readHistory()
                    let parsed = ClaudeHistoryAdapter.parse(text: history, server: server)
                    parsedConversations = parsed.conversations
                    warning = parsed.warning
                }

                let metadata = (try? client.readSessionMetadata(for: parsedConversations.map(\.sessionID))) ?? ""
                let conversations = ClaudeHistoryAdapter.applyTitleOverrides(from: metadata, to: parsedConversations)

                let currentSignature = try client.historySignature() ?? signature
                let cache = HistoryCacheEntry(
                    signature: currentSignature,
                    byteOffset: currentSignature?.byteCount ?? 0,
                    conversations: conversations,
                    warning: warning
                )
                return ServerRefreshResult(
                    conversations: conversations,
                    sessions: try client.listSessions(),
                    warning: warning,
                    error: nil,
                    cache: cache
                )
            } catch {
                return ServerRefreshResult(
                    conversations: [],
                    sessions: [],
                    warning: nil,
                    error: error.localizedDescription,
                    cache: nil
                )
            }
        }.value

        guard selectedServerID == server.id else { return }

        conversations = result.conversations.sorted {
            ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
        let previousActiveSessions = activeSessions
        let reconciled = reconcileActiveSessions(result.sessions, conversations: conversations)
        activeSessions = reconciled.sessions
        rebindChangedGhosttyTabs(
            previous: previousActiveSessions,
            current: reconciled.sessions,
            conversations: conversations
        )
        isLoading = false
        if let cache = result.cache {
            historyCache[server.id] = cache
            try? LocalStore.saveHistoryCache(historyCache)
        }
        if let error = result.error {
            statusMessage = nil
            lastError = "\(server.name)：\(error)"
        } else {
            statusMessage = "已更新 \(server.name)：\(conversations.count) 个对话，\(activeSessions.count) 个活跃会话"
            if reconciled.duplicateCount > 0 {
                lastError = "检测到 \(reconciled.duplicateCount) 个重复 tmux 连接，已全部列出；请保留一个并结束其余旧会话。"
            } else {
                lastError = result.warning
            }
        }
    }

    func open(_ conversation: Conversation) {
        statusMessage = "正在创建 tmux 会话…"
        lastError = nil
        Task {
            do {
                guard let server = servers.first(where: { $0.id == conversation.serverID }) else {
                    throw SSHError.commandFailed("找不到服务器配置")
                }
                let legacyNames = servers.map {
                    Conversation.legacyTmuxName(
                        serverID: $0.id,
                        sshTarget: $0.sshTarget,
                        projectPath: conversation.projectPath,
                        sessionID: conversation.sessionID
                    )
                }
                let resolution = try await Task.detached(priority: .userInitiated) { () -> (name: String, before: [ActiveSession], after: [ActiveSession]) in
                    let client = SSHClient(server: server)
                    let before = (try? client.listSessions()) ?? []
                    let name = try client.ensureSession(
                        for: conversation,
                        additionalLegacyNames: legacyNames
                    )
                    let after = (try? client.listSessions()) ?? []
                    return (name, before, after)
                }.value
                let tmuxName = resolution.name
                let previousSessionID = resolution.after.first(where: { $0.name == tmuxName })?.previousSessionID
                    ?? resolution.before.first(where: { $0.name == tmuxName })?.sessionID
                if let previousSessionID,
                   previousSessionID != conversation.sessionID {
                    _ = try? ghostty.rebindExistingTab(
                        from: previousSessionID,
                        to: conversation.sessionID,
                        title: conversation.title
                    )
                }
                let tabResult = try ghostty.openAttachTab(
                    server: server,
                    tmuxName: tmuxName,
                    title: conversation.title,
                    sessionID: conversation.sessionID
                )
                selectedConversationID = conversation.id
                statusMessage = tabResult == .reused
                    ? "已切换到已打开的 Ghostty tab：\(conversation.title)"
                    : "已在 Ghostty 中打开：\(conversation.title)"
                await refreshSelectedServer()
            } catch {
                lastError = error.localizedDescription
                statusMessage = nil
            }
        }
    }

    func attach(_ session: ActiveSession) {
        guard let server = selectedServer else { return }
        do {
            let title = title(for: session)
            let tabResult = try ghostty.openAttachTab(
                server: server,
                tmuxName: session.name,
                title: title,
                sessionID: session.sessionID
            )
            statusMessage = tabResult == .reused
                ? "已切换到已打开的 Ghostty tab：\(title)"
                : "已重新连接 \(title)"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func end(_ session: ActiveSession) {
        guard let server = selectedServer else { return }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SSHClient(server: server).killSession(named: session.name)
                }.value
                await refreshSelectedServer()
                statusMessage = "已结束 \(session.name)"
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func persistServers() {
        do {
            try LocalStore.saveServers(servers)
        } catch {
            lastError = "保存服务器配置失败：\(error.localizedDescription)"
        }
    }

    private func replaceConversation(_ conversation: Conversation) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index] = conversation
        guard let serverID = selectedServerID,
              var cache = historyCache[serverID] else { return }
        cache = HistoryCacheEntry(
            signature: cache.signature,
            byteOffset: cache.byteOffset,
            conversations: cache.conversations.map { $0.id == conversation.id ? conversation : $0 },
            warning: cache.warning
        )
        historyCache[serverID] = cache
        try? LocalStore.saveHistoryCache(historyCache)
    }

    private func reconcileActiveSessions(
        _ sessions: [ActiveSession],
        conversations: [Conversation]
    ) -> (sessions: [ActiveSession], duplicateCount: Int) {
        var groups: [String: [ActiveSession]] = [:]
        for session in sessions {
            if let sessionID = session.sessionID {
                groups["session:\(sessionID)", default: []].append(session)
            } else if let conversation = conversations.first(where: { isManagedSession(session, for: $0) }) {
                groups["session:\(conversation.sessionID)", default: []].append(session)
            }
        }
        let duplicateCount = groups.values.reduce(into: 0) { count, group in
            count += max(0, group.count - 1)
        }
        // Keep every duplicate visible so the user can identify and end stale
        // sessions left by an older app version or a previous race.
        return (sessions.sorted { $0.created < $1.created }, duplicateCount)
    }

    private func rebindChangedGhosttyTabs(
        previous: [ActiveSession],
        current: [ActiveSession],
        conversations: [Conversation]
    ) {
        let previousByName = Dictionary(uniqueKeysWithValues: previous.map { ($0.name, $0) })
        for session in current {
            guard let newSessionID = session.sessionID,
                  let previousSessionID = session.previousSessionID
                    ?? previousByName[session.name]?.sessionID,
                  previousSessionID != newSessionID,
                  let conversation = conversations.first(where: { $0.sessionID == newSessionID }) else {
                continue
            }
            _ = try? ghostty.rebindExistingTab(
                from: previousSessionID,
                to: newSessionID,
                title: conversation.title
            )
        }
    }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            ConversationView()
        }
        .frame(minWidth: 980, minHeight: 640)
        .task {
            await state.refresh()
        }
        .onChange(of: state.selectedServerID) { _, _ in
            state.serverSelectionChanged()
        }
        .sheet(isPresented: $state.showingAddServer) {
            AddServerView()
                .environmentObject(state)
        }
        .sheet(isPresented: $state.showingNewConversation) {
            if let server = state.selectedServer {
                NewConversationView(
                    server: server,
                    defaultProjectPath: state.selectedConversation?.projectPath ?? "~"
                )
                .environmentObject(state)
            }
        }
        .sheet(item: $state.renameTarget) { conversation in
            RenameConversationView(conversation: conversation)
                .environmentObject(state)
        }
        .alert("连接或操作失败", isPresented: Binding(
            get: { state.lastError != nil },
            set: { if !$0 { state.lastError = nil } }
        )) {
            Button("好") { state.lastError = nil }
        } message: {
            Text(state.lastError ?? "")
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        List(selection: $state.selectedServerID) {
            Section("服务器") {
                ForEach(state.servers) { server in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                            Text(server.sshTarget)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "server.rack")
                    }
                    .tag(server.id)
                    .contextMenu {
                        Button("移除服务器", role: .destructive) {
                            state.removeServer(server)
                        }
                    }
                }
            }

            if state.selectedServer != nil {
                Section("活跃 tmux") {
                    if state.selectedActiveSessions.isEmpty {
                        Text("没有活跃会话")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(state.selectedActiveSessions) { session in
                            HStack {
                                Image(systemName: "terminal")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(state.title(for: session))
                                        .lineLimit(1)
                                    Text(session.attachedClients > 0 ? "已连接" : "后台运行")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(session.name)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if let conversation = state.conversation(for: session) {
                                    Button {
                                        state.beginRename(conversation)
                                    } label: {
                                        Image(systemName: "pencil")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("重命名聊天")
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { state.attach(session) }
                            .contextMenu {
                                Button("进入") { state.attach(session) }
                                if let conversation = state.conversation(for: session) {
                                    Button("重命名") { state.beginRename(conversation) }
                                }
                                Button("结束会话", role: .destructive) { state.end(session) }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    state.showingAddServer = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("添加服务器")

                Button {
                    state.importFromSSHConfig()
                    Task { await state.refresh() }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .help("从 ~/.ssh/config 导入")

                Button {
                    Task { await state.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
                .disabled(state.isLoading)
            }
        }
    }
}

struct ConversationView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.selectedServer?.name ?? "选择服务器")
                        .font(.title2.weight(.semibold))
                    Text(state.selectedServer?.sshTarget ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    state.showingNewConversation = true
                } label: {
                    Label("新建对话", systemImage: "plus.bubble")
                }
                .disabled(state.selectedServer == nil || state.isLoading)
                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()

            if state.servers.isEmpty {
                ContentUnavailableView("还没有服务器", systemImage: "server.rack", description: Text("点击左下角的加号添加 SSH 主机。"))
            } else if state.selectedServer == nil {
                ContentUnavailableView("选择服务器", systemImage: "server.rack", description: Text("从左侧选择一台服务器后再读取对话记录。"))
            } else if state.filteredConversations.isEmpty {
                ContentUnavailableView("没有找到对话", systemImage: "bubble.left.and.bubble.right", description: Text("刷新服务器记录，或调整搜索条件。"))
            } else {
                List(selection: $state.selectedConversationID) {
                    ForEach(state.filteredConversations) { conversation in
                        ConversationRow(conversation: conversation)
                            .tag(conversation.id)
                            .contextMenu {
                                Button("打开") { state.open(conversation) }
                                Button("重命名") { state.beginRename(conversation) }
                            }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack(spacing: 12) {
                TextField("搜索对话、项目或 session ID", text: $state.searchText)
                    .textFieldStyle(.roundedBorder)
                if let statusMessage = state.statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    if let id = state.selectedConversationID,
                       let conversation = state.conversations.first(where: { $0.id == id }) {
                        state.open(conversation)
                    }
                } label: {
                    Label("打开", systemImage: "arrow.up.right.square")
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(state.selectedConversationID == nil)
            }
            .padding(14)
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    @EnvironmentObject private var state: AppState

    var isActive: Bool {
        state.activeSessions.contains { state.isManagedSession($0, for: conversation) }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                .foregroundStyle(isActive ? .green : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(conversation.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Label(conversation.projectPath, systemImage: "folder")
                    if let updatedAt = conversation.updatedAt {
                        Text(updatedAt, style: .relative)
                    }
                    if isActive {
                        Text("运行中")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                state.beginRename(conversation)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("重命名聊天")
            Button {
                state.open(conversation)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help(isActive ? "重新进入 tmux 会话" : "创建并打开 tmux 会话")
        }
        .padding(.vertical, 6)
    }
}

struct RenameConversationView: View {
    let conversation: Conversation
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form: RenameConversationForm

    init(conversation: Conversation) {
        self.conversation = conversation
        _form = StateObject(wrappedValue: RenameConversationForm(title: conversation.title))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("重命名聊天")
                .font(.title2.weight(.semibold))
            Text("标题会写入 Claude Code 的 session 记录，并同步活跃 tmux 的显示名称。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("聊天标题", text: $form.title)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    state.rename(conversation, to: form.title)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ClaudeHistoryAdapter.normalizedTitle(form.title) == nil)
            }
        }
        .padding(24)
        .frame(width: 470)
    }
}

struct NewConversationView: View {
    let server: ServerProfile
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form: NewConversationForm
    init(server: ServerProfile, defaultProjectPath: String) {
        self.server = server
        _form = StateObject(wrappedValue: NewConversationForm(projectPath: defaultProjectPath))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新建 Claude 对话")
                .font(.title2.weight(.semibold))
            Label(server.name, systemImage: "server.rack")
                .font(.subheadline.weight(.medium))
            Text("在选定项目目录创建持久 tmux 会话，并在 Ghostty 中打开。标题留空时由 Claude Code 自动生成。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("标题（可选）")
                    .font(.subheadline)
                TextField("让 Claude Code 自动生成标题", text: $form.title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("远程项目目录")
                    .font(.subheadline)
                HStack {
                    TextField("~/projects/my-project", text: $form.projectPath)
                        .textFieldStyle(.roundedBorder)
                        .help("服务器上的目录，支持绝对路径和 ~/")
                    Button {
                        form.showingDirectoryPicker = true
                    } label: {
                        Label("浏览…", systemImage: "folder")
                    }
                    .keyboardShortcut("o", modifiers: [.command])
                }
                if !state.bookmarkedDirectories(for: server).isEmpty {
                    Menu {
                        ForEach(state.bookmarkedDirectories(for: server), id: \.self) { path in
                            Button(path) { form.projectPath = path }
                        }
                        Divider()
                        Button("管理收藏…") { form.showingDirectoryPicker = true }
                    } label: {
                        Label("收藏目录", systemImage: "star")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("创建并打开") {
                    state.startNewConversation(
                        title: form.title,
                        projectPath: form.projectPath,
                        on: server
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .sheet(isPresented: $form.showingDirectoryPicker) {
            RemoteDirectoryPicker(server: server, initialPath: form.projectPath) { path in
                form.projectPath = path
            }
        }
    }
}

struct AddServerView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = AddServerForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("添加服务器")
                .font(.title2.weight(.semibold))

            Form {
                TextField("名称", text: $form.name)
                TextField("SSH 主机或别名", text: $form.sshTarget)
                    .help("可以填写 user@host，也可以填写 ~/.ssh/config 中的 Host 别名")
                TextField("Claude Code 历史路径", text: $form.historyPath)
                    .help("默认读取 ~/.claude/history.jsonl")
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加") {
                    let trimmedTarget = form.sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedTarget.isEmpty else { return }
                    let trimmedName = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    state.addServer(ServerProfile(
                        name: trimmedName.isEmpty ? trimmedTarget : trimmedName,
                        sshTarget: trimmedTarget,
                        historyPath: form.historyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "~/.claude/history.jsonl" : form.historyPath
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(form.sshTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 470)
    }
}

@MainActor
final class AddServerForm: ObservableObject {
    @Published var name = ""
    @Published var sshTarget = ""
    @Published var historyPath = "~/.claude/history.jsonl"
}

@MainActor
final class RenameConversationForm: ObservableObject {
    @Published var title: String

    init(title: String) {
        self.title = title
    }
}

@MainActor
final class NewConversationForm: ObservableObject {
    @Published var title = ""
    @Published var projectPath: String
    @Published var showingDirectoryPicker = false

    init(projectPath: String) {
        self.projectPath = projectPath
    }
}

@main
struct ClaudeSessionManagerApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("刷新远程记录") {
                    Task { await state.refresh() }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}
