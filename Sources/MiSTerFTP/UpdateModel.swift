import AppKit
import UpdateKit

/// Checks GitHub for a newer release and installs it when the user agrees.
///
/// Info.plist keys: `MFTPUpdateRepository` ("owner/name"), `MFTPUpdatePublicKey`
/// (Ed25519, Base64) and, for tests only, `MFTPUpdateAPIURL` to use another feed.
@MainActor @Observable
final class UpdateModel {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateOffer)
        case downloading(UpdateOffer, received: Int64, total: Int64)
        case installing(UpdateOffer)
        case failed(String, UpdateOffer?)
    }

    struct Configuration {
        let feedURL: URL
        let releasesPage: URL?
        let publicKey: String
        let bundleIdentifier: String
        let appURL: URL
        let currentVersion: AppVersion
    }

    private(set) var state: State = .idle
    var showSheet = false
    private(set) var lastCheck: Date?
    var autoCheck: Bool {
        didSet {
            defaults.set(autoCheck, forKey: Keys.autoCheck)
            scheduleAutomaticChecks()
        }
    }

    let configuration: Configuration?
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// True while transfers run; installing then would cut them off.
    @ObservationIgnored var isBusy: () -> Bool = { false }
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var skippedVersion: String?

    private enum Keys {
        static let autoCheck = "checkForUpdates"
        static let lastCheck = "lastUpdateCheck"
        static let skipped = "skippedUpdateVersion"
    }

    init(bundle: Bundle = .main) {
        autoCheck = defaults.object(forKey: Keys.autoCheck) as? Bool ?? true
        lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date
        skippedVersion = defaults.string(forKey: Keys.skipped)

        let info = bundle.infoDictionary ?? [:]
        let repository = info["MFTPUpdateRepository"] as? String
        let feed = (info["MFTPUpdateAPIURL"] as? String).flatMap(URL.init(string:))
            ?? repository.flatMap(ReleaseFeed.latestReleaseURL(repository:))
        if let feed,
           let publicKey = info["MFTPUpdatePublicKey"] as? String, !publicKey.isEmpty,
           let identifier = bundle.bundleIdentifier,
           let version = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init),
           bundle.bundleURL.pathExtension == "app" {
            configuration = Configuration(
                feedURL: feed,
                releasesPage: repository.flatMap { URL(string: "https://github.com/\($0)/releases") },
                publicKey: publicKey,
                bundleIdentifier: identifier,
                appURL: bundle.bundleURL,
                currentVersion: version
            )
        } else {
            // A debug build run from .build has no Info.plist.
            configuration = nil
        }
    }

    /// The new version the sidebar card and the badge point to. Hidden while installing.
    var bannerOffer: UpdateOffer? {
        if case .installing = state { return nil }
        return pendingOffer
    }

    /// The offer the sheet describes.
    var pendingOffer: UpdateOffer? {
        switch state {
        case .available(let offer), .downloading(let offer, _, _), .installing(let offer): return offer
        case .failed(_, let offer): return offer
        default: return nil
        }
    }

    // MARK: Checking

    func start() {
        scheduleAutomaticChecks()
    }

    /// The first automatic look waits a few seconds, so it never slows down finding the MiSTer.
    private func scheduleAutomaticChecks() {
        timer?.invalidate()
        timer = nil
        guard autoCheck, configuration != nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.checkIfDue()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
    }

    /// Automatic checks happen at most about once a day.
    private func checkIfDue() async {
        guard autoCheck, state == .idle || state == .upToDate else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 20 * 3600 { return }
        await check(userInitiated: false)
    }

    /// "Check for Updates…": opens the sheet and shows the answer, even "up to date".
    func checkNow() {
        showSheet = true
        switch state {
        case .downloading, .installing: return
        default: Task { await check(userInitiated: true) }
        }
    }

    func check(userInitiated: Bool) async {
        guard let configuration else {
            if userInitiated { state = .failed(String(localized: "개발 빌드에서는 업데이트를 확인할 수 없어요."), nil) }
            return
        }
        if userInitiated { state = .checking }
        do {
            let release = try await ReleaseFeed.fetchLatest(from: configuration.feedURL, userAgent: "MiSTer-FTP/\(configuration.currentVersion)")
            lastCheck = Date()
            defaults.set(lastCheck, forKey: Keys.lastCheck)
            if let release, let offer = ReleaseFeed.offer(from: release), offer.version > configuration.currentVersion,
               userInitiated || offer.version.description != skippedVersion {
                state = .available(offer)
            } else {
                state = .upToDate
            }
        } catch {
            // Automatic checks fail quietly; the next one tries again.
            state = userInitiated ? .failed(error.localizedDescription, nil) : .idle
        }
    }

    // MARK: Choices

    func later() {
        showSheet = false
    }

    func skip(_ offer: UpdateOffer) {
        skippedVersion = offer.version.description
        defaults.set(skippedVersion, forKey: Keys.skipped)
        state = .idle
        showSheet = false
    }

    func openReleasePage() {
        if let url = pendingOffer?.pageURL ?? configuration?.releasesPage {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Installing

    func install(_ offer: UpdateOffer) {
        guard let configuration, !isBusy() else { return }
        installTask?.cancel()
        installTask = Task {
            let workFolder = FileManager.default.temporaryDirectory.appendingPathComponent("MiSTerFTP-Update", isDirectory: true)
            do {
                try UpdateInstaller.checkReplaceable(configuration.appURL)
                state = .downloading(offer, received: 0, total: offer.archiveSize)
                let preparer = UpdatePreparer(
                    publicKey: configuration.publicKey,
                    bundleIdentifier: configuration.bundleIdentifier,
                    currentVersion: configuration.currentVersion,
                    workFolder: workFolder
                )
                let newApp = try await preparer.prepare(offer) { received, total in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(offer, received: received, total: total > 0 ? total : offer.archiveSize)
                    }
                }
                guard !isBusy() else {
                    state = .available(offer)
                    return
                }
                state = .installing(offer)
                let oldCopy = try UpdateInstaller.swap(installedApp: configuration.appURL, with: newApp)
                try? FileManager.default.removeItem(at: workFolder)
                try UpdateInstaller.relaunchAfterExit(app: configuration.appURL, cleanup: oldCopy)
                // Let the sheet show "reopening" for a moment. AppKit refuses to quit
                // while a sheet is attached, so close it and wait until it is gone.
                try? await Task.sleep(for: .milliseconds(600))
                showSheet = false
                for _ in 0..<30 where NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                NSApp.terminate(nil)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: workFolder)
                state = .available(offer)
            } catch {
                try? FileManager.default.removeItem(at: workFolder)
                state = .failed(error.localizedDescription, offer)
            }
        }
    }

    func cancelDownload() {
        installTask?.cancel()
    }

    #if DEBUG
    /// For the debug harness: shows a state without talking to GitHub.
    func debugShow(_ newState: State) {
        state = newState
    }
    #endif
}
