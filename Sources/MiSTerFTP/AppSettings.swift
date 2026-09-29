import Foundation
import Security
import FTPKit

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
