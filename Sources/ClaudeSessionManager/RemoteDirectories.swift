import Foundation

struct RemoteDirectoryEntry: Identifiable, Equatable {
    let name: String
    let path: String

    var id: String { path }
    var isHidden: Bool { name.hasPrefix(".") }
}

struct RemoteDirectoryListing: Equatable {
    let path: String
    let homePath: String
    let directories: [RemoteDirectoryEntry]
}

enum RemoteDirectoryReader {
    private static let responseMarker = "CCSM_DIRECTORY_V1\0"

    static func command(for path: String) throws -> String {
        guard !path.contains("\0") else {
            throw SSHError.commandFailed("目录路径不能包含空字符")
        }
        let script = """
        unset CDPATH
        cd -- \(ShellQuoting.remotePath(path.isEmpty ? "~" : path)) || exit 1
        if [ ! -r . ] || [ ! -x . ]; then
            printf '没有权限读取此目录\\n' >&2
            exit 1
        fi
        printf '%s\\0' 'CCSM_DIRECTORY_V1'
        pwd -P || exit 1
        printf '\\0%s\\0' "$HOME"
        for entry in ./* ./.[!.]* ./..?*; do
            [ -d "$entry" ] || continue
            printf '%s\\0' "${entry#./}"
        done
        printf '%s\\0' 'CCSM_DIRECTORY_END'
        """
        // NUL separators preserve spaces and shell metacharacters in folder names.
        // Only direct child directories are returned; the rest of the server is never scanned.
        return "/bin/sh -c \(ShellQuoting.singleQuote(script))"
    }

    static func parse(_ output: String) throws -> RemoteDirectoryListing {
        guard let markerRange = output.range(of: responseMarker) else {
            throw SSHError.commandFailed("无法解析服务器返回的目录列表")
        }
        let fields = output[markerRange.upperBound...]
            .split(separator: "\0", omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count >= 3, fields[0].hasSuffix("\n"),
              fields[1].hasPrefix("/") else {
            throw SSHError.commandFailed("服务器返回的目录列表不完整")
        }
        let path = String(fields[0].dropLast())
        guard path.hasPrefix("/") else {
            throw SSHError.commandFailed("服务器没有返回绝对目录路径")
        }
        guard let endIndex = fields.firstIndex(of: "CCSM_DIRECTORY_END"), endIndex >= 2 else {
            throw SSHError.commandFailed("服务器返回的目录列表不完整")
        }
        let names = fields[2..<endIndex]
        guard names.allSatisfy({ !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." }) else {
            throw SSHError.commandFailed("服务器返回了无效的目录名")
        }
        let directories = names.map { name in
            RemoteDirectoryEntry(name: name, path: RemotePath.appending(name, to: path))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return RemoteDirectoryListing(path: path, homePath: fields[1], directories: directories)
    }
}

enum RemotePath {
    static func appending(_ name: String, to path: String) -> String {
        (path == "/" ? "/" : path + "/") + name
    }

    static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func name(of path: String) -> String {
        path == "/" ? "/" : (path as NSString).lastPathComponent
    }
}

extension SSHClient {
    func listDirectories(at path: String) throws -> RemoteDirectoryListing {
        try RemoteDirectoryReader.parse(execute(RemoteDirectoryReader.command(for: path)))
    }
}
