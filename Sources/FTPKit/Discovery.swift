import Foundation

public struct DiscoveredDevice: Sendable, Hashable {
    public let address: String
    public let hostname: String?
    public let greeting: String
}

public enum DiscoveryCellState: Sendable, Equatable {
    case waiting
    case probing
    case silent
    case ftp
    case mister
    case thisMac
    case outside
}

public struct DiscoverySummary: Sendable {
    public var found: [DiscoveredDevice] = []
    /// FTP servers that looked like a MiSTer but refused our user name and password.
    public var loginFailures: [String] = []
    public var otherFTPServers: [String] = []
    public var scannedHosts = 0
    public var localNetworkBlocked = false
    public var noNetwork = false
}

public enum DiscoveryEvent: Sendable {
    /// The /24 block drawn on screen. Nil when the Mac has no private IPv4 network.
    case grid(LocalSubnet?)
    case cell(index: Int, state: DiscoveryCellState)
    case nameLookupStarted(String)
    case nameLookupFinished(String, [String])
    case sweepProgress(done: Int, total: Int)
    case verifying(String)
    case found(DiscoveredDevice)
    case loginFailed(String)
    case finished(DiscoverySummary)
}

/// Finds MiSTer FTP servers on the local network.
///
/// Three searches run at the same time: the last known address, the
/// `MiSTer.local` multicast DNS name, and a TCP sweep of port 21 on this Mac's
/// private network. An FTP server counts as a MiSTer when it accepts the
/// credentials and has a `/media/fat` directory (the MiSTer SD card).
public final class MiSTerFinder: @unchecked Sendable {
    public static let defaultHostname = "MiSTer.local"

    private let credentials: FTPCredentials
    private let preferredHosts: [String]
    private let lock = NSLock()
    private var cancelled = false
    private var claimed: Set<String> = []
    private var summary = DiscoverySummary()
    private var immediateFailures = 0
    private var reachable = 0

    /// `credentials.host` is ignored; every candidate address is tried with the rest.
    public init(credentials: FTPCredentials, preferredHosts: [String]) {
        self.credentials = credentials
        var seen = Set<String>()
        self.preferredHosts = preferredHosts.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    public func events() -> AsyncStream<DiscoveryEvent> {
        AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in self?.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                self.run(continuation)
            }
        }
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    // MARK: Run

    private func run(_ out: AsyncStream<DiscoveryEvent>.Continuation) {
        let subnets = LocalNetwork.subnets()
        let grid = subnets.first
        out.yield(.grid(grid))
        let group = DispatchGroup()

        func cellIndex(_ ip: IPv4) -> Int? {
            guard let grid, ip.value & 0xFFFF_FF00 == grid.displayBase.value else { return nil }
            return Int(ip.value & 0xFF)
        }

        func verify(_ host: String, hostname: String?, trusted: Bool) {
            lock.lock()
            let isNew = claimed.insert(host.lowercased()).inserted
            lock.unlock()
            guard isNew else { return }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                if self.isCancelled { return }
                let outcome = Self.verify(host: host, credentials: self.credentials, allowLoginToUnknownServer: trusted) { address in
                    out.yield(.verifying(address))
                }
                let ip = IPv4(outcome.address ?? host)
                self.lock.lock()
                switch outcome {
                case .mister(let address, let greeting):
                    let device = DiscoveredDevice(address: address, hostname: hostname, greeting: greeting)
                    if !self.summary.found.contains(where: { $0.address == address }) { self.summary.found.append(device) }
                    self.lock.unlock()
                    if let ip, let index = cellIndex(ip) { out.yield(.cell(index: index, state: .mister)) }
                    out.yield(.found(device))
                    return
                case .loginFailed(let address):
                    if !self.summary.loginFailures.contains(address) { self.summary.loginFailures.append(address) }
                    self.lock.unlock()
                    out.yield(.loginFailed(address))
                    return
                case .otherServer(let address):
                    if !self.summary.otherFTPServers.contains(address) { self.summary.otherFTPServers.append(address) }
                case .unreachable(let error):
                    if error.looksLikeLocalNetworkBlock { self.immediateFailures += 1 }
                }
                self.lock.unlock()
            }
        }

        // 1. Addresses we connected to before, or one the user typed in settings.
        for host in preferredHosts {
            verify(host, hostname: nil, trusted: true)
        }

        // 2. The default MiSTer host name over multicast DNS.
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            let name = Self.defaultHostname
            out.yield(.nameLookupStarted(name))
            let addresses = LocalNetwork.resolveIPv4(name, timeout: 3).map(\.description)
            out.yield(.nameLookupFinished(name, addresses))
            for address in addresses where !self.isCancelled {
                verify(address, hostname: name, trusted: true)
            }
        }

        // 3. Sweep port 21 on the private networks.
        var hosts: [IPv4] = []
        for subnet in subnets.prefix(3) {
            for host in subnet.hostsToScan() where !hosts.contains(host) { hosts.append(host) }
        }
        if let grid {
            for index in 0..<256 {
                let ip = IPv4(grid.displayBase.value | UInt32(index))
                if ip == grid.address {
                    out.yield(.cell(index: index, state: .thisMac))
                } else if !grid.contains(ip) || ip == grid.network || ip == grid.broadcast {
                    out.yield(.cell(index: index, state: .outside))
                }
            }
        }
        lock.lock()
        summary.noNetwork = subnets.isEmpty
        summary.scannedHosts = hosts.count
        lock.unlock()

        var done = 0
        PortSweeper.sweep(
            hosts,
            port: credentials.port,
            timeout: 1.2,
            isCancelled: { self.isCancelled },
            onStart: { batch in
                for ip in batch { if let index = cellIndex(ip) { out.yield(.cell(index: index, state: .probing)) } }
            },
            onResult: { ip, result in
                done += 1
                let index = cellIndex(ip)
                switch result {
                case .open:
                    self.lock.lock(); self.reachable += 1; self.lock.unlock()
                    if let index { out.yield(.cell(index: index, state: .ftp)) }
                    verify(ip.description, hostname: nil, trusted: false)
                case .refused:
                    self.lock.lock(); self.reachable += 1; self.lock.unlock()
                    if let index { out.yield(.cell(index: index, state: .silent)) }
                case .failed(_, let immediate):
                    if immediate { self.lock.lock(); self.immediateFailures += 1; self.lock.unlock() }
                    if let index { out.yield(.cell(index: index, state: .silent)) }
                case .noAnswer:
                    if let index { out.yield(.cell(index: index, state: .silent)) }
                }
                if done % 8 == 0 || done == hosts.count { out.yield(.sweepProgress(done: done, total: hosts.count)) }
            }
        )

        group.wait()
        lock.lock()
        // Nearly every address failed at once and nothing answered at all:
        // the system is blocking local network access for this app.
        summary.localNetworkBlocked = summary.found.isEmpty && reachable == 0
            && immediateFailures >= max(3, Int(Double(hosts.count) * 0.8))
        let result = summary
        lock.unlock()
        out.yield(.finished(result))
        out.finish()
    }

    // MARK: Verify one host

    enum Outcome {
        case mister(address: String, greeting: String)
        case loginFailed(address: String)
        case otherServer(address: String)
        case unreachable(FTPError)

        var address: String? {
            switch self {
            case .mister(let address, _), .loginFailed(let address), .otherServer(let address): return address
            case .unreachable: return nil
            }
        }
    }

    /// Logs in only when the host is trusted (a name or address that should be a
    /// MiSTer) or when the greeting is from ProFTPD, the server MiSTer ships.
    /// Other FTP servers on the network (a NAS, a router) never see a login attempt.
    static func verify(host: String, credentials: FTPCredentials, allowLoginToUnknownServer: Bool, willLogIn: (String) -> Void = { _ in }) -> Outcome {
        var target = credentials
        target.host = host
        do {
            let connection = try FTPConnection(credentials: target, connectTimeout: 2, replyTimeout: 4)
            defer { connection.quit() }
            let address = connection.serverAddress
            guard allowLoginToUnknownServer || isMiSTerGreeting(connection.greeting) else {
                return .otherServer(address: address)
            }
            willLogIn(address)
            do {
                try connection.login()
            } catch FTPError.loginFailed {
                return .loginFailed(address: address)
            }
            if let fat = try connection.stat("/media/fat"), fat.isDirectory {
                return .mister(address: address, greeting: connection.greeting)
            }
            return .otherServer(address: address)
        } catch let error as FTPError {
            return .unreachable(error)
        } catch {
            return .unreachable(.connectionClosed)
        }
    }

    public static func isMiSTerGreeting(_ greeting: String) -> Bool {
        greeting.localizedCaseInsensitiveContains("ProFTPD")
    }
}
