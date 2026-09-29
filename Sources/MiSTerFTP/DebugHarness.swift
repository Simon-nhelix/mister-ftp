#if DEBUG
import AppKit
import SwiftUI
import FTPKit

/// Debug builds only. Drives the UI through its main states and saves window
/// snapshots, so the design can be checked without screen-recording permission.
///
///   MISTERFTP_SNAPSHOT_DIR=/path  where PNG files go
///   MISTERFTP_DEMO=1              run the scripted tour, then quit
///
/// The tour writes only under /tmp on the MiSTer (RAM) and removes it again.
@MainActor
enum DebugHarness {
    static let environment = ProcessInfo.processInfo.environment
    static var snapshotDirectory: URL? { environment["MISTERFTP_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) } }

    static func capture(_ name: String) {
        guard let directory = snapshotDirectory,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        // Sheets and alerts are separate windows.
        if let sheet = window.attachedSheet, let sheetView = sheet.contentView?.superview ?? sheet.contentView,
           let sheetRep = sheetView.bitmapImageRepForCachingDisplay(in: sheetView.bounds) {
            sheetView.cacheDisplay(in: sheetView.bounds, to: sheetRep)
            try? sheetRep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name)-sheet.png"))
        }
        print("snapshot \(name)")
    }

    static func runIfRequested(model: AppModel) {
        switch environment["MISTERFTP_DEMO"] {
        case "1": Task { await tour(model) }
        case "notfound": Task { await notFoundTour(model) }
        default: break
        }
    }

    /// Looks for a server on a port nobody uses, to show the "not found" screen.
    private static func notFoundTour(_ model: AppModel) async {
        let savedPort = model.settings.port
        let savedHost = model.settings.lastHost
        model.settings.port = 2121
        model.settings.lastHost = nil
        model.startDiscovery()
        await sleep(0.6)
        capture("20-searching")
        for _ in 0..<80 where model.phase == .discovering { await sleep(0.1) }
        await sleep(0.5)
        capture("21-not-found")
        print("phase after search: \(model.phase)")
        // Put the real port back: the quiet retry then finds the MiSTer by itself.
        model.settings.port = savedPort
        model.settings.lastHost = savedHost
        for _ in 0..<150 where model.phase != .connected { await sleep(0.1) }
        print("phase after quiet retry: \(model.phase)")
        await sleep(0.8)
        capture("22-reconnected")
        fflush(stdout)
        exit(0)
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func tour(_ model: AppModel) async {
        await sleep(0.35)
        capture("01-discovery")
        for _ in 0..<100 where model.phase != .connected { await sleep(0.1) }
        guard let browser = model.browser else {
            capture("02-problem")
            NSApp.terminate(nil)
            return
        }
        await sleep(0.8)
        capture("02-browser-root")

        // Select a folder, as in the design.
        if let games = browser.visibleItems.first(where: { $0.name == "games" }) {
            browser.click(games, modifiers: [])
        }
        await sleep(0.3)
        capture("03-selected")

        await browser.open("/media/fat/games/SNES")
        await sleep(0.5)
        capture("04-snes")

        await checkRealInput(browser)

        // Transfers into a scratch folder under /tmp on the MiSTer.
        let remote = "/tmp/misterftp-demo"
        try? await browser.session.perform { try $0.ensureDirectory(remote) }
        await browser.open(remote)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("misterftp-demo")
        try? FileManager.default.removeItem(at: local)
        try? FileManager.default.createDirectory(at: local.appendingPathComponent("240pSuite-PSX"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: local.appendingPathComponent("240p Test Suite.sfc").path, contents: Data(count: 512 * 1024))
        FileManager.default.createFile(atPath: local.appendingPathComponent("240pSuite-PSX/240pSuite.bin").path, contents: Data(count: 36 * 1024 * 1024))
        FileManager.default.createFile(atPath: local.appendingPathComponent("240pSuite-PSX/240pSuite.cue").path, contents: Data("FILE \"240pSuite.bin\" BINARY\n".utf8))
        FileManager.default.createFile(atPath: local.appendingPathComponent("crt_grid.png").path, contents: Data(count: 1_800_000))
        browser.upload([
            local.appendingPathComponent("240p Test Suite.sfc"),
            local.appendingPathComponent("240pSuite-PSX"),
            local.appendingPathComponent("crt_grid.png"),
        ])
        for _ in 0..<40 {
            await sleep(0.05)
            if model.transfers.jobs.contains(where: { $0.state == .running && $0.progress > 0.35 }) { break }
        }
        capture("05-transferring")
        for _ in 0..<200 where model.transfers.isBusy { await sleep(0.1) }
        await sleep(0.8)
        capture("06-transfers-done")

        // Upload the same names again to show the conflict question.
        browser.upload([local.appendingPathComponent("crt_grid.png")])
        await sleep(0.4)
        capture("07-conflict")
        browser.pendingConflict = nil

        // Drop overlay.
        DebugState.shared.forceDropOverlay = true
        await sleep(0.3)
        capture("08-drop")
        DebugState.shared.forceDropOverlay = false

        // Download one file back to show a finished download row.
        if let file = browser.visibleItems.first(where: { $0.name == "crt_grid.png" }) {
            let downloads = FileManager.default.temporaryDirectory.appendingPathComponent("misterftp-demo-downloads")
            try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            browser.download([file], to: downloads)
            for _ in 0..<50 where model.transfers.isBusy { await sleep(0.1) }
            await sleep(0.4)
            capture("09-download")
        }

        // Clean up the MiSTer and the Mac.
        let folder = FTPItem(name: "misterftp-demo", path: remote, kind: .directory, size: nil, modified: nil)
        try? await browser.session.perform { try $0.deleteRecursively(folder) }
        try? FileManager.default.removeItem(at: local)
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("misterftp-demo-downloads"))
        let leftover = try? await browser.session.perform { try $0.stat(remote) }
        print("cleanup: remote folder \(leftover == nil ? "removed" : "still exists")")

        model.showManualConnect()
        await sleep(0.5)
        capture("10-manual")
        model.showSettings = true
        await sleep(0.5)
        capture("11-settings")
        model.showSettings = false
        await sleep(0.6)
        fflush(stdout)
        exit(0)
    }
}

extension DebugHarness {
    /// Sends real mouse and key events through the window, so the gesture and
    /// focus code paths run exactly as they do for a person.
    static func checkRealInput(_ browser: BrowserModel) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<20 where NSApp.keyWindow == nil { await sleep(0.1) }
        print("app active=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow != nil)"); fflush(stdout)

        // Row n of the file list, in top-left window coordinates.
        func rowPoint(_ index: Int) -> CGPoint {
            let top: CGFloat = 52 + 30 + 6 + 16
            let step: CGFloat = 33
            return CGPoint(x: 401, y: top + step * CGFloat(index))
        }
        func check(_ label: String, _ ok: Bool) {
            let names = browser.visibleItems.filter { browser.selection.contains($0.path) }.map(\.name)
            print("input check \(label): \(ok ? "PASS" : "FAIL")  selection=\(names) first responder=\(String(describing: NSApp.keyWindow?.firstResponder.map { type(of: $0) }))")
            fflush(stdout)
        }

        let items = browser.visibleItems
        guard items.count > 9 else { return }

        click(window, at: rowPoint(2))
        await sleep(0.8)
        check("single click selects row", browser.selection == [items[2].path])

        click(window, at: rowPoint(5), modifiers: .command)
        await sleep(0.8)
        check("command-click adds row", browser.selection == [items[2].path, items[5].path])

        click(window, at: rowPoint(8), modifiers: .shift)
        await sleep(0.8)
        check("shift-click selects range", browser.selection.count == 4)

        click(window, at: rowPoint(1))
        await sleep(0.8)
        key(window, code: 125, characters: "\u{F701}")  // down arrow
        await sleep(0.8)
        check("down arrow moves selection", browser.selection == [items[2].path])
        key(window, code: 126, characters: "\u{F700}")  // up arrow
        await sleep(0.8)
        check("up arrow moves selection", browser.selection == [items[1].path])

        // Double-click the first folder opens it; the back button returns.
        if let folderIndex = items.firstIndex(where: \.isDirectory) {
            let folder = items[folderIndex]
            click(window, at: rowPoint(folderIndex), count: 2)
            for _ in 0..<30 where browser.path != folder.path { await sleep(0.1) }
            check("double-click opens folder", browser.path == folder.path)
            capture("04b-opened-by-double-click")
            click(window, at: CGPoint(x: 259, y: 26))  // back button
            for _ in 0..<30 where browser.path == folder.path { await sleep(0.1) }
            check("back button returns", browser.path == RemotePath.parent(of: folder.path))
        }

        // Return opens the selected folder.
        await sleep(0.3)
        if let folderIndex = browser.visibleItems.firstIndex(where: \.isDirectory) {
            let folder = browser.visibleItems[folderIndex]
            click(window, at: rowPoint(folderIndex))
            await sleep(0.8)
            key(window, code: 36, characters: "\r")
            for _ in 0..<30 where browser.path != folder.path { await sleep(0.1) }
            check("return opens folder", browser.path == folder.path)
            await browser.goBack()
        }
    }

    private static func click(_ window: NSWindow, at point: CGPoint, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        guard let height = window.contentView?.bounds.height else { return }
        let location = NSPoint(x: point.x, y: height - point.y)
        for clickCount in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0
                ) {
                    // Queue the events: a mouse-down can start a tracking loop that
                    // waits for the matching mouse-up from the event queue.
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
    }

    private static func key(_ window: NSWindow, code: UInt16, characters: String) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }
}

@MainActor @Observable
final class DebugState {
    static let shared = DebugState()
    var forceDropOverlay = false
}
#endif
