import Foundation
import FTPKit

enum Format {
    /// Finder style sizes (1 KB = 1000 bytes).
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// "23.7 / 38.2 MB"
    static func progress(_ done: Int64, of total: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let totalText = formatter.string(fromByteCount: total)
        formatter.includesUnit = false
        return "\(formatter.string(fromByteCount: min(done, total))) / \(totalText)"
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    static func remaining(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        if seconds < 60 { return String(localized: "약 \(max(1, Int(seconds.rounded())))초") }
        if seconds < 3600 { return String(localized: "약 \(Int((seconds / 60).rounded()))분") }
        return String(localized: "약 \(Int(seconds / 3600))시간 \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))분")
    }

    /// The app's text language with the Mac's region, so dates read like the words
    /// around them: "2026. 9. 29. 오후 3:04" in Korean, "9/29/2026, 3:04 PM" in US English.
    /// Locale.current alone keeps the system language even when the app shows another one.
    static let locale: Locale = {
        guard !Bundle.main.localizations.isEmpty, let language = Bundle.main.preferredLocalizations.first else { return .current }
        guard let region = Locale.current.region?.identifier else { return Locale(identifier: language) }
        return Locale(identifier: "\(language)_\(region)")
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("yMdjmm")
        return formatter
    }()

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dateFormatter.string(from: date)
    }
}

/// Friendly names for the MiSTer storage locations.
enum Places {
    static let sdCard = "/media/fat"

    static func displayName(for path: String) -> String {
        let normalized = RemotePath.normalize(path)
        if normalized == sdCard { return String(localized: "SD 카드") }
        if let usb = usbNumber(normalized) { return String(localized: "USB \(usb + 1)") }
        if normalized == "/" { return "/" }
        return RemotePath.lastComponent(normalized)
    }

    static func usbNumber(_ path: String) -> Int? {
        guard path.hasPrefix("/media/usb"), let number = Int(path.dropFirst("/media/usb".count)) else { return nil }
        return number
    }

    /// The storage root a path belongs to ("/media/fat", "/media/usb0" or "/").
    static func root(of path: String) -> String {
        let parts = RemotePath.components(path)
        if parts.count >= 2, parts[0] == "media" { return "/media/" + parts[1] }
        return "/"
    }

    /// "games/SNES" style label, relative to the storage root.
    static func shortLabel(_ path: String) -> String {
        let root = root(of: path)
        let normalized = RemotePath.normalize(path)
        if normalized == root { return displayName(for: root) }
        if root == "/" { return normalized }
        let relative = String(normalized.dropFirst(root.count + 1))
        return root == sdCard ? relative : "\(displayName(for: root))/\(relative)"
    }
}
