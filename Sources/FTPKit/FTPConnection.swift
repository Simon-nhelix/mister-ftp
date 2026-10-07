import Foundation
import Darwin

public struct FTPCredentials: Sendable, Hashable {
    public var host: String
    public var port: UInt16
    public var username: String
    public var password: String

    public init(host: String, port: UInt16 = 21, username: String = "root", password: String = "1") {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

public struct FTPResponse: Sendable, CustomStringConvertible {
    public let code: Int
    public let lines: [String]

    /// Text of the reply without the numeric code.
    public var message: String {
        lines.map { line -> String in
            if line.count >= 4, Int(line.prefix(3)) == code { return String(line.dropFirst(4)) }
            return line.trimmingCharacters(in: .whitespaces)
        }
        .joined(separator: "\n")
    }

    public var isPreliminary: Bool { (100..<200).contains(code) }
    public var isCompletion: Bool { (200..<300).contains(code) }
    public var isIntermediate: Bool { (300..<400).contains(code) }
    public var description: String { lines.joined(separator: "\n") }
}

/// One FTP control connection (RFC 959 + RFC 3659), passive mode only.
///
/// The object is not thread-safe: use it from one thread at a time.
/// `abort()` is the only exception; call it from any thread to stop a running
/// command. After `abort()` the connection is dead and must be thrown away.
public final class FTPConnection: @unchecked Sendable {
    public let credentials: FTPCredentials
    public private(set) var greeting = ""
    public private(set) var features: Set<String> = []
    public private(set) var isLoggedIn = false
    /// Numeric address of the server, used for data connections.
    public var serverAddress: String { control.remoteAddress }

    public var dataTimeout: TimeInterval = 30

    private let control: TCPSocket
    private var buffer: [UInt8] = []
    private var bufferStart = 0
    private var epsvUnsupported = false
    private var mlsdUnsupported = false
    private var broken = false

    private let stateLock = NSLock()
    private var activeData: TCPSocket?
    private var abortRequested = false

    /// Opens the control connection and reads the server greeting.
    public init(credentials: FTPCredentials, connectTimeout: TimeInterval = 5, replyTimeout: TimeInterval = 15) throws {
        self.credentials = credentials
        control = try TCPSocket.connect(host: credentials.host, port: credentials.port, timeout: connectTimeout, noDelay: true)
        control.setTimeouts(read: replyTimeout, write: replyTimeout)
        let hello = try readResponse()
        guard hello.code == 220 else {
            control.close()
            throw FTPError.server(code: hello.code, message: hello.message)
        }
        greeting = hello.message
    }

    deinit {
        activeData?.close()
        control.close()
    }

    public var isUsable: Bool { !broken && !isAborted }

    // MARK: Session

    public func login() throws {
        try guarded {
            var reply = try command("USER \(credentials.username)")
            if reply.code == 331 || reply.code == 332 {
                reply = try command("PASS \(credentials.password)")
            }
            guard reply.code == 230 || reply.code == 202 else {
                throw FTPError.loginFailed(reply.message)
            }
            isLoggedIn = true

            if let feat = try? command("FEAT"), feat.code == 211 {
                features = Set(feat.lines.dropFirst().dropLast().map {
                    $0.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map { String($0).uppercased() } ?? ""
                })
            }
            if features.contains("UTF8") {
                _ = try? command("OPTS UTF8 ON")
            }
            let type = try command("TYPE I")
            guard type.isCompletion else { throw FTPError.server(code: type.code, message: type.message) }
        }
    }

    public func noop() throws {
        try guarded {
            let reply = try command("NOOP")
            guard reply.isCompletion else { throw FTPError.server(code: reply.code, message: reply.message) }
        }
    }

    /// Says goodbye politely and closes the socket. Never throws.
    public func quit() {
        if !broken && !isAborted {
            control.setTimeouts(read: 1, write: 1)
            _ = try? command("QUIT")
        }
        close()
    }

    public func close() {
        broken = true
        takeActiveData()?.close()
        control.close()
    }

    /// Stops the running command from another thread.
    public func abort() {
        stateLock.lock()
        abortRequested = true
        let data = activeData
        stateLock.unlock()
        data?.shutdown()
        control.shutdown()
    }

    public var isAborted: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return abortRequested
    }

    // MARK: File system

    public func list(_ path: String) throws -> [FTPItem] {
        try guarded {
            if !mlsdUnsupported {
                do {
                    let text = try retrieveText("MLSD \(try checked(path))")
                    return FTPListParser.parseMLSD(text, directory: path)
                } catch FTPError.server(let code, _) where code == 500 || code == 502 || code == 504 {
                    mlsdUnsupported = true
                }
            }
            let text = try retrieveText("LIST -a \(try checked(path))")
            return FTPListParser.parseLIST(text, directory: path)
        }
    }

    /// Facts about one path, or nil when it does not exist.
    public func stat(_ path: String) throws -> FTPItem? {
        try guarded {
            let reply = try command("MLST \(try checked(path))")
            if reply.code == 550 { return nil }
            guard reply.code == 250 else { throw FTPError.server(code: reply.code, message: reply.message) }
            for line in reply.lines.dropFirst() where line.hasPrefix(" ") {
                if let item = FTPListParser.parseMLSDLine(String(line.dropFirst()), directory: RemotePath.parent(of: path)) {
                    return FTPItem(name: RemotePath.lastComponent(path), path: path, kind: item.kind, size: item.size, modified: item.modified)
                }
            }
            return nil
        }
    }

    public func makeDirectory(_ path: String) throws {
        try guarded {
            let reply = try command("MKD \(try checked(path))")
            guard reply.isCompletion else { throw FTPError.server(code: reply.code, message: reply.message) }
        }
    }

    /// Creates the directory unless a directory with that path already exists.
    public func ensureDirectory(_ path: String) throws {
        if let existing = try stat(path) {
            if existing.isDirectory || existing.kind == .link { return }
            throw FTPError.server(code: 553, message: String(localized: "같은 이름의 파일이 있어요: \(RemotePath.lastComponent(path))"))
        }
        try makeDirectory(path)
    }

    public func deleteFile(_ path: String) throws {
        try guarded {
            let reply = try command("DELE \(try checked(path))")
            guard reply.isCompletion else { throw FTPError.server(code: reply.code, message: reply.message) }
        }
    }

    public func removeDirectory(_ path: String) throws {
        try guarded {
            let reply = try command("RMD \(try checked(path))")
            guard reply.isCompletion else { throw FTPError.server(code: reply.code, message: reply.message) }
        }
    }

    /// Deletes a file, or a directory with everything inside it.
    public func deleteRecursively(_ item: FTPItem, progress: ((String) -> Void)? = nil) throws {
        if item.isDirectory {
            for child in try list(item.path) {
                try deleteRecursively(child, progress: progress)
            }
            progress?(item.path)
            try removeDirectory(item.path)
        } else {
            progress?(item.path)
            try deleteFile(item.path)
        }
    }

    public func rename(_ from: String, to: String) throws {
        try guarded {
            let first = try command("RNFR \(try checked(from))")
            guard first.code == 350 else { throw FTPError.server(code: first.code, message: first.message) }
            let second = try command("RNTO \(try checked(to))")
            guard second.isCompletion else { throw FTPError.server(code: second.code, message: second.message) }
        }
    }

    // MARK: Transfers

    /// Downloads `remotePath` into a new file at `localURL`.
    /// `progress` receives the number of bytes written so far.
    public func download(_ remotePath: String, to localURL: URL, progress: (Int64) -> Void) throws {
        try guarded {
            guard FileManager.default.createFile(atPath: localURL.path, contents: nil) else {
                throw FTPError.localFile(String(localized: "Mac에 파일을 만들 수 없어요: \(localURL.lastPathComponent)"))
            }
            let fd = Darwin.open(localURL.path, O_WRONLY | O_TRUNC)
            guard fd >= 0 else { throw FTPError.localFile(String(localized: "Mac에 파일을 쓸 수 없어요: \(localURL.lastPathComponent)")) }
            defer { Darwin.close(fd) }

            let data = try beginTransfer("RETR \(try checked(remotePath))")
            defer { finishData(data) }
            var total: Int64 = 0
            let chunk = 256 * 1024
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
            defer { buffer.deallocate() }
            while true {
                let n = try data.receive(into: buffer, count: chunk)
                if n == 0 { break }
                var written = 0
                while written < n {
                    let w = Darwin.write(fd, buffer + written, n - written)
                    if w < 0 {
                        if errno == EINTR { continue }
                        throw FTPError.localFile(String(localized: "Mac 디스크에 쓰지 못했어요: \(String(cString: strerror(errno)))"))
                    }
                    written += w
                }
                total += Int64(n)
                progress(total)
            }
            finishData(data)
            try finishTransfer()
        }
    }

    /// Uploads the file at `localURL` to `remotePath`, replacing any file with that name.
    public func upload(_ localURL: URL, to remotePath: String, progress: (Int64) -> Void) throws {
        try guarded {
            let fd = Darwin.open(localURL.path, O_RDONLY)
            guard fd >= 0 else { throw FTPError.localFile(String(localized: "파일을 읽을 수 없어요: \(localURL.lastPathComponent)")) }
            defer { Darwin.close(fd) }

            let data = try beginTransfer("STOR \(try checked(remotePath))")
            defer { finishData(data) }
            var total: Int64 = 0
            let chunk = 1024 * 1024
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
            defer { buffer.deallocate() }
            while true {
                let n = Darwin.read(fd, buffer, chunk)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw FTPError.localFile(String(localized: "파일을 읽지 못했어요: \(localURL.lastPathComponent)"))
                }
                if n == 0 { break }
                try data.sendAll(buffer, count: n)
                total += Int64(n)
                progress(total)
            }
            // Closing the data connection tells the server the file is complete.
            finishData(data)
            try finishTransfer()
        }
    }

    // MARK: Protocol plumbing

    @discardableResult
    public func command(_ line: String) throws -> FTPResponse {
        try send(line)
        let reply = try readResponse()
        if reply.code == 421 {
            broken = true
            throw FTPError.server(code: 421, message: reply.message)
        }
        return reply
    }

    private func send(_ line: String) throws {
        do {
            try control.sendAll(Array((line + "\r\n").utf8))
        } catch {
            broken = true
            throw error
        }
    }

    public func readResponse() throws -> FTPResponse {
        let first = try readLine()
        guard first.count >= 3, let code = Int(first.prefix(3)) else {
            broken = true
            throw FTPError.protocolError(first)
        }
        var lines = [first]
        if first.count > 3, first[first.index(first.startIndex, offsetBy: 3)] == "-" {
            let end = "\(code) "
            while true {
                let line = try readLine()
                lines.append(line)
                if line.hasPrefix(end) || line == String(code) { break }
            }
        }
        return FTPResponse(code: code, lines: lines)
    }

    private func readLine() throws -> String {
        while true {
            if let newline = buffer[bufferStart...].firstIndex(of: 0x0A) {
                var end = newline
                if end > bufferStart && buffer[end - 1] == 0x0D { end -= 1 }
                let line = Self.decode(buffer[bufferStart..<end])
                bufferStart = newline + 1
                if bufferStart > 8192 {
                    buffer.removeFirst(bufferStart)
                    bufferStart = 0
                }
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n: Int
            do {
                n = try chunk.withUnsafeMutableBytes { try control.receive(into: $0.baseAddress!, count: $0.count) }
            } catch {
                broken = true
                throw error
            }
            if n == 0 {
                broken = true
                throw FTPError.connectionClosed
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    static func decode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        let data = Data(bytes)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// Opens a passive data connection. EPSV first, PASV when EPSV is not supported.
    private func openData() throws -> TCPSocket {
        var port: UInt16?
        if !epsvUnsupported {
            let reply = try command("EPSV")
            if reply.code == 229 {
                port = Self.parseEPSV(reply.message)
            } else if reply.code >= 500 {
                epsvUnsupported = true
            } else {
                throw FTPError.server(code: reply.code, message: reply.message)
            }
        }
        if port == nil {
            let reply = try command("PASV")
            guard reply.code == 227 else { throw FTPError.server(code: reply.code, message: reply.message) }
            port = Self.parsePASV(reply.message)
        }
        guard let dataPort = port else { throw FTPError.protocolError("passive port") }
        // Always use the control address: the address inside a PASV reply can be wrong behind NAT.
        let socket = try TCPSocket.connect(host: serverAddress, port: dataPort, timeout: 10)
        socket.setTimeouts(read: dataTimeout, write: dataTimeout)
        stateLock.lock()
        activeData = socket
        let aborted = abortRequested
        stateLock.unlock()
        if aborted { throw FTPError.cancelled }
        return socket
    }

    private func beginTransfer(_ line: String) throws -> TCPSocket {
        let data = try openData()
        do {
            let reply = try command(line)
            guard reply.code == 150 || reply.code == 125 else {
                throw FTPError.server(code: reply.code, message: reply.message)
            }
            return data
        } catch {
            finishData(data)
            throw error
        }
    }

    private func finishData(_ socket: TCPSocket) {
        socket.close()
        stateLock.lock()
        if activeData === socket { activeData = nil }
        stateLock.unlock()
    }

    private func takeActiveData() -> TCPSocket? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let data = activeData
        activeData = nil
        return data
    }

    private func finishTransfer() throws {
        let reply = try readResponse()
        guard reply.isCompletion else { throw FTPError.server(code: reply.code, message: reply.message) }
    }

    private func retrieveText(_ line: String) throws -> String {
        let data = try beginTransfer(line)
        defer { finishData(data) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = try chunk.withUnsafeMutableBytes { try data.receive(into: $0.baseAddress!, count: $0.count) }
            if n == 0 { break }
            bytes.append(contentsOf: chunk[0..<n])
        }
        finishData(data)
        try finishTransfer()
        return Self.decode(bytes)
    }

    /// Rejects names that would break the command line (CR/LF injection).
    private func checked(_ path: String) throws -> String {
        if path.contains("\r") || path.contains("\n") || path.contains("\0") {
            throw FTPError.invalidName(RemotePath.lastComponent(path))
        }
        return path
    }

    /// Runs `body` and turns errors caused by `abort()` into `.cancelled`.
    private func guarded<T>(_ body: () throws -> T) throws -> T {
        if isAborted { throw FTPError.cancelled }
        do {
            return try body()
        } catch {
            if isAborted { broken = true; throw FTPError.cancelled }
            if let ftp = error as? FTPError, ftp.isConnectionLost { broken = true }
            throw error
        }
    }

    // MARK: Reply parsing

    /// `Entering Extended Passive Mode (|||10520|)`
    static func parseEPSV(_ text: String) -> UInt16? {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return nil }
        let inside = text[text.index(after: open)..<close]
        guard let delimiter = inside.first else { return nil }
        let fields = inside.split(separator: delimiter, omittingEmptySubsequences: false)
        guard fields.count >= 4 else { return nil }
        return UInt16(fields[3])
    }

    /// `Entering Passive Mode (192,168,1,11,41,24)`
    static func parsePASV(_ text: String) -> UInt16? {
        var numbers: [Int] = []
        var current = ""
        for character in text {
            if character.isNumber {
                current.append(character)
            } else {
                if !current.isEmpty { numbers.append(Int(current) ?? -1); current = "" }
                if numbers.count == 6 { break }
                if character != "," { numbers.removeAll() }
            }
        }
        if !current.isEmpty && numbers.count < 6 { numbers.append(Int(current) ?? -1) }
        guard numbers.count >= 6 else { return nil }
        let p1 = numbers[4], p2 = numbers[5]
        guard (0...255).contains(p1), (0...255).contains(p2) else { return nil }
        return UInt16(p1 * 256 + p2)
    }
}
