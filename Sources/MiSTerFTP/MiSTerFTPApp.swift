import SwiftUI
import FTPKit

@main
struct MiSTerFTPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("MiSTer FTP", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 600)
                .preferredColorScheme(.dark)
                .tint(Theme.amber)
                .onAppear { appDelegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 740)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The design is dark only; alerts and file panels should match it.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model, model.transfers.isBusy else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = String(localized: "전송 중인 항목이 있어요")
            alert.informativeText = String(localized: "지금 종료하면 진행 중인 전송이 멈추고, 올리던 파일은 MiSTer에 반쯤 남을 수 있어요.")
            alert.addButton(withTitle: String(localized: "계속 전송"))
            alert.addButton(withTitle: String(localized: "종료"))
            alert.buttons.last?.hasDestructiveAction = true
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.disconnect() }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            switch model.phase {
            case .discovering:
                DiscoveryView()
                    .transition(.opacity)
            case .problem(let problem):
                ConnectView(problem: problem)
                    .transition(.opacity)
            case .connected:
                if let browser = model.browser {
                    BrowserView(browser: browser)
                        .transition(.opacity.combined(with: .scale(scale: 0.995)))
                }
            }
        }
        .animation(.easeOut(duration: 0.28), value: model.phase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.phase == .connected ? Theme.window : Theme.discovery)
        .ignoresSafeArea()
        .background(WindowConfigurator())
        .overlay(alignment: .topTrailing) {
            // Screens without a sidebar show a new version here instead.
            if model.phase != .connected, let offer = model.updates.bannerOffer, !model.updates.showSheet {
                // In the title bar row, level with the window buttons.
                UpdatePill(offer: offer) { model.updates.showSheet = true }
                    .padding(.top, 12)
                    .padding(.trailing, 16)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
                .environment(model)
        }
        .sheet(isPresented: Bindable(model.updates).showSheet) {
            UpdateSheet()
                .environment(model)
        }
        .alert("전송 중인 항목이 있어요", isPresented: $model.confirmRediscover) {
            Button("취소하고 다시 찾기", role: .destructive) { model.startDiscovery() }
            Button("계속 전송", role: .cancel) {}
        } message: {
            Text("MiSTer를 다시 찾으면 진행 중인 전송이 멈춰요.")
        }
        .task {
            model.start()
            #if DEBUG
            DebugHarness.runIfRequested(model: model)
            #endif
        }
    }
}

/// Makes the title bar transparent and 52 pt tall, so the traffic lights sit
/// in the middle of the app's own header row.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ConfiguringView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfiguringView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = NSColor(Theme.discovery)
            if window.toolbar == nil {
                let toolbar = NSToolbar(identifier: "MiSTerFTP.header")
                window.toolbar = toolbar
            }
            window.toolbarStyle = .unified
            window.isMovableByWindowBackground = false
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("업데이트 확인…") { model.updates.checkNow() }
        }
        CommandGroup(replacing: .newItem) {
            Button("올리기…") { model.browser?.uploadWithPanel() }
                .keyboardShortcut("u")
                .disabled(model.browser == nil)
            Button("선택 항목 받기") { if let b = model.browser { b.download(b.selectedItems) } }
                .keyboardShortcut("d")
                .disabled(model.browser?.selection.isEmpty ?? true)
            Divider()
            Button("새 폴더") { model.browser?.beginNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.browser == nil)
            Button("이름 바꾸기…") {
                if let b = model.browser, let item = b.selectedItems.first { b.beginRename(item) }
            }
            .keyboardShortcut("e")
            .disabled(model.browser?.selection.count != 1)
            Button("삭제…") { if let b = model.browser { b.pendingDelete = b.selectedItems } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.browser?.selection.isEmpty ?? true)
            Divider()
            Button("MiSTer 다시 찾기") { model.requestRediscover() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("주소로 연결…") { model.showManualConnect() }
                .keyboardShortcut("k")
        }
        CommandGroup(after: .sidebar) {
            Button("새로 고침") { Task { await model.browser?.refresh() } }
                .keyboardShortcut("r")
                .disabled(model.browser == nil)
            Button(model.settings.showHidden ? "숨김 파일 가리기" : "숨김 파일 보기") {
                model.settings.showHidden.toggle()
                model.browser?.rebuild()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            Divider()
            Button("뒤로") { Task { await model.browser?.goBack() } }
                .keyboardShortcut("[")
                .disabled(!(model.browser?.canGoBack ?? false))
            Button("앞으로") { Task { await model.browser?.goForward() } }
                .keyboardShortcut("]")
                .disabled(!(model.browser?.canGoForward ?? false))
            Button("상위 폴더") { Task { await model.browser?.goUp() } }
                .keyboardShortcut(.upArrow)
                .disabled(!(model.browser?.canGoUp ?? false))
        }
        CommandGroup(replacing: .appSettings) {
            Button("설정…") { model.showSettings = true }
                .keyboardShortcut(",")
        }
    }
}
