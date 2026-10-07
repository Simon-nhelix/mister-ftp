import Foundation

/// A dotted release number such as "1.0.1". A leading "v" (tag names) and any
/// pre-release or build suffix ("-beta.1", "+5") are ignored.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// Numbers without trailing zeros, so "1.0" and "1.0.0" are the same version.
    private let numbers: [Int]
    public let description: String

    public init?(_ text: String) {
        var value = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if value.first == "v" || value.first == "V" { value = value.dropFirst() }
        if let suffix = value.firstIndex(where: { $0 == "-" || $0 == "+" }) { value = value[..<suffix] }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        description = numbers.map(String.init).joined(separator: ".")
        while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
        self.numbers = numbers
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        return lhs.numbers.lexicographicallyPrecedes(rhs.numbers)
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { lhs.numbers == rhs.numbers }
    public func hash(into hasher: inout Hasher) { hasher.combine(numbers) }
}
