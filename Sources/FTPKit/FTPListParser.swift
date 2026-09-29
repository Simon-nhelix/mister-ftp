import Foundation

/// Parses directory listings: MLSD (RFC 3659) first, Unix `LIST` output as a fallback.
public enum FTPListParser {
    public static func parseMLSD(_ text: String, directory: String) -> [FTPItem] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            parseMLSDLine(String(line), directory: directory)
        }
    }

    /// One MLSD/MLST fact line: `type=file;size=1024;modify=20260716173454; name`.
    public static func parseMLSDLine(_ line: String, directory: String) -> FTPItem? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let name = String(line[line.index(after: space)...])
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        var facts: [String: String] = [:]
        for fact in line[..<space].split(separator: ";") {
            let pair = fact.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { facts[pair[0].lowercased()] = String(pair[1]) }
        }

        let type = facts["type"]?.lowercased() ?? "file"
        if type == "cdir" || type == "pdir" { return nil }
        let kind: FTPItem.Kind
        if type == "dir" {
            kind = .directory
        } else if type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink") {
            kind = .link
        } else {
            kind = .file
        }

        // MLST answers with a full path; MLSD answers with a bare name.
        let displayName = name.contains("/") ? RemotePath.lastComponent(name) : name
        let path = name.hasPrefix("/") ? RemotePath.normalize(name) : RemotePath.join(directory, name)
        return FTPItem(
            name: displayName,
            path: path,
            kind: kind,
            size: kind == .file ? facts["size"].flatMap { Int64($0) } : nil,
            modified: facts["modify"].flatMap(parseMLSDTime)
        )
    }

    /// `YYYYMMDDHHMMSS[.sss]`, always UTC.
    public static func parseMLSDTime(_ value: String) -> Date? {
        let digits = value.prefix(14)
        guard digits.count == 14, digits.allSatisfy(\.isNumber) else { return nil }
        func number(_ from: Int, _ length: Int) -> Int {
            let start = digits.index(digits.startIndex, offsetBy: from)
            return Int(digits[start..<digits.index(start, offsetBy: length)]) ?? 0
        }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = number(0, 4)
        components.month = number(4, 2)
        components.day = number(6, 2)
        components.hour = number(8, 2)
        components.minute = number(10, 2)
        components.second = number(12, 2)
        return components.date
    }

    // MARK: LIST fallback

    public static func parseLIST(_ text: String, directory: String, now: Date = Date()) -> [FTPItem] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            parseLISTLine(String(line), directory: directory, now: now)
        }
    }

    /// Parses `drwxr-xr-x 2 root root 4096 Jul 16 17:34 name` style lines.
    static func parseLISTLine(_ line: String, directory: String, now: Date) -> FTPItem? {
        guard let first = line.first, "-dlbcps".contains(first) else { return nil }
        // Walk the first 8 whitespace-separated fields; the name is the rest of the line.
        var fields: [Substring] = []
        var index = line.startIndex
        while fields.count < 8 {
            while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
            guard index < line.endIndex else { return nil }
            let start = index
            while index < line.endIndex, line[index] != " " { index = line.index(after: index) }
            fields.append(line[start..<index])
        }
        guard index < line.endIndex else { return nil }
        var name = String(line[line.index(after: index)...])

        let kind: FTPItem.Kind
        switch first {
        case "d": kind = .directory
        case "l":
            kind = .link
            if let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        default: kind = .file
        }
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        return FTPItem(
            name: name,
            path: RemotePath.join(directory, name),
            kind: kind,
            size: kind == .file ? Int64(fields[4]) : nil,
            modified: parseLISTDate(month: fields[5], day: fields[6], timeOrYear: fields[7], now: now)
        )
    }

    static func parseLISTDate(month: Substring, day: Substring, timeOrYear: Substring, now: Date) -> Date? {
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let monthIndex = months.firstIndex(of: month.lowercased()), let dayValue = Int(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.month = monthIndex + 1
        components.day = dayValue
        if timeOrYear.contains(":") {
            let parts = timeOrYear.split(separator: ":")
            components.hour = Int(parts[0])
            components.minute = parts.count > 1 ? Int(parts[1]) : 0
            let year = calendar.component(.year, from: now)
            components.year = year
            // "Jul 16 17:34" means the last 12 months; a date in the future belongs to last year.
            if let date = calendar.date(from: components), date > now.addingTimeInterval(86_400) {
                components.year = year - 1
            }
        } else {
            components.year = Int(timeOrYear)
        }
        return calendar.date(from: components)
    }
}
