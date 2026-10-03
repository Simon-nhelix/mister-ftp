import Foundation
import Security
import FTPKit

/// A folder the user pinned to the sidebar.
struct Favorite: Codable, Hashable, Identifiable {
    var path: String
    /// Set only when the user typed their own name for the row; otherwise the path makes the name.
    var customTitle: String?

    var id: String { path }
}

/// Connection and display preferences.
/// The password lives in the Keychain, and only when it is not the MiSTer default.
@MainActor @Observable
final class AppSettings {
    static let defaultUser = "root"
    static let defaultPassword = "1"

    private let defaults = UserDefaults.standard

    /// Empty means "find the MiSTer automatically".
    var fixedHost: String { didSet { defaults.set(fixedHost, forKey: "fixedHost") } }
    var port: Int { didSet { defaults.set(port, forKey: "port") } }
    var username: String { didSet { defaults.set(username, forKey: "username") } }
    var lastHost: String? { didSet { defaults.set(lastHost, forKey: "lastHost") } }
    var showHidden: Bool { didSet { defaults.set(showHidden, forKey: "showHidden") } }
    var downloadFolder: URL { didSet { defaults.set(downloadFolder.path, forKey: "downloadFolder") } }
    private(set) var password: String
    /// Pinned folders, in the order the user put them in.
    private(set) var favorites: [Favorite] = []

    init() {
        fixedHost = defaults.string(forKey: "fixedHost") ?? ""
        let savedPort = defaults.integer(forKey: "port")
        port = (1...65535).contains(savedPort) ? savedPort : 21
        username = defaults.string(forKey: "username").flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultUser
        lastHost = defaults.string(forKey: "lastHost")
        showHidden = defaults.bool(forKey: "showHidden")
        if let path = defaults.string(forKey: "downloadFolder") {
            downloadFolder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            downloadFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        }
        password = Keychain.read() ?? Self.defaultPassword
        favorites = Self.readFavorites(from: defaults)
    }

    func setPassword(_ value: String) {
        password = value
        if value == Self.defaultPassword {
            Keychain.delete()
        } else {
            Keychain.save(value)
        }
    }

    func credentials(host: String) -> FTPCredentials {
        FTPCredentials(host: host, port: UInt16(port), username: username, password: password)
    }

    // MARK: Favorites

    func isFavorite(_ path: String) -> Bool {
        favorites.contains { $0.path == RemotePath.normalize(path) }
    }

    func addFavorite(path rawPath: String) {
        let path = RemotePath.normalize(rawPath)
        guard !favorites.contains(where: { $0.path == path }) else { return }
        favorites.append(Favorite(path: path, customTitle: nil))
        storeFavorites()
    }

    func removeFavorite(path rawPath: String) {
        let path = RemotePath.normalize(rawPath)
        guard favorites.contains(where: { $0.path == path }) else { return }
        favorites.removeAll { $0.path == path }
        storeFavorites()
    }

    /// An empty or blank name goes back to the name made from the path.
    func setFavoriteTitle(_ title: String?, path rawPath: String) {
        let path = RemotePath.normalize(rawPath)
        guard let index = favorites.firstIndex(where: { $0.path == path }) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespaces) ?? ""
        favorites[index].customTitle = trimmed.isEmpty ? nil : trimmed
        storeFavorites()
    }

    /// Moves a favorite one row up (-1) or down (+1).
    func moveFavorite(path rawPath: String, by offset: Int) {
        let path = RemotePath.normalize(rawPath)
        guard let index = favorites.firstIndex(where: { $0.path == path }) else { return }
        let target = index + offset
        guard favorites.indices.contains(target) else { return }
        favorites.swapAt(index, target)
        storeFavorites()
    }

    /// Follows a renamed folder, so a pinned row keeps working.
    func relocateFavorites(from oldPath: String, to newPath: String) {
        let old = RemotePath.normalize(oldPath)
        let new = RemotePath.normalize(newPath)
        guard old != new else { return }
        var moved = false
        for index in favorites.indices where favorites[index].path == old || favorites[index].path.hasPrefix(old + "/") {
            favorites[index].path = new + String(favorites[index].path.dropFirst(old.count))
            moved = true
        }
        if moved { storeFavorites() }
    }

    /// Drops rows that point at a deleted folder or anything inside it.
    func dropFavorites(under rawPath: String) {
        let path = RemotePath.normalize(rawPath)
        let before = favorites.count
        favorites.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
        if favorites.count != before { storeFavorites() }
    }

    private func storeFavorites() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        defaults.set(data, forKey: "favorites")
    }

    private static func readFavorites(from defaults: UserDefaults) -> [Favorite] {
        guard let data = defaults.data(forKey: "favorites"),
              let saved = try? JSONDecoder().decode([Favorite].self, from: data) else { return [] }
        // Old files could hold the same path twice; the sidebar needs unique ids.
        var seen = Set<String>()
        return saved.filter { seen.insert($0.path).inserted }
    }

    /// Addresses to try before scanning the network.
    var preferredHosts: [String] {
        [fixedHost.trimmingCharacters(in: .whitespaces), lastHost ?? ""].filter { !$0.isEmpty }
    }
}

private enum Keychain {
    static let service = "io.github.simon-nhelix.misterftp"
    static let account = "mister"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) {
        delete()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "MiSTer FTP",
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
