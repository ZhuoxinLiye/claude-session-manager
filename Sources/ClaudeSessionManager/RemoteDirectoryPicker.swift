import Foundation
import SwiftUI

@MainActor
final class RemoteDirectoryBrowser: ObservableObject {
    let server: ServerProfile
    @Published var pathInput: String
    @Published var filter = ""
    @Published var showsHiddenDirectories = false
    @Published var selectedDirectory: String?
    @Published private(set) var listing: RemoteDirectoryListing?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published var bookmarkError: String?

    private var requestID = UUID()
    private var pendingTask: Task<Void, Never>?

    init(server: ServerProfile, initialPath: String) {
        self.server = server
        pathInput = initialPath.isEmpty ? "~" : initialPath
    }

    var visibleDirectories: [RemoteDirectoryEntry] {
        (listing?.directories ?? []).filter {
            (showsHiddenDirectories || !$0.isHidden)
                && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter))
        }
    }

    var choice: String? {
        guard !isLoading, error == nil else { return nil }
        if let selectedDirectory {
            return selectedDirectory
        }
        guard let listing, pathInput == listing.path else {
            return nil
        }
        return listing.path
    }

    func goToInput() {
        let path: String
        if pathInput.hasPrefix("/") || pathInput == "~" || pathInput.hasPrefix("~/") {
            path = pathInput
        } else if pathInput.isEmpty {
            path = "~"
        } else {
            path = RemotePath.appending(pathInput, to: listing?.path ?? "~")
        }
        navigate(to: path)
    }

    func openSelectedDirectory() {
        guard let selectedDirectory, !isLoading else { return }
        navigate(to: selectedDirectory)
    }

    func navigate(to path: String, afterLoading: ((String) -> Void)? = nil) {
        pendingTask?.cancel()
        let id = UUID()
        requestID = id
        pathInput = path
        selectedDirectory = nil
        filter = ""
        error = nil
        isLoading = true
        pendingTask = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { [server] in
                    try SSHClient(server: server).listDirectories(at: path)
                }.value
                guard !Task.isCancelled, requestID == id else { return }
                listing = result
                pathInput = result.path
                isLoading = false
                afterLoading?(result.path)
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }

    func confirm(_ completion: @escaping (String) -> Void) {
        guard let choice else { return }
        if choice == listing?.path {
            completion(choice)
        } else {
            // Resolve the selected child and verify it is still accessible before returning it.
            navigate(to: choice, afterLoading: completion)
        }
    }

    func cancel() {
        requestID = UUID()
        pendingTask?.cancel()
        pendingTask = nil
    }
}

struct RemoteDirectoryPicker: View {
    let server: ServerProfile
    let onSelect: (String) -> Void
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser: RemoteDirectoryBrowser

    init(server: ServerProfile, initialPath: String, onSelect: @escaping (String) -> Void) {
        self.server = server
        self.onSelect = onSelect
        _browser = StateObject(wrappedValue: RemoteDirectoryBrowser(server: server, initialPath: initialPath))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                bookmarks
                    .frame(width: 210)
                Divider()
                directoryContents
            }
            Divider()
            footer
        }
        .frame(width: 790, height: 540)
        .task { browser.navigate(to: browser.pathInput) }
        .onDisappear { browser.cancel() }
        .onChange(of: browser.showsHiddenDirectories) { _, _ in
            browser.selectedDirectory = nil
        }
        .onChange(of: browser.filter) { _, _ in
            browser.selectedDirectory = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("选择远程目录")
                    .font(.title3.weight(.semibold))
                Spacer()
                Label(server.name, systemImage: "server.rack")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button {
                    if let path = browser.listing?.path {
                        browser.navigate(to: RemotePath.parent(of: path))
                    }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .help("上级目录（⌘↑）")
                .keyboardShortcut(.upArrow, modifiers: [.command])
                .disabled(browser.listing == nil || browser.listing?.path == "/" || browser.isLoading)

                TextField("输入远程路径，回车进入", text: $browser.pathInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit { browser.goToInput() }
                Button("前往") { browser.goToInput() }
                Button {
                    if let path = browser.listing?.path {
                        browser.navigate(to: path)
                    } else {
                        browser.goToInput()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新目录")
                .disabled(browser.isLoading)
            }
        }
        .padding(18)
    }

    private var bookmarks: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                browser.navigate(to: browser.listing?.homePath ?? "~")
            } label: {
                Label("主目录", systemImage: "house")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.top, 8)

            Text("收藏")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if state.bookmarkedDirectories(for: server).isEmpty {
                        Text("进入目录后，点击星标收藏。\n收藏只属于当前服务器。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    ForEach(state.bookmarkedDirectories(for: server), id: \.self) { path in
                        Button {
                            browser.navigate(to: path)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(RemotePath.name(of: path))
                                        .lineLimit(1)
                                    Text(path)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(path)
                        .contextMenu {
                            Button("取消收藏") { toggleBookmark(path) }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .background(.quaternary.opacity(0.3))
    }

    private var directoryContents: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("筛选当前目录", text: $browser.filter)
                    .textFieldStyle(.roundedBorder)
                Toggle("显示隐藏目录", isOn: $browser.showsHiddenDirectories)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            .padding(12)
            if browser.isLoading {
                Spacer()
                ProgressView("正在读取目录…")
                Spacer()
            } else if let error = browser.error {
                ContentUnavailableView {
                    Label("无法打开目录", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { browser.goToInput() }
                }
            } else if browser.visibleDirectories.isEmpty {
                ContentUnavailableView(
                    browser.filter.isEmpty ? "没有子目录" : "没有匹配的目录",
                    systemImage: "folder",
                    description: Text(browser.filter.isEmpty ? "可直接选择当前目录。" : "尝试其他关键词。")
                )
            } else {
                List(selection: $browser.selectedDirectory) {
                    ForEach(browser.visibleDirectories) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                            Text(entry.name)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .tag(entry.path)
                        .onTapGesture(count: 2) { browser.navigate(to: entry.path) }
                        .contextMenu {
                            Button("进入目录") { browser.navigate(to: entry.path) }
                            Button("使用此目录") {
                                browser.navigate(to: entry.path, afterLoading: selectDirectory)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .onKeyPress(.return) {
                    browser.openSelectedDirectory()
                    return .handled
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let bookmarkError = browser.bookmarkError {
                Text(bookmarkError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Button {
                    if let path = browser.listing?.path { toggleBookmark(path) }
                } label: {
                    Image(systemName: isCurrentDirectoryBookmarked ? "star.fill" : "star")
                        .foregroundStyle(isCurrentDirectoryBookmarked ? .yellow : .secondary)
                }
                .help(isCurrentDirectoryBookmarked ? "取消收藏当前目录" : "收藏当前目录")
                .disabled(browser.listing == nil || browser.isLoading || browser.error != nil)
                VStack(alignment: .leading, spacing: 3) {
                    Text("选择：\(browser.choice ?? browser.pathInput)")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(browser.choice ?? browser.pathInput)
                    Text("双击或回车进入目录；⌘↑ 返回上级")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("使用此目录") { browser.confirm(selectDirectory) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .disabled(browser.choice == nil)
            }
        }
        .padding(16)
    }

    private var isCurrentDirectoryBookmarked: Bool {
        guard let path = browser.listing?.path else { return false }
        return state.bookmarkedDirectories(for: server).contains(path)
    }

    private func toggleBookmark(_ path: String) {
        do {
            try state.toggleDirectoryBookmark(path, for: server)
            browser.bookmarkError = nil
        } catch {
            browser.bookmarkError = "无法保存收藏：\(error.localizedDescription)"
        }
    }

    private func selectDirectory(_ path: String) {
        onSelect(path)
        dismiss()
    }
}
