import SwiftUI
import FTPKit

enum StepState: Equatable { case pending, running, done, failed, skipped }

/// What the discovery screen shows while the finder runs.
@MainActor @Observable
final class DiscoveryState {
    var cells = Array(repeating: DiscoveryCellState.waiting, count: 256)
    var gridLabel = "—"
    var hasGrid = false
    var nameState: StepState = .pending
    var nameDetail = MiSTerFinder.defaultHostname
    var sweepState: StepState = .pending
    var sweepDone = 0
    var sweepTotal = 0
    var loginState: StepState = .pending
    var loginDetail = String(localized: "MiSTer를 찾으면 확인해요")
    var found: DiscoveredDevice?
}

enum ConnectProblem: Equatable {
    case notFound(scanned: Int, label: String)
    case loginFailed(host: String)
    case blocked
    case noNetwork
    case failed(host: String, message: String)
    case manual
}

enum Phase: Equatable {
    case discovering
    case problem(ConnectProblem)
    case connected
}

struct DeviceInfo {
    let address: String
    let hostname: String?
    let greeting: String
    let username: String

    var serverName: String {
        MiSTerFinder.isMiSTerGreeting(greeting) ? "ProFTPD" : "FTP"
    }
}

@MainActor @Observable
final class AppModel {
    let settings = AppSettings()
    let transfers = TransferQueue()
    let updates = UpdateModel()

    private(set) var phase: Phase = .discovering
    private(set) var discovery = DiscoveryState()
    private(set) var device: DeviceInfo?
    private(set) var browser: BrowserModel?
    private(set) var isConnecting = false

    var showSettings = false
    var confirmRediscover = false

    // Manual connection form
    var formHost = ""
    var formPort = "21"
    var formUser = AppSettings.defaultUser
    var formPassword = AppSettings.defaultPassword
    var formError: String?

    @ObservationIgnored private var finder: MiSTerFinder?
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init() {
        LocalNetwork.raiseFileLimit()
        transfers.onRemoteDirectoryChanged = { [weak self] directory in
            self?.browser?.scheduleRefresh(of: directory)
        }
        updates.isBusy = { [weak self] in self?.transfers.isBusy ?? false }
        resetForm()
    }

    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        // Update tests launched through Launch Services stay off the local network.
        if ProcessInfo.processInfo.environment["MISTERFTP_NO_DISCOVERY"] == "1" {
            updates.start()
            return
        }
        #endif
        startDiscovery()
        updates.start()
    }

    // MARK: Discovery

    /// Asks before throwing away running transfers.
    func requestRediscover() {
        if transfers.isBusy {
            confirmRediscover = true
        } else {
            startDiscovery()
        }
    }

    func startDiscovery() {
        retryTask?.cancel()
        stopFinder()
        disconnect()
        discovery = DiscoveryState()
        phase = .discovering
        runFinder(showProgress: true)
    }

    func stopFinder() {
        finder?.cancel()
        finder = nil
        discoveryTask?.cancel()
        discoveryTask = nil
    }

    private func runFinder(showProgress: Bool) {
        let finder = MiSTerFinder(credentials: settings.credentials(host: ""), preferredHosts: settings.preferredHosts)
        self.finder = finder
        let startedAt = Date()
        discoveryTask = Task { [weak self] in
            for await event in finder.events() {
                guard let self, self.finder === finder else { return }
                if showProgress { self.apply(event) }
                switch event {
                case .found(let device):
                    guard self.discovery.found == nil else { continue }
                    self.discovery.found = device
                    self.discovery.loginState = .done
                    self.discovery.loginDetail = "\(device.address):\(self.settings.port) · \(self.settings.username)"
                    if self.discovery.sweepState != .done {
                        self.discovery.sweepState = .skipped
                    }
                    if self.discovery.nameState == .running || self.discovery.nameState == .pending {
                        self.discovery.nameState = .skipped
                        self.discovery.nameDetail = String(localized: "\(MiSTerFinder.defaultHostname) · 필요 없어요")
                    }
                    finder.cancel()
                    if showProgress {
                        // Let the found light glow for a moment before the browser appears.
                        let wait = max(0.5, 1.2 - Date().timeIntervalSince(startedAt))
                        try? await Task.sleep(for: .seconds(wait))
                    }
                    guard self.finder === finder else { return }
                    self.finder = nil
                    await self.connect(host: device.address, hostname: device.hostname)
                    return
                case .finished(let summary):
                    self.finder = nil
                    self.finish(summary)
                default:
                    break
                }
            }
        }
    }

    private func apply(_ event: DiscoveryEvent) {
        let state = discovery
        switch event {
        case .grid(let subnet):
            state.hasGrid = subnet != nil
            state.gridLabel = subnet?.displayLabel ?? String(localized: "사설 네트워크 없음")
        case .cell(let index, let cell):
            if state.cells.indices.contains(index), state.cells[index] != .mister {
                state.cells[index] = cell
            }
        case .nameLookupStarted(let name):
            state.nameState = .running
            state.nameDetail = String(localized: "\(name) 확인 중…")
        case .nameLookupFinished(let name, let addresses):
            guard state.nameState != .skipped else { break }
            if let first = addresses.first {
                state.nameState = .done
                state.nameDetail = "\(name) → \(first)"
            } else {
                state.nameState = .failed
                state.nameDetail = String(localized: "\(name) 응답 없음")
            }
        case .sweepProgress(let done, let total):
            guard state.found == nil else { break }
            state.sweepDone = done
            state.sweepTotal = total
            state.sweepState = done >= total ? .done : .running
        case .verifying(let host):
            if state.found == nil {
                state.loginState = .running
                state.loginDetail = "\(host):\(settings.port) · \(settings.username)"
            }
        case .loginFailed(let host):
            if state.found == nil {
                state.loginState = .failed
                state.loginDetail = String(localized: "\(host) · 로그인 실패")
            }
        case .found, .finished:
            break
        }
    }

    private func finish(_ summary: DiscoverySummary) {
        guard discovery.found == nil else { return }
        if discovery.sweepState != .done { discovery.sweepState = .done }
        if summary.localNetworkBlocked {
            phase = .problem(.blocked)
            scheduleQuietRetry(after: 3)
        } else if summary.noNetwork {
            phase = .problem(.noNetwork)
            scheduleQuietRetry(after: 5)
        } else if let host = summary.loginFailures.first {
            formHost = host
            formError = nil
            phase = .problem(.loginFailed(host: host))
        } else {
            if case .problem(.manual) = phase {} else {
                phase = .problem(.notFound(scanned: summary.scannedHosts, label: discovery.gridLabel))
            }
            // The MiSTer may still be booting: keep looking quietly.
            scheduleQuietRetry(after: 8)
        }
    }

    /// Looks again in the background while a problem screen is showing, so the app
    /// connects by itself once the MiSTer boots or local network access is allowed.
    private func scheduleQuietRetry(after seconds: Double) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, self.finder == nil, !self.isConnecting else { return }
            switch self.phase {
            case .problem(.blocked), .problem(.noNetwork), .problem(.notFound), .problem(.manual), .problem(.failed):
                self.discovery = DiscoveryState()
                self.runFinder(showProgress: false)
            default:
                return
            }
        }
    }

    // MARK: Connect

    func connect(host: String, hostname: String? = nil) async {
        isConnecting = true
        formError = nil
        defer { isConnecting = false }

        let credentials = settings.credentials(host: host)
        let session = FTPSession(credentials: credentials, label: "browse")
        do {
            let (greeting, startPath, items) = try await session.perform { connection -> (String, String, [FTPItem]) in
                do {
                    return (connection.greeting, Places.sdCard, try connection.list(Places.sdCard))
                } catch FTPError.server(let code, _) where code == 550 {
                    // Not a MiSTer layout; show the server root instead.
                    return (connection.greeting, "/", try connection.list("/"))
                }
            }
            settings.lastHost = host
            device = DeviceInfo(address: host, hostname: hostname, greeting: greeting, username: credentials.username)
            transfers.configure(credentials: credentials)
            let browser = BrowserModel(session: session, settings: settings, transfers: transfers, path: startPath, items: items)
            self.browser = browser
            phase = .connected
            browser.startKeepAlive()
            await browser.loadPlaces()
        } catch FTPError.loginFailed {
            session.close()
            formHost = host
            formError = String(localized: "로그인하지 못했어요. 사용자 이름과 비밀번호를 확인하세요.")
            phase = .problem(.loginFailed(host: host))
        } catch {
            session.close()
            formHost = host
            formError = error.localizedDescription
            phase = .problem(.failed(host: host, message: error.localizedDescription))
            scheduleQuietRetry(after: 8)
        }
    }

    func connectFromForm() async {
        let host = formHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            formError = String(localized: "MiSTer의 주소를 입력하세요.")
            return
        }
        guard let port = Int(formPort.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else {
            formError = String(localized: "포트는 1부터 65535 사이의 숫자예요.")
            return
        }
        retryTask?.cancel()
        stopFinder()
        settings.port = port
        let user = formUser.trimmingCharacters(in: .whitespaces)
        settings.username = user.isEmpty ? AppSettings.defaultUser : user
        settings.setPassword(formPassword.isEmpty ? AppSettings.defaultPassword : formPassword)
        await connect(host: host)
    }

    func showManualConnect() {
        stopFinder()
        scheduleQuietRetry(after: 8)
        resetForm()
        formError = nil
        phase = .problem(.manual)
    }

    func resetForm() {
        formHost = settings.fixedHost.isEmpty ? (settings.lastHost ?? "") : settings.fixedHost
        formPort = String(settings.port)
        formUser = settings.username
        formPassword = settings.password
    }

    func disconnect() {
        transfers.shutdown()
        browser?.stop()
        browser?.session.close()
        browser = nil
        device = nil
    }
}
