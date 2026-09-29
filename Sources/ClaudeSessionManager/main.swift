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

struct Conversation: Identifiable, Hashable, Codable {
    let id: String
    let serverID: UUID
    let serverName: String
    let sshTarget: String
    let sessionID: String
    let projectPath: String
    let title: String
    let updatedAt: Date?
    let source: String

    var tmuxName: String {
        let input = "\(serverID.uuidString)|\(sshTarget)|\(projectPath)|\(sessionID)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return "cc-" + digest.map { String(format: "%02x", $0) }.joined().prefix(18)
    }
}

struct ActiveSession: Identifiable, Hashable {
    let id: String
    let serverID: UUID
    let serverName: String
    let name: String
    let attachedClients: Int
    let created: String
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
        return try execute("if [ -f \(path) ]; then cat \(path); else \(fallback); fi")
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
        let format = ShellQuoting.singleQuote("#{session_name}\t#{session_attached}\t#{session_created_string}")
        let output = try execute("tmux list-sessions -F \(format) 2>/dev/null || true")
        return output
            .split(whereSeparator: \ .isNewline)
            .compactMap { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 3, fields[0].hasPrefix("cc-") else { return nil }
                return ActiveSession(
                    id: fields[0],
                    serverID: server.id,
                    serverName: server.name,
                    name: fields[0],
                    attachedClients: Int(fields[1]) ?? 0,
                    created: fields[2]
                )
            }
    }

    func ensureSession(for conversation: Conversation) throws {
        let session = ShellQuoting.singleQuote(conversation.tmuxName)
        let project = ShellQuoting.remotePath(conversation.projectPath)
        let claudeSession = ShellQuoting.singleQuote(conversation.sessionID)
        let launch = "exec claude --resume \(claudeSession)"
        let command = "cd -- \(project) && exec ${SHELL:-/bin/sh} -lic \(ShellQuoting.singleQuote(launch))"
        let quotedCommand = ShellQuoting.singleQuote(command)
        _ = try execute("tmux has-session -t \(session) 2>/dev/null || tmux new-session -d -s \(session) \(quotedCommand)")
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
        var malformedLines = 0

        for line in text.split(whereSeparator: \ .isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                malformedLines += 1
                continue
            }

            let sessionID = stringValue(object, keys: ["sessionId", "session_id", "sessionID"])
            guard let sessionID, !sessionID.isEmpty else { continue }

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
            if newDate >= previousDate || previous.title == "未命名对话" {
                bySession[conversation.sessionID] = conversation
            }
        }
        return bySession.values.sorted {
            ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
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

    private static func normalizedTitle(_ value: String?) -> String? {
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

struct GhosttyBridge {
    func openAttachTab(server: ServerProfile, tmuxName: String, title: String) throws {
        let remote = "tmux attach-session -t \(ShellQuoting.singleQuote(tmuxName))"
        // Many servers do not have Ghostty's xterm-ghostty terminfo entry yet.
        // Keep Ghostty unchanged locally, but send a widely available TERM value
        // to the remote PTY so tmux and ncurses applications can start.
        let command = "/usr/bin/env TERM=xterm-256color /usr/bin/ssh -tt -o RemoteCommand=none \(ShellQuoting.singleQuote(server.sshTarget)) \(ShellQuoting.singleQuote(remote))"
        let cleanTitle = title
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let action = "set_tab_title:\(String(cleanTitle.prefix(80)))"
        let script = """
        tell application "Ghostty"
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
        end tell
        """

        let result = try ProcessRunner.run("/usr/bin/osascript", arguments: ["-e", script])
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GhosttyBridgeError.unavailable(detail.isEmpty ? "无法通过 AppleScript 打开 Ghostty。" : detail)
        }
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

    func title(for session: ActiveSession) -> String {
        conversations.first(where: { $0.tmuxName == session.name })?.title ?? session.name
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
                let conversations: [Conversation]
                let warning: String?

                if let signature,
                   let cachedEntry,
                   cachedEntry.signature == signature {
                    conversations = cachedEntry.conversations
                    warning = cachedEntry.warning
                } else if let signature,
                          let cachedEntry,
                          let cachedSignature = cachedEntry.signature,
                          signature.byteCount > cachedEntry.byteOffset,
                          signature.modifiedAt >= cachedSignature.modifiedAt {
                    let suffix = try client.readHistoryAppending(fromByteOffset: cachedEntry.byteOffset)
                    let parsed = ClaudeHistoryAdapter.parse(text: suffix, server: server)
                    conversations = ClaudeHistoryAdapter.merge(cached: cachedEntry.conversations, incremental: parsed.conversations)
                    warning = parsed.warning
                } else {
                    let history = try client.readHistory()
                    let parsed = ClaudeHistoryAdapter.parse(text: history, server: server)
                    conversations = parsed.conversations
                    warning = parsed.warning
                }

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
        activeSessions = result.sessions
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
            lastError = result.warning
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
                try await Task.detached(priority: .userInitiated) {
                    try SSHClient(server: server).ensureSession(for: conversation)
                }.value
                try ghostty.openAttachTab(server: server, tmuxName: conversation.tmuxName, title: conversation.title)
                selectedConversationID = conversation.id
                statusMessage = "已在 Ghostty 中打开：\(conversation.title)"
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
            let title = conversations.first(where: { $0.tmuxName == session.name })?.title ?? session.name
            try ghostty.openAttachTab(server: server, tmuxName: session.name, title: title)
            statusMessage = "已重新连接 \(session.name)"
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
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { state.attach(session) }
                            .contextMenu {
                                Button("进入") { state.attach(session) }
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
        state.activeSessions.contains { $0.name == conversation.tmuxName }
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
