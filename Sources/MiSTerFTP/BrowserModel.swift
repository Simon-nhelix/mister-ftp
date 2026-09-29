import AppKit
import FTPKit

/// A place in the sidebar.
struct Place: Identifiable, Hashable {
    enum Kind { case storage, shortcut }
    var id: String { path }
    let path: String
    let title: String
    let symbol: String
    let kind: Kind
    var detail: String?
}

enum SortKey { case name, size, date }

/// The open folder on the MiSTer: listing, selection, history and file operations.
@MainActor @Observable
final class BrowserModel {
    let session: FTPSession
    private let settings: AppSettings
    private let transfers: TransferQueue

    private(set) var path: String
    private(set) var items: [FTPItem] = [] { didSet { rebuild() } }
    private(set) var visibleItems: [FTPItem] = []
    var filter = "" { didSet { rebuild() } }
    var sortKey: SortKey = .name { didSet { rebuild() } }
    var ascending = true { didSet { rebuild() } }
    var selection: Set<String> = []
    @ObservationIgnored private var anchor: String?

    private(set) var isLoading = false
    private(set) var busyMessage: String?
    var errorMessage: String?
    /// False while the MiSTer does not answer; the keep-alive loop reconnects.
    private(set) var connectionHealthy = true
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?

    private(set) var storages: [Place] = [Place(path: Places.sdCard, title: Places.displayName(for: Places.sdCard), symbol: "sdcard", kind: .storage, detail: "fat")]
    private(set) var shortcuts: [Place] = []

    private var backStack: [String] = []
    private var forwardStack: [String] = []
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    // Dialog state
    var pendingDelete: [FTPItem]?
    var pendingRename: FTPItem?
    var renameText = ""
    var isCreatingFolder = false
    var newFolderName = ""
    var pendingConflict: PendingUpload?

    struct PendingUpload {
        let urls: [URL]
        let directory: String
        let clashes: [String]
    }

    init(session: FTPSession, settings: AppSettings, transfers: TransferQueue, path: String, items: [FTPItem]) {
        self.session = session
        self.settings = settings
        self.transfers = transfers
        self.path = path
        self.items = items
        rebuild()
    }

    /// Sends NOOP every 30 s so the server keeps the session, and notices a lost MiSTer.
    func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                let healthy = self?.connectionHealthy ?? true
                try? await Task.sleep(for: .seconds(healthy ? 30 : 4))
                guard let self, !Task.isCancelled else { return }
                do {
                    try await self.session.perform { try $0.noop() }
                    if !self.connectionHealthy {
                        self.connectionHealthy = true
                        await self.refresh()
                    }
                } catch {
                    self.connectionHealthy = false
                }
            }
        }
    }

    func stop() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        refreshTask?.cancel()
    }

    private func noteFailure(_ error: Error) {
        if let ftp = error as? FTPError {
            switch ftp {
            case .connectFailed, .timeout, .connectionClosed, .hostNotFound: connectionHealthy = false
            default: break
            }
        }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { path != "/" }
    var showHidden: Bool { settings.showHidden }

    var selectedItems: [FTPItem] { visibleItems.filter { selection.contains($0.path) } }

    // MARK: Listing

    func rebuild() {
        var list = items
        if !settings.showHidden { list.removeAll(where: \.isHidden) }
        let query = filter.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { list.removeAll { !$0.name.localizedCaseInsensitiveContains(query) } }
        let up = ascending
        list.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order: ComparisonResult
            switch sortKey {
            case .name:
                order = a.name.localizedStandardCompare(b.name)
            case .size:
                let left = a.size ?? -1, right = b.size ?? -1
                order = left == right ? a.name.localizedStandardCompare(b.name) : (left < right ? .orderedAscending : .orderedDescending)
            case .date:
                let left = a.modified ?? .distantPast, right = b.modified ?? .distantPast
                order = left == right ? a.name.localizedStandardCompare(b.name) : (left < right ? .orderedAscending : .orderedDescending)
            }
            return up ? order == .orderedAscending : order == .orderedDescending
        }
        visibleItems = list
        let visible = Set(list.map(\.path))
        if !selection.isSubset(of: visible) { selection.formIntersection(visible) }
    }

    func setSort(_ key: SortKey) {
        if sortKey == key { ascending.toggle() } else { sortKey = key; ascending = key == .name }
    }

    func open(_ newPath: String, recordHistory: Bool = true) async {
        let target = RemotePath.normalize(newPath)
        loadToken += 1
        let token = loadToken
        let spinner = Task {
            try? await Task.sleep(for: .milliseconds(180))
            if !Task.isCancelled && token == loadToken { isLoading = true }
        }
        defer {
            spinner.cancel()
            if token == loadToken { isLoading = false }
        }
        do {
            let list = try await session.perform { try $0.list(target) }
            guard token == loadToken else { return }
            if recordHistory && target != path {
                backStack.append(path)
                forwardStack.removeAll()
            }
            let changedFolder = target != path
            path = target
            filter = changedFolder ? "" : filter
            items = list
            if changedFolder { selection = []; anchor = nil }
            errorMessage = nil
            connectionHealthy = true
        } catch {
            guard token == loadToken else { return }
            noteFailure(error)
            errorMessage = String(localized: "‘\(Places.displayName(for: target))’ 폴더를 열지 못했어요. \(error.localizedDescription)")
        }
    }

    func refresh() async { await open(path, recordHistory: false) }

    /// Refreshes soon, merging bursts of finished uploads into one listing.
    func scheduleRefresh(of directory: String) {
        guard RemotePath.normalize(directory) == path else { return }
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    func goBack() async {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        await open(previous, recordHistory: false)
    }

    func goForward() async {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        await open(next, recordHistory: false)
    }

    func goUp() async {
        guard canGoUp else { return }
        let child = path
        await open(RemotePath.parent(of: path))
        if visibleItems.contains(where: { $0.path == child }) { selection = [child]; anchor = child }
    }

    func activate(_ item: FTPItem) async {
        if item.kind == .file {
            download([item])
        } else {
            await open(item.path)
        }
    }

    /// Finds USB drives and the usual MiSTer folders for the sidebar.
    func loadPlaces() async {
        let found = try? await session.perform { connection -> ([Place], [Place]) in
            var storages = [Place(path: Places.sdCard, title: Places.displayName(for: Places.sdCard), symbol: "sdcard", kind: .storage, detail: "fat")]
            if let media = try? connection.list("/media") {
                for folder in media.filter(\.isDirectory).sorted(by: { $0.name < $1.name }) {
                    guard Places.usbNumber(folder.path) != nil,
                          let contents = try? connection.list(folder.path), !contents.isEmpty else { continue }
                    storages.append(Place(path: folder.path, title: Places.displayName(for: folder.path), symbol: "externaldrive", kind: .storage, detail: folder.name))
                }
            }
            let known: [(String, String, String)] = [
                ("games", String(localized: "게임"), "gamecontroller"),
                ("_Arcade", String(localized: "아케이드"), "arcade.stick"),
                ("saves", String(localized: "세이브"), "memorychip"),
                ("savestates", String(localized: "세이브 스테이트"), "square.stack.3d.up"),
                ("screenshots", String(localized: "스크린샷"), "camera.viewfinder"),
                ("Scripts", String(localized: "스크립트"), "terminal"),
                ("wallpapers", String(localized: "배경화면"), "photo"),
            ]
            let root = (try? connection.list(Places.sdCard)) ?? []
            let shortcuts = known.compactMap { name, title, symbol -> Place? in
                guard root.contains(where: { $0.name == name && $0.isDirectory }) else { return nil }
                return Place(path: RemotePath.join(Places.sdCard, name), title: title, symbol: symbol, kind: .shortcut)
            }
            return (storages, shortcuts)
        }
        if let found {
            storages = found.0
            shortcuts = found.1
        }
    }

    // MARK: Selection

    func click(_ item: FTPItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(item.path) { selection.remove(item.path) } else { selection.insert(item.path) }
            anchor = item.path
        } else if modifiers.contains(.shift), let anchor, let from = visibleItems.firstIndex(where: { $0.path == anchor }),
                  let to = visibleItems.firstIndex(where: { $0.path == item.path }) {
            selection = Set(visibleItems[min(from, to)...max(from, to)].map(\.path))
        } else {
            selection = [item.path]
            anchor = item.path
        }
    }

    /// Right-click: act on the selection when the row is part of it, else on the row alone.
    func contextTargets(for item: FTPItem) -> [FTPItem] {
        if selection.contains(item.path) { return selectedItems }
        selection = [item.path]
        anchor = item.path
        return [item]
    }

    func moveSelection(by offset: Int, extend: Bool) -> String? {
        guard !visibleItems.isEmpty else { return nil }
        let current = visibleItems.lastIndex { selection.contains($0.path) && $0.path == anchor }
            ?? visibleItems.lastIndex { selection.contains($0.path) }
        let next: Int
        if let current {
            next = min(max(current + offset, 0), visibleItems.count - 1)
        } else {
            next = offset > 0 ? 0 : visibleItems.count - 1
        }
        let target = visibleItems[next].path
        if extend { selection.insert(target) } else { selection = [target] }
        anchor = target
        return target
    }

    func selectAll() { selection = Set(visibleItems.map(\.path)) }

    // MARK: Transfers

    func download(_ items: [FTPItem], to folder: URL? = nil) {
        let targets = items.filter { $0.kind != .link }
        guard !targets.isEmpty else { return }
        transfers.enqueueDownloads(targets, to: folder ?? settings.downloadFolder)
    }

    func downloadWithPanel(_ items: [FTPItem]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "여기에 받기")
        panel.directoryURL = settings.downloadFolder
        if panel.runModal() == .OK, let url = panel.url { download(items, to: url) }
    }

    func uploadWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "올리기")
        panel.message = String(localized: "\(Places.displayName(for: path)) 폴더에 올릴 파일이나 폴더를 고르세요.")
        if panel.runModal() == .OK { upload(panel.urls) }
    }

    /// Starts uploads into the open folder, asking first when names already exist.
    func upload(_ urls: [URL]) {
        let files = urls.filter { !UploadPlan.isJunk($0.lastPathComponent) }
        guard !files.isEmpty else { return }
        let existing = Set(items.map { $0.name.lowercased() })
        let clashes = files.map { UploadPlan.remoteName($0.lastPathComponent) }.filter { existing.contains($0.lowercased()) }
        if clashes.isEmpty {
            transfers.enqueueUploads(files, to: path)
        } else {
            pendingConflict = PendingUpload(urls: files, directory: path, clashes: clashes)
        }
    }

    func resolveConflict(_ pending: PendingUpload, overwrite: Bool) {
        pendingConflict = nil
        let clashes = Set(pending.clashes.map { $0.lowercased() })
        let urls = overwrite ? pending.urls : pending.urls.filter { !clashes.contains(UploadPlan.remoteName($0.lastPathComponent).lowercased()) }
        if !urls.isEmpty { transfers.enqueueUploads(urls, to: pending.directory) }
    }

    // MARK: File operations

    func beginNewFolder() {
        newFolderName = String(localized: "새 폴더")
        isCreatingFolder = true
    }

    func createFolder(named rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard isValidName(name) else { return }
        let target = RemotePath.join(path, UploadPlan.remoteName(name))
        await run(String(localized: "폴더를 만드는 중…")) { try $0.makeDirectory(target) }
        await refresh()
        selection = [target]
        anchor = target
    }

    func beginRename(_ item: FTPItem) {
        renameText = item.name
        pendingRename = item
    }

    func rename(_ item: FTPItem, to newName: String) async {
        pendingRename = nil
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard isValidName(name), name != item.name else { return }
        let target = RemotePath.join(RemotePath.parent(of: item.path), UploadPlan.remoteName(name))
        await run(String(localized: "이름을 바꾸는 중…")) { try $0.rename(item.path, to: target) }
        await refresh()
        selection = [target]
        anchor = target
    }

    func delete(_ targets: [FTPItem]) async {
        pendingDelete = nil
        guard !targets.isEmpty else { return }
        await run(String(localized: "삭제하는 중…")) { connection in
            for item in targets { try connection.deleteRecursively(item) }
        }
        await refresh()
    }

    func copyPath(_ items: [FTPItem]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
    }

    private func isValidName(_ name: String) -> Bool {
        if name.isEmpty || name == "." || name == ".." || name.contains("/") {
            errorMessage = String(localized: "‘\(name)’은(는) 쓸 수 없는 이름이에요.")
            return false
        }
        return true
    }

    private func run(_ message: String, _ work: @escaping (FTPConnection) throws -> Void) async {
        busyMessage = message
        defer { busyMessage = nil }
        do {
            try await session.perform(work)
        } catch {
            noteFailure(error)
            errorMessage = error.localizedDescription
        }
    }
}
