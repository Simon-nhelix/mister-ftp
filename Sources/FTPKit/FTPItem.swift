import Foundation

public struct FTPItem: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable, Hashable {
        case directory
        case file
        case link
    }

    public var id: String { path }
    public let name: String
    /// Absolute path on the server, for example "/media/fat/games/SNES".
    public let path: String
    public let kind: Kind
    public let size: Int64?
    public let modified: Date?

    public init(name: String, path: String, kind: Kind, size: Int64?, modified: Date?) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
    }

    public var isDirectory: Bool { kind == .directory }
    public var isHidden: Bool { name.hasPrefix(".") }
}

/// Helpers for absolute POSIX-style server paths.
public enum RemotePath {
    public static func join(_ directory: String, _ name: String) -> String {
        if directory.isEmpty || directory == "/" { return "/" + name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    public static func parent(of path: String) -> String {
        let trimmed = normalize(path)
        guard trimmed != "/", let slash = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    public static func lastComponent(_ path: String) -> String {
        let trimmed = normalize(path)
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    public static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Path components after the root, for breadcrumbs.
    public static func components(_ path: String) -> [String] {
        normalize(path).split(separator: "/").map(String.init)
    }
}
