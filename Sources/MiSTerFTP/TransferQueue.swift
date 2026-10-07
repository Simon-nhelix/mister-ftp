import AppKit
import FTPKit

/// One row in the transfer tray: a file or a whole folder the user dropped or picked.
@MainActor @Observable
final class TransferJob: Identifiable {
    enum Direction { case upload, download }
    enum State: Equatable {
        case preparing
        case waiting
        case running
        case done
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let direction: Direction
    let name: String
    let isFolder: Bool
    /// "games/SNES" for uploads, the Mac folder name for downloads.
    let destinationLabel: String
    /// Upload target directory, or the directory the download came from.
    let remoteDirectory: String

    var state: State = .preparing
    var totalBytes: Int64 = 0
    var doneBytes: Int64 = 0
    var fileCount = 0
    var doneFiles = 0
    var resultURL: URL?

    // Sources
    fileprivate let localURL: URL?
    fileprivate let remoteItem: FTPItem?
    fileprivate let localTarget: URL?
    fileprivate var plan: UploadPlan?
    fileprivate var cancelRequested = false

    fileprivate init(upload url: URL, isFolder: Bool, into remoteDirectory: String) {
        direction = .upload
        name = url.lastPathComponent
        self.isFolder = isFolder
        destinationLabel = Places.shortLabel(remoteDirectory)
        self.remoteDirectory = remoteDirectory
        localURL = url
        remoteItem = nil
        localTarget = nil
    }

    fileprivate init(download item: FTPItem, to target: URL) {
        direction = .download
        name = item.name
        isFolder = item.isDirectory
        destinationLabel = FileManager.default.displayName(atPath: target.deletingLastPathComponent().path)
        remoteDirectory = RemotePath.parent(of: item.path)
        localURL = nil
        remoteItem = item
        localTarget = target
        totalBytes = item.size ?? 0
        fileCount = item.isDirectory ? 0 : 1
        state = .waiting
    }

    var isFinished: Bool {
        switch state {
        case .done, .failed, .cancelled: return true
        default: return false
        }
    }

    var progress: Double {
        if state == .done { return 1 }
        return totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0
    }
}

@MainActor @Observable
final class TransferQueue {
    private(set) var jobs: [TransferJob] = []
    var expanded = true
    private(set) var speed: Double = 0

    /// Called after uploads change a server directory, so the browser can refresh.
    @ObservationIgnored var onRemoteDirectoryChanged: ((String) -> Void)?

    @ObservationIgnored private var workers: [Worker] = []
    @ObservationIgnored private var credentials: FTPCredentials?
    @ObservationIgnored private var sampler: Timer?
    @ObservationIgnored private var lastSample: (bytes: Int64, time: Date) = (0, Date())
    @ObservationIgnored private var reservedPaths: Set<String> = []

    private final class Worker {
        let session: FTPSession
        var job: TransferJob?
        init(session: FTPSession) { self.session = session }
    }

    /// Two connections: one big file never blocks the next small one for long.
    func configure(credentials: FTPCredentials) {
        guard credentials != self.credentials else { return }
        shutdown()
        self.credentials = credentials
        workers = (0..<2).map { Worker(session: FTPSession(credentials: credentials, label: "transfer\($0)")) }
    }

    func shutdown() {
        cancelAll()
        workers.forEach { $0.session.close() }
        workers = []
        credentials = nil
    }

    // MARK: Summary

    var hasJobs: Bool { !jobs.isEmpty }
    var isBusy: Bool { jobs.contains { !$0.isFinished } }
    var finishedCount: Int { jobs.filter(\.isFinished).count }

    private var countedJobs: [TransferJob] { jobs.filter { $0.state != .cancelled } }
    var totalBytes: Int64 { countedJobs.reduce(0) { $0 + $1.totalBytes } }
    var doneBytes: Int64 { countedJobs.reduce(0) { $0 + ($1.state == .done ? $1.totalBytes : $1.doneBytes) } }
    var overallProgress: Double {
        let total = totalBytes
        if total == 0 { return isBusy ? 0 : 1 }
        return min(1, Double(doneBytes) / Double(total))
    }
    var remainingSeconds: Double? {
        guard speed > 0, isBusy else { return nil }
        return Double(max(0, totalBytes - doneBytes)) / speed
    }

    // MARK: Enqueue

    func enqueueUploads(_ urls: [URL], to remoteDirectory: String) {
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let job = TransferJob(upload: url, isFolder: isFolder, into: remoteDirectory)
            jobs.append(job)
            Task.detached(priority: .userInitiated) {
                let result = Result { try UploadPlan.make(for: url, into: remoteDirectory) }
                await MainActor.run {
                    switch result {
                    case .success(let plan):
                        job.plan = plan
                        job.totalBytes = plan.totalBytes
                        job.fileCount = plan.files.count
                        if job.state == .preparing { job.state = .waiting }
                    case .failure(let error):
                        if job.state == .preparing { job.state = .failed(error.localizedDescription) }
                    }
                    self.pump()
                }
            }
        }
        expanded = true
        startSampler()
    }

    func enqueueDownloads(_ items: [FTPItem], to folder: URL) {
        for item in items {
            let target = uniqueLocalURL(in: folder, name: item.name)
            reservedPaths.insert(target.path)
            jobs.append(TransferJob(download: item, to: target))
        }
        expanded = true
        startSampler()
        pump()
    }

    /// "name 2.ext" style name that is free on disk and not taken by another download.
    private func uniqueLocalURL(in folder: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) || reservedPaths.contains(candidate.path) {
            let next = ext.isEmpty || base.isEmpty ? "\(name) \(number)" : "\(base) \(number).\(ext)"
            candidate = folder.appendingPathComponent(next)
            number += 1
        }
        return candidate
    }

    // MARK: Control

    func cancel(_ job: TransferJob) {
        switch job.state {
        case .preparing, .waiting:
            job.state = .cancelled
        case .running:
            job.cancelRequested = true
            workers.first { $0.job === job }?.session.abortCurrent()
        default:
            break
        }
    }

    func cancelAll() {
        jobs.filter { !$0.isFinished }.forEach(cancel)
    }

    func remove(_ job: TransferJob) {
        guard job.isFinished else { return }
        jobs.removeAll { $0 === job }
    }

    func clearFinished() {
        jobs.removeAll(where: \.isFinished)
    }

    func reveal(_ job: TransferJob) {
        guard let url = job.resultURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Scheduling

    private func pump() {
        for worker in workers where worker.job == nil {
            guard let job = jobs.first(where: { $0.state == .waiting }) else { break }
            worker.job = job
            job.state = .running
            let session = worker.session
            Task.detached(priority: .userInitiated) {
                let outcome = await TransferRunner.run(job, session: session)
                await MainActor.run {
                    if job.state == .running { job.state = outcome }
                    worker.job = nil
                    if let target = job.localTarget { self.reservedPaths.remove(target.path) }
                    if job.direction == .upload, job.doneFiles > 0 || job.state == .done {
                        self.onRemoteDirectoryChanged?(job.remoteDirectory)
                    }
                    self.pump()
                }
            }
        }
    }

    // MARK: Speed

    private func startSampler() {
        guard sampler == nil else { return }
        lastSample = (doneBytes, Date())
        sampler = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        let now = Date()
        let bytes = doneBytes
        let elapsed = now.timeIntervalSince(lastSample.time)
        if elapsed > 0 {
            let instant = Double(max(0, bytes - lastSample.bytes)) / elapsed
            speed = speed == 0 ? instant : speed * 0.7 + instant * 0.3
        }
        lastSample = (bytes, now)
        if !isBusy {
            speed = 0
            sampler?.invalidate()
            sampler = nil
        }
    }

    // MARK: Runner

    /// Does the network work for one job on the worker's session.
    private enum TransferRunner {
        static func run(_ job: TransferJob, session: FTPSession) async -> TransferJob.State {
            do {
                let direction = await MainActor.run { job.direction }
                switch direction {
                case .upload: try await upload(job, session: session)
                case .download: try await download(job, session: session)
                }
                return .done
            } catch {
                if await MainActor.run(body: { job.cancelRequested }) || (error as? FTPError) == .cancelled {
                    return .cancelled
                }
                return .failed(error.localizedDescription)
            }
        }

        private static func checkCancel(_ job: TransferJob) async throws {
            if await MainActor.run(body: { job.cancelRequested }) { throw FTPError.cancelled }
        }

        static func upload(_ job: TransferJob, session: FTPSession) async throws {
            guard let plan = await MainActor.run(body: { job.plan }) else { throw FTPError.cancelled }
            for directory in plan.directories {
                try await checkCancel(job)
                try await session.perform { try $0.ensureDirectory(directory) }
            }
            var done: Int64 = 0
            for file in plan.files {
                try await checkCancel(job)
                let reporter = ProgressReporter(job: job, base: done)
                do {
                    try await attempt(session) { try $0.upload(file.local, to: file.remote, progress: reporter.report) }
                } catch FTPError.cancelled {
                    // Leave no half-written file on the MiSTer.
                    try? await session.perform { try $0.deleteFile(file.remote) }
                    throw FTPError.cancelled
                }
                done += file.size
                let finished = done
                await MainActor.run {
                    job.doneBytes = finished
                    job.doneFiles += 1
                }
            }
        }

        static func download(_ job: TransferJob, session: FTPSession) async throws {
            guard let (item, target) = await MainActor.run(body: {
                guard let item = job.remoteItem, let target = job.localTarget else { return nil }
                return (item, target)
            }) else {
                throw FTPError.cancelled
            }
            var directories: [URL] = []
            var files: [(remote: String, local: URL, size: Int64)] = []
            if item.isDirectory {
                directories.append(target)
                var stack = [(item.path, target)]
                while let (remote, local) = stack.popLast() {
                    try await checkCancel(job)
                    for child in try await session.perform({ try $0.list(remote) }) {
                        let childURL = local.appendingPathComponent(child.name)
                        switch child.kind {
                        case .directory:
                            directories.append(childURL)
                            stack.append((child.path, childURL))
                        case .file:
                            files.append((child.path, childURL, child.size ?? 0))
                        case .link:
                            continue
                        }
                    }
                }
            } else {
                files.append((item.path, target, item.size ?? 0))
            }
            let total = files.reduce(Int64(0)) { $0 + $1.size }
            let count = files.count
            await MainActor.run {
                job.totalBytes = total
                job.fileCount = count
            }
            for directory in directories {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            await MainActor.run { job.resultURL = target }

            var done: Int64 = 0
            for file in files {
                try await checkCancel(job)
                let reporter = ProgressReporter(job: job, base: done)
                do {
                    try await attempt(session) { try $0.download(file.remote, to: file.local, progress: reporter.report) }
                } catch {
                    try? FileManager.default.removeItem(at: file.local)
                    throw error
                }
                done += file.size
                let finished = done
                await MainActor.run {
                    job.doneBytes = finished
                    job.doneFiles += 1
                }
            }
        }

        /// Runs a transfer; if the connection dropped, tries once more on a new connection.
        private static func attempt(_ session: FTPSession, _ work: @escaping (FTPConnection) throws -> Void) async throws {
            do {
                try await session.perform(retry: false, work)
            } catch let error as FTPError where error.isConnectionLost {
                try await session.perform(retry: false, work)
            }
        }
    }
}

/// Passes byte counts from the transfer thread to the UI about 12 times a second.
private final class ProgressReporter: @unchecked Sendable {
    private let job: TransferJob
    private let base: Int64
    private var lastReport: UInt64 = 0

    init(job: TransferJob, base: Int64) {
        self.job = job
        self.base = base
    }

    func report(_ bytes: Int64) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastReport > 80_000_000 else { return }
        lastReport = now
        let value = base + bytes
        let job = self.job
        Task { @MainActor in
            if value > job.doneBytes { job.doneBytes = value }
        }
    }
}

/// Everything one upload needs: directories to create first, then files.
struct UploadPlan: Sendable {
    struct File: Sendable {
        let local: URL
        let remote: String
        let size: Int64
    }

    var directories: [String]
    var files: [File]
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// macOS leaves these behind; MiSTer does not need them.
    static func isJunk(_ name: String) -> Bool {
        name.hasPrefix("._") || [".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", ".localized", "Icon\r"].contains(name)
    }

    /// NFC Korean, and no characters that FAT/exFAT cannot store.
    static func remoteName(_ name: String) -> String {
        let composed = name.precomposedStringWithCanonicalMapping
        let forbidden = CharacterSet(charactersIn: "\\:*?\"<>|")
        return String(String.UnicodeScalarView(composed.unicodeScalars.map { scalar in
            forbidden.contains(scalar) || scalar.value < 0x20 ? "_" : scalar
        }))
    }

    static func make(for url: URL, into remoteDirectory: String) throws -> UploadPlan {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        let top = RemotePath.join(remoteDirectory, remoteName(url.lastPathComponent))
        let values = try url.resourceValues(forKeys: Set(keys))
        guard values.isDirectory == true else {
            return UploadPlan(directories: [], files: [File(local: url, remote: top, size: Int64(values.fileSize ?? 0))])
        }

        var plan = UploadPlan(directories: [top], files: [])
        let baseCount = url.standardizedFileURL.pathComponents.count
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return plan }
        for case let child as URL in walker {
            let childValues = try child.resourceValues(forKeys: Set(keys))
            if isJunk(child.lastPathComponent) || childValues.isSymbolicLink == true {
                if childValues.isDirectory == true { walker.skipDescendants() }
                continue
            }
            let relative = child.standardizedFileURL.pathComponents.dropFirst(baseCount).map(remoteName)
            let remote = relative.reduce(top) { RemotePath.join($0, $1) }
            if childValues.isDirectory == true {
                plan.directories.append(remote)
            } else {
                plan.files.append(File(local: child, remote: remote, size: Int64(childValues.fileSize ?? 0)))
            }
        }
        return plan
    }
}
