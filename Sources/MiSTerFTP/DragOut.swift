import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FTPKit

/// Drags rows out of the file list into Finder or another app.
///
/// The rows stay plain SwiftUI, so clicks, menus and hovers work as before. This
/// watches the mouse: a press on a row that moves becomes an AppKit drag of file
/// promises. When the drop lands, the receiving app names the destination and a
/// normal download starts there, in the transfer tray.
@MainActor
final class DragOutController: NSObject {
    weak var browser: BrowserModel?
    /// True while a drag from the list is under way, so the list does not offer to upload it.
    private(set) var isDragging = false

    private let rows = NSHashTable<DragOutRowView>.weakObjects()
    private var monitor: Any?
    private var press: Press?

    private struct Press {
        let item: FTPItem
        let window: NSWindow
        let location: NSPoint
        let modifiers: NSEvent.ModifierFlags
    }

    /// How far the pointer moves with the button down before a press becomes a drag.
    private static let threshold: CGFloat = 4

    fileprivate func add(_ row: DragOutRowView) {
        rows.add(row)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return used ? nil : event
        }
    }

    fileprivate func remove(_ row: DragOutRowView) {
        rows.remove(row)
        if rows.allObjects.isEmpty { stop() }
    }

    /// Stops watching the mouse. The browser calls this when it closes.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        press = nil
    }

    /// Turns a press on a row that moves into a drag. Returns true when it used the event.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            press = nil
            // Control-click opens the context menu, and a window behind a sheet or panel takes no drags.
            guard !event.modifierFlags.contains(.control), NSApp.modalWindow == nil,
                  let window = event.window, window.attachedSheet == nil,
                  let row = hitRow(at: event.locationInWindow, in: window) else { return false }
            press = Press(item: row.item, window: window, location: event.locationInWindow, modifiers: event.modifierFlags)
            return false
        case .leftMouseDragged:
            guard let press, event.window === press.window else { return false }
            let dx = event.locationInWindow.x - press.location.x
            let dy = event.locationInWindow.y - press.location.y
            guard dx * dx + dy * dy >= Self.threshold * Self.threshold else { return false }
            self.press = nil
            return beginDrag(press, event: event)
        default:
            press = nil
            return false
        }
    }

    /// The row under the pointer. Rows scrolled out of the list lie outside their visible rect.
    private func hitRow(at location: NSPoint, in window: NSWindow) -> DragOutRowView? {
        rows.allObjects.first { row in
            row.window === window && row.visibleRect.contains(row.convert(location, from: nil))
        }
    }

    private func beginDrag(_ press: Press, event: NSEvent) -> Bool {
        guard let browser, let view = press.window.contentView else { return false }
        let items = browser.dragTargets(for: press.item, modifiers: press.modifiers)
        guard !items.isEmpty else { return false }
        let pointer = view.convert(event.locationInWindow, from: nil)
        let draggingItems = items.enumerated().map { (index, item) -> NSDraggingItem in
            let type = Self.fileType(for: item)
            let promise = RemoteFilePromise(item: item, browser: browser)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: promise)
            // The provider holds its delegate weakly; this keeps it until the drop is answered.
            provider.userInfo = promise
            let draggingItem = NSDraggingItem(pasteboardWriter: provider)
            // A small stack under the pointer. AppKit shows the item count.
            let offset = CGFloat(min(index, 3)) * 3
            let frame = NSRect(x: pointer.x - 16 + offset, y: pointer.y - 16 + offset, width: 32, height: 32)
            draggingItem.setDraggingFrame(frame, contents: NSWorkspace.shared.icon(for: type))
            return draggingItem
        }
        view.beginDraggingSession(with: draggingItems, event: event, source: self)
        return true
    }

    private static func fileType(for item: FTPItem) -> UTType {
        if item.isDirectory { return .folder }
        let ext = (item.name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .data }
        return type
    }
}

extension DragOutController: NSDraggingSource {
    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Only other apps take the files. Inside this app the drop would mean nothing.
        context == .outsideApplication ? .copy : []
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        MainActor.assumeIsolated { self.isDragging = true }
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { self.isDragging = false }
    }
}

/// Answers one promised file: downloads the item to where the drop landed.
private final class RemoteFilePromise: NSObject, NSFilePromiseProviderDelegate {
    let item: FTPItem
    private weak var browser: BrowserModel?

    init(item: FTPItem, browser: BrowserModel) {
        self.item = item
        self.browser = browser
        super.init()
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        item.name
    }

    /// The receiving app waits on `completionHandler`, so it runs when the download ends.
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        MainActor.assumeIsolated {
            guard let browser = self.browser else {
                completionHandler(CocoaError(.userCancelled))
                return
            }
            browser.downloadDropped(self.item, to: url) { state in
                completionHandler(Self.error(for: state))
            }
        }
    }

    /// Writing only queues a download, so the request can come on the main queue.
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }

    private static func error(for state: TransferJob.State) -> Error? {
        switch state {
        case .done: return nil
        case .failed(let message): return CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: message])
        default: return CocoaError(.userCancelled)
        }
    }
}

/// Marks a file row as a place where a drag out can start. It sits behind the row.
struct DragOutRow: NSViewRepresentable {
    let item: FTPItem
    let controller: DragOutController

    func makeNSView(context: Context) -> DragOutRowView {
        let view = DragOutRowView(item: item)
        view.controller = controller
        return view
    }

    func updateNSView(_ view: DragOutRowView, context: Context) {
        view.item = item
        view.controller = controller
    }
}

final class DragOutRowView: NSView {
    fileprivate(set) var item: FTPItem
    weak var controller: DragOutController? {
        didSet {
            guard controller !== oldValue, window != nil else { return }
            oldValue?.remove(self)
            controller?.add(self)
        }
    }

    init(item: FTPItem) {
        self.item = item
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Clicks, hovers and menus belong to the SwiftUI row in front.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { controller?.remove(self) } else { controller?.add(self) }
    }
}
