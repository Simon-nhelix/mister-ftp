import Foundation
import Darwin

/// An IPv4 address in host byte order.
public struct IPv4: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let value: UInt32

    public init(_ value: UInt32) { self.value = value }

    public init?(_ text: String) {
        let parts = text.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            result = result << 8 | UInt32(byte)
        }
        value = result
    }

    public var description: String {
        "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    public var isPrivate: Bool {
        let a = value >> 24, b = value >> 16 & 0xFF
        return a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
    }

    public static func < (lhs: IPv4, rhs: IPv4) -> Bool { lhs.value < rhs.value }
}

/// A private IPv4 network this Mac is connected to.
public struct LocalSubnet: Hashable, Sendable {
    public let interface: String
    public let address: IPv4
    public let prefixLength: Int

    public var mask: UInt32 { prefixLength == 0 ? 0 : UInt32.max << UInt32(32 - prefixLength) }
    public var network: IPv4 { IPv4(address.value & mask) }
    public var broadcast: IPv4 { IPv4(address.value | ~mask) }

    /// The /24 block around this Mac, which the discovery screen draws as a 16×16 grid.
    public var displayBase: IPv4 { IPv4(address.value & 0xFFFF_FF00) }
    public var displayLabel: String { "\(displayBase)/24" }

    public func contains(_ ip: IPv4) -> Bool { ip.value & mask == address.value & mask }

    /// Host addresses to probe. Networks larger than /22 are cut down to this Mac's /24.
    public func hostsToScan() -> [IPv4] {
        let effectivePrefix = prefixLength < 22 ? 24 : prefixLength
        let effectiveMask: UInt32 = UInt32.max << UInt32(32 - effectivePrefix)
        let first = address.value & effectiveMask
        let last = address.value | ~effectiveMask
        guard last > first + 1 else { return [] }
        return (first + 1..<last).map(IPv4.init).filter { $0 != address }
    }
}

public enum LocalNetwork {
    /// Private IPv4 networks on active Ethernet/Wi-Fi style interfaces, best candidate first.
    public static func subnets() -> [LocalSubnet] {
        var list: [LocalSubnet] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let netmask = entry.pointee.ifa_netmask else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4(UInt32(bigEndian: $0.pointee.sin_addr.s_addr)) }
            let maskValue = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            guard ip.isPrivate else { continue }
            let subnet = LocalSubnet(interface: name, address: ip, prefixLength: maskValue.nonzeroBitCount)
            if !list.contains(where: { $0.network == subnet.network && $0.prefixLength == subnet.prefixLength }) {
                list.append(subnet)
            }
        }
        // en* (Ethernet / Wi-Fi) before bridges and virtual interfaces.
        return list.sorted { rank($0.interface) < rank($1.interface) }
    }

    private static func rank(_ name: String) -> Int {
        if name.hasPrefix("en") { return 0 }
        if name.hasPrefix("bridge") { return 2 }
        return 1
    }

    /// Raises the open-file limit so a whole /24 can be probed at once.
    public static func raiseFileLimit(to wanted: rlim_t = 4096) {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let target = min(wanted, limit.rlim_max)
        if limit.rlim_cur < target {
            limit.rlim_cur = target
            setrlimit(RLIMIT_NOFILE, &limit)
        }
    }

    /// Resolves a host name with a time limit. `.local` names use multicast DNS.
    public static func resolveIPv4(_ host: String, timeout: TimeInterval) -> [IPv4] {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let addresses = (try? TCPSocket.resolve(host: host, port: 21, family: AF_INET)) ?? []
            box.set(addresses.filter { $0.family == AF_INET }.compactMap { IPv4($0.numeric) })
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return [] }
        return box.get()
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [IPv4] = []
        func set(_ newValue: [IPv4]) { lock.lock(); value = newValue; lock.unlock() }
        func get() -> [IPv4] { lock.lock(); defer { lock.unlock() }; return value }
    }
}

/// Probes many hosts on one TCP port at the same time with non-blocking sockets.
public enum PortSweeper {
    public enum Result: Sendable, Equatable {
        case open
        case refused
        /// The connection failed before the timeout. `immediate` is true when it failed
        /// in a few milliseconds, which is what a local-network permission block looks like.
        case failed(code: Int32, immediate: Bool)
        case noAnswer
    }

    public static func sweep(
        _ hosts: [IPv4],
        port: UInt16,
        timeout: TimeInterval,
        batchSize: Int = 256,
        isCancelled: () -> Bool,
        onStart: ([IPv4]) -> Void = { _ in },
        onResult: (IPv4, Result) -> Void
    ) {
        var index = 0
        while index < hosts.count, !isCancelled() {
            let batch = Array(hosts[index..<min(index + batchSize, hosts.count)])
            index += batch.count
            onStart(batch)
            sweepBatch(batch, port: port, timeout: timeout, isCancelled: isCancelled, onResult: onResult)
        }
    }

    private static func sweepBatch(_ hosts: [IPv4], port: UInt16, timeout: TimeInterval, isCancelled: () -> Bool, onResult: (IPv4, Result) -> Void) {
        let started = Date()
        var pending: [(fd: Int32, host: IPv4)] = []

        for host in hosts {
            let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else {
                onResult(host, .failed(code: errno, immediate: false))
                continue
            }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: host.value.bigEndian)
            let rc = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if rc == 0 {
                close(fd)
                onResult(host, .open)
            } else if errno == EINPROGRESS {
                pending.append((fd, host))
            } else {
                let code = errno
                close(fd)
                onResult(host, code == ECONNREFUSED ? .refused : .failed(code: code, immediate: true))
            }
        }

        let deadline = started.addingTimeInterval(timeout)
        while !pending.isEmpty {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 || isCancelled() { break }
            var fds = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
            let ready = poll(&fds, nfds_t(fds.count), Int32(min(50, max(1, remaining * 1000))))
            if ready <= 0 { continue }
            var stillPending: [(fd: Int32, host: IPv4)] = []
            for (i, entry) in pending.enumerated() {
                guard fds[i].revents != 0 else {
                    stillPending.append(entry)
                    continue
                }
                var soError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(entry.fd, SOL_SOCKET, SO_ERROR, &soError, &length)
                close(entry.fd)
                let immediate = Date().timeIntervalSince(started) < 0.03
                switch soError {
                case 0: onResult(entry.host, .open)
                case ECONNREFUSED: onResult(entry.host, .refused)
                default: onResult(entry.host, .failed(code: soError, immediate: immediate))
                }
            }
            pending = stillPending
        }
        for entry in pending {
            close(entry.fd)
            onResult(entry.host, .noAnswer)
        }
    }
}
