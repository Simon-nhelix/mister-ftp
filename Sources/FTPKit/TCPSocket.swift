import Foundation
import Darwin

/// A small blocking TCP socket with timeouts.
///
/// Every method except `shutdown()` and `close()` must be called from one thread
/// at a time. `shutdown()` may be called from any thread to wake up a blocked
/// `receive` or `send` (this is how transfers are cancelled).
public final class TCPSocket: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    /// Numeric address of the peer, for example "192.168.1.11".
    public let remoteAddress: String

    private init(fd: Int32, remoteAddress: String) {
        self.fd = fd
        self.remoteAddress = remoteAddress
    }

    deinit { close() }

    // MARK: Connect

    public static func connect(host: String, port: UInt16, timeout: TimeInterval, noDelay: Bool = false) throws -> TCPSocket {
        let addresses = try resolve(host: host, port: port)
        var lastError: FTPError = .connectFailed(host: host, code: EHOSTUNREACH)
        for address in addresses {
            do {
                return try connect(to: address, timeout: timeout, noDelay: noDelay)
            } catch let error as FTPError {
                lastError = error
            }
        }
        if case .connectFailed(_, let code) = lastError {
            throw FTPError.connectFailed(host: host, code: code)
        }
        throw lastError
    }

    struct ResolvedAddress {
        let family: Int32
        let storage: Data
        let numeric: String
    }

    static func resolve(host: String, port: UInt16, family: Int32 = AF_UNSPEC) throws -> [ResolvedAddress] {
        var hints = addrinfo()
        hints.ai_family = family
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        hints.ai_flags = AI_NUMERICSERV
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else {
            throw FTPError.hostNotFound(host)
        }
        defer { freeaddrinfo(first) }

        var list: [ResolvedAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if let sa = info.pointee.ai_addr {
                let data = Data(bytes: sa, count: Int(info.pointee.ai_addrlen))
                list.append(ResolvedAddress(family: info.pointee.ai_family, storage: data, numeric: numericHost(sa, Int(info.pointee.ai_addrlen))))
            }
            cursor = info.pointee.ai_next
        }
        // Prefer IPv4: MiSTer.local also answers with link-local IPv6 addresses,
        // which need a scope and are slower to reach.
        list.sort { ($0.family == AF_INET ? 0 : 1) < ($1.family == AF_INET ? 0 : 1) }
        guard !list.isEmpty else { throw FTPError.hostNotFound(host) }
        return list
    }

    static func numericHost(_ sa: UnsafePointer<sockaddr>, _ length: Int) -> String {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(sa, socklen_t(length), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
            return String(cString: buffer)
        }
        return "?"
    }

    private static func connect(to address: ResolvedAddress, timeout: TimeInterval, noDelay: Bool) throws -> TCPSocket {
        let fd = Darwin.socket(address.family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw FTPError.connectFailed(host: address.numeric, code: errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        if noDelay {
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let rc = address.storage.withUnsafeBytes { raw -> Int32 in
            let sa = raw.baseAddress!.assumingMemoryBound(to: sockaddr.self)
            return Darwin.connect(fd, sa, socklen_t(raw.count))
        }
        if rc != 0 {
            let code = errno
            guard code == EINPROGRESS else {
                Darwin.close(fd)
                throw FTPError.connectFailed(host: address.numeric, code: code)
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    Darwin.close(fd)
                    throw FTPError.timeout
                }
                let ready = poll(&pfd, 1, Int32(max(1, remaining * 1000)))
                if ready > 0 { break }
                if ready < 0 && errno != EINTR {
                    let code = errno
                    Darwin.close(fd)
                    throw FTPError.connectFailed(host: address.numeric, code: code)
                }
            }
            var soError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
            if soError != 0 {
                Darwin.close(fd)
                throw FTPError.connectFailed(host: address.numeric, code: soError)
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return TCPSocket(fd: fd, remoteAddress: address.numeric)
    }

    // MARK: I/O

    public func setTimeouts(read: TimeInterval, write: TimeInterval) {
        var readTime = Self.timeval(read)
        var writeTime = Self.timeval(write)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTime, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &writeTime, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func timeval(_ seconds: TimeInterval) -> Darwin.timeval {
        let whole = Int(seconds)
        return Darwin.timeval(tv_sec: whole, tv_usec: Int32((seconds - Double(whole)) * 1_000_000))
    }

    /// Reads up to `count` bytes into `buffer`. Returns 0 at end of stream.
    public func receive(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        while true {
            let n = Darwin.recv(fd, buffer, count, 0)
            if n >= 0 { return n }
            switch errno {
            case EINTR: continue
            case EAGAIN: throw FTPError.timeout
            default: throw FTPError.connectionClosed
            }
        }
    }

    public func sendAll(_ buffer: UnsafeRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let n = Darwin.send(fd, buffer + offset, count - offset, 0)
            if n > 0 {
                offset += n
                continue
            }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && errno == EAGAIN { throw FTPError.timeout }
            throw FTPError.connectionClosed
        }
    }

    public func sendAll(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { raw in
            try sendAll(raw.baseAddress!, count: raw.count)
        }
    }

    /// Wakes up any thread blocked on this socket. Safe from any thread.
    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        if !closed { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if !closed {
            closed = true
            Darwin.close(fd)
        }
    }
}
