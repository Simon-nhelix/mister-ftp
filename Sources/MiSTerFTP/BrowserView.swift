import SwiftUI
import UniformTypeIdentifiers
import FTPKit

/// Screens 2 and 3 of the design: the connected file browser.
struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @Bindable var browser: BrowserModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(browser: browser)
            Rectangle().fill(Theme.line).frame(width: 1)
            VStack(spacing: 0) {
                BrowserHeader(browser: browser)
                ColumnHeader(browser: browser)
                FileListView(browser: browser)
                if model.transfers.hasJobs {
                    TransferTray(queue: model.transfers)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)
            .background(Theme.window)
        }
        .animation(.easeOut(duration: 0.22), value: model.transfers.hasJobs)
        // Dialog buttons read their input when they are pressed, not later in a Task:
        // closing the dialog clears the pending state before a Task gets to run.
        .alert("새 폴더", isPresented: $browser.isCreatingFolder) {
            TextField("폴더 이름", text: $browser.newFolderName)
            Button("만들기") {
                let name = browser.newFolderName
                Task { await browser.createFolder(named: name) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("\(Places.displayName(for: browser.path)) 폴더 안에 만들어요.")
        }
        .alert("이름 바꾸기", isPresented: Binding(
            get: { browser.pendingRename != nil },
            set: { if !$0 { browser.pendingRename = nil } }
        ), presenting: browser.pendingRename) { item in
            TextField("새 이름", text: $browser.renameText)
            Button("바꾸기") {
                let name = browser.renameText
                Task { await browser.rename(item, to: name) }
            }
            Button("취소", role: .cancel) {}
        } message: { item in
            Text(String(localized: "‘\(item.name)’의 새 이름을 입력하세요."))
        }
        .alert(deleteTitle, isPresented: Binding(
            get: { browser.pendingDelete != nil },
            set: { if !$0 { browser.pendingDelete = nil } }
        ), presenting: browser.pendingDelete) { items in
            Button("삭제", role: .destructive) { Task { await browser.delete(items) } }
            Button("취소", role: .cancel) {}
        } message: { _ in
            Text("MiSTer에서 바로 지워지고 되돌릴 수 없어요. 폴더는 안에 있는 파일도 함께 지워져요.")
        }
        .alert(conflictTitle, isPresented: Binding(
            get: { browser.pendingConflict != nil },
            set: { if !$0 { browser.pendingConflict = nil } }
        ), presenting: browser.pendingConflict) { pending in
            Button("덮어쓰기", role: .destructive) { browser.resolveConflict(pending, overwrite: true) }
            Button("건너뛰기") { browser.resolveConflict(pending, overwrite: false) }
            Button("취소", role: .cancel) {}
        } message: { _ in
            Text(conflictMessage)
        }
    }

    private var deleteTitle: String {
        guard let items = browser.pendingDelete else { return "" }
        if items.count == 1 { return String(localized: "‘\(items[0].name)’을(를) 삭제할까요?") }
        return String(localized: "항목 \(items.count)개를 삭제할까요?")
    }

    private var conflictTitle: String {
        String(localized: "같은 이름의 항목이 \(browser.pendingConflict?.clashes.count ?? 0)개 있어요")
    }

    private var conflictMessage: String {
        guard let clashes = browser.pendingConflict?.clashes else { return "" }
        var names = clashes.prefix(3).map { String(localized: "‘\($0)’", comment: "A file name in quotes") }.joined(separator: ", ")
        if clashes.count > 3 { names += String(localized: " 외 \(clashes.count - 3)개") }
        return String(localized: "\(names)이(가) 이미 있어요. 덮어쓰면 폴더는 합쳐지고 같은 이름의 파일은 새 파일로 바뀌어요.")
    }
}

// MARK: Sidebar

private struct SidebarView: View {
    @Environment(AppModel.self) private var model
    let browser: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PixelWordmark(unit: 3)
                .padding(.horizontal, 8)
                .padding(.top, 6)

            if let device = model.device {
                DeviceCard(device: device, healthy: browser.connectionHealthy)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("저장소", places: browser.storages)
                    if !browser.shortcuts.isEmpty {
                        section("바로가기", places: browser.shortcuts)
                    }
                }
            }
            .scrollIndicators(.never)

            if let offer = model.updates.bannerOffer, !model.updates.showSheet {
                UpdateBanner(offer: offer) { model.updates.showSheet = true }
                    .transition(.opacity)
            }

            HStack(spacing: 8) {
                Button {
                    model.requestRediscover()
                } label: {
                    Label("다시 찾기", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PanelButtonStyle())
                .help("같은 네트워크에서 MiSTer를 다시 찾아요 (⇧⌘R)")

                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(IconButtonStyle(size: 32, fill: Theme.panel))
                .help("설정 (⌘,)")
                .accessibilityLabel("설정")
            }
        }
        .padding(.top, 58)
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(width: 232)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { DragStrip() }
    }

    private var currentPlace: String? {
        let path = browser.path
        let all = browser.shortcuts + browser.storages
        return all
            .filter { path == $0.path || path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }?
            .path
    }

    private func section(_ title: LocalizedStringKey, places: [Place]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach(places) { place in
                SidebarRow(place: place, selected: place.path == currentPlace) {
                    Task { await browser.open(place.path) }
                }
            }
        }
    }
}

private struct DeviceCard: View {
    let device: DeviceInfo
    let healthy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.amberWell)
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: "cpu").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.amber))
                VStack(alignment: .leading, spacing: 2) {
                    Text("MiSTer")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(device.address)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.text2)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(healthy ? Theme.green : Theme.amber)
                    .frame(width: 7, height: 7)
                    .background(Circle().fill((healthy ? Theme.green : Theme.amber).opacity(0.16)).frame(width: 13, height: 13))
                if healthy {
                    Text("연결됨").foregroundStyle(Theme.greenText)
                    Text("· \(device.serverName) · \(device.username)").foregroundStyle(Theme.text3)
                } else {
                    Text("다시 연결하는 중…").foregroundStyle(Theme.amber)
                }
            }
            .font(.system(size: 12))
            .animation(.easeOut(duration: 0.2), value: healthy)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }
}

private struct SidebarRow: View {
    let place: Place
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: place.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Theme.amber : Theme.text3)
                    .frame(width: 18)
                Text(place.title)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.text : Theme.textSoft)
                Spacer(minLength: 4)
                if let detail = place.detail {
                    Text(detail)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Theme.navSelected : (hovering ? Theme.hover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: Header

private struct BrowserHeader: View {
    @Bindable var browser: BrowserModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                Button { Task { await browser.goBack() } } label: {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(size: 28, bordered: false))
                .disabled(!browser.canGoBack)
                .help("뒤로 (⌘[)")
                .accessibilityLabel("뒤로")
                Button { Task { await browser.goForward() } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(size: 28, bordered: false))
                .disabled(!browser.canGoForward)
                .help("앞으로 (⌘])")
                .accessibilityLabel("앞으로")
            }

            Breadcrumbs(browser: browser)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text3)
                TextField("", text: $browser.filter, prompt: Text("이 폴더에서 찾기").foregroundStyle(Theme.text3))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .focused($searchFocused)
                    .onExitCommand { browser.filter = ""; searchFocused = false }
                if !browser.filter.isEmpty {
                    Button { browser.filter = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("검색어 지우기")
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 210, height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(searchFocused ? Theme.amber.opacity(0.8) : Theme.fieldBorder))
            .background(Button("") { searchFocused = true }.keyboardShortcut("f").hidden())

            Button { browser.beginNewFolder() } label: {
                Image(systemName: "folder.badge.plus").font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(IconButtonStyle(size: 30))
            .help("새 폴더 (⇧⌘N)")
            .accessibilityLabel("새 폴더")

            Button { browser.download(browser.selectedItems) } label: {
                Label {
                    Text("받기")
                } icon: {
                    Image(systemName: "square.and.arrow.down").foregroundStyle(Theme.cyan)
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(browser.selection.isEmpty)
            .help("선택한 항목을 Mac의 다운로드 폴더로 받아요 (⌘D)")

            Button { browser.uploadWithPanel() } label: {
                Label("올리기", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryButtonStyle())
            .help("Mac의 파일을 이 폴더로 올려요 (⌘U). 파일을 창에 끌어다 놓아도 돼요.")
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(height: 52)
        .background(Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

private struct Breadcrumbs: View {
    let browser: BrowserModel

    private struct Crumb: Hashable {
        let title: String
        let path: String
    }

    private var crumbs: [Crumb] {
        let root = Places.root(of: browser.path)
        var list = [Crumb(title: Places.displayName(for: root), path: root)]
        var current = root
        let rest = RemotePath.components(browser.path).dropFirst(RemotePath.components(root).count)
        for part in rest {
            current = RemotePath.join(current, part)
            list.append(Crumb(title: part, path: current))
        }
        if list.count > 4 {
            list = [list[0], Crumb(title: "…", path: list[list.count - 3].path)] + list.suffix(2)
        }
        return list
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(crumbs.enumerated()), id: \.element) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x5E6268))
                }
                if index == crumbs.count - 1 {
                    Text(crumb.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .layoutPriority(1)
                } else {
                    Button(crumb.title) { Task { await browser.open(crumb.path) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
            }
            Text(detail)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
                .padding(.leading, 4)
            if let busy = browser.busyMessage {
                ProgressView().controlSize(.mini)
                Text(busy).font(.system(size: 12)).foregroundStyle(Theme.text2)
            } else if browser.isLoading {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private var detail: String {
        let count = String(localized: "\(browser.visibleItems.count)개 항목")
        let selected = browser.selection.isEmpty ? "" : String(localized: " · \(browser.selection.count)개 선택")
        let root = Places.root(of: browser.path)
        return (browser.path == root && root != "/" ? "\(root) · " : "") + count + selected
    }
}

private struct ColumnHeader: View {
    let browser: BrowserModel

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 16)
            sortButton("이름", key: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortButton("크기", key: .size)
                .frame(width: 96, alignment: .trailing)
            sortButton("수정한 날짜", key: .date)
                .frame(width: 176, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.lineSoft).frame(height: 1) }
    }

    private func sortButton(_ title: LocalizedStringKey, key: SortKey) -> some View {
        Button { browser.setSort(key) } label: {
            HStack(spacing: 4) {
                Text(title)
                if browser.sortKey == key {
                    Image(systemName: browser.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(browser.sortKey == key ? Theme.text2 : Theme.text3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: File list

private struct FileListView: View {
    @Environment(AppModel.self) private var model
    @Bindable var browser: BrowserModel
    @FocusState private var focused: Bool
    @State private var dropTargeted = false
    @State private var dropCount = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(browser.visibleItems) { item in
                        FileRow(item: item, selected: browser.selection.contains(item.path))
                            .id(item.path)
                            .onTapGesture { click(item) }
                            .contextMenu { itemMenu(item) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .opacity(showDropOverlay ? 0.3 : 1)
            }
            .scrollContentBackground(.hidden)
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        browser.selection = []
                        focused = true
                    }
            )
            .contextMenu { backgroundMenu }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
                if let target = browser.moveSelection(by: press.key == .upArrow ? -1 : 1, extend: press.modifiers.contains(.shift)) {
                    proxy.scrollTo(target)
                }
                return .handled
            }
            .onKeyPress(.return) {
                guard browser.selection.count == 1, let item = browser.selectedItems.first else { return .ignored }
                Task { await browser.activate(item) }
                return .handled
            }
            .onKeyPress(phases: .down) { press in
                if press.modifiers == .command, press.characters == "a" {
                    browser.selectAll()
                    return .handled
                }
                return .ignored
            }
        }
        .overlay { emptyState.allowsHitTesting(false) }
        .overlay(alignment: .top) { errorBanner }
        .overlay {
            if showDropOverlay {
                DropOverlay(folder: Places.displayName(for: browser.path), count: dropTargeted ? dropCount : 3)
            }
        }
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(browser: browser, targeted: $dropTargeted, count: $dropCount))
        .onAppear { focused = true }
    }

    private var showDropOverlay: Bool {
        #if DEBUG
        if DebugState.shared.forceDropOverlay { return true }
        #endif
        return dropTargeted
    }

    private func click(_ item: FTPItem) {
        let event = NSApp.currentEvent
        focused = true
        if (event?.clickCount ?? 1) >= 2 {
            Task { await browser.activate(item) }
        } else {
            browser.click(item, modifiers: event?.modifierFlags ?? [])
        }
    }

    private func targets(for item: FTPItem) -> [FTPItem] {
        browser.selection.contains(item.path) ? browser.selectedItems : [item]
    }

    @ViewBuilder private func itemMenu(_ item: FTPItem) -> some View {
        let targets = targets(for: item)
        let many = targets.count > 1
        if !many && item.kind != .file {
            Button("열기") { Task { await browser.open(item.path) } }
            Divider()
        }
        Button(many ? String(localized: "항목 \(targets.count)개 받기") : String(localized: "받기")) { browser.download(targets) }
        Button("다른 위치에 받기…") { browser.downloadWithPanel(targets) }
        Divider()
        if !many {
            Button("이름 바꾸기…") { browser.beginRename(item) }
        }
        Button("경로 복사") { browser.copyPath(targets) }
        Divider()
        Button(many ? String(localized: "항목 \(targets.count)개 삭제…") : String(localized: "삭제…"), role: .destructive) {
            browser.pendingDelete = targets
        }
    }

    @ViewBuilder private var backgroundMenu: some View {
        Button("새 폴더…") { browser.beginNewFolder() }
        Button("올리기…") { browser.uploadWithPanel() }
        Divider()
        Button("새로 고침") { Task { await browser.refresh() } }
        Button(model.settings.showHidden ? "숨김 파일 가리기" : "숨김 파일 보기") {
            model.settings.showHidden.toggle()
            browser.rebuild()
        }
    }

    @ViewBuilder private var errorBanner: some View {
            if let error = browser.errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("닫기") { browser.errorMessage = nil }
                        .buttonStyle(QuietButtonStyle(height: 22))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hex: 0x2A1A18)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.red.opacity(0.35)))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
    }

    @ViewBuilder private var emptyState: some View {
            if browser.visibleItems.isEmpty && !browser.isLoading && !showDropOverlay {
                VStack(spacing: 10) {
                    Image(systemName: browser.filter.isEmpty ? "tray" : "magnifyingglass")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Theme.text3)
                    Text(browser.filter.isEmpty ? String(localized: "이 폴더는 비어 있어요") : String(localized: "‘\(browser.filter)’와 맞는 항목이 없어요"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textSoft)
                    if browser.filter.isEmpty {
                        Text("Mac에서 파일을 끌어다 놓으면 여기로 올라가요.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text3)
                    }
                }
            }
    }
}

private struct FileRow: View {
    let item: FTPItem
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(item: item)
                .frame(width: 16)
            Text(item.name)
                .font(.system(size: 13))
                .foregroundStyle(item.isHidden ? Theme.text3 : Theme.textRow)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.kind == .file ? Format.bytes(item.size ?? 0) : "—")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.text2)
                .frame(width: 96, alignment: .trailing)
            Text(Format.date(item.modified))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.text2)
                .frame(width: 176, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Theme.rowSelected : (hovering ? Theme.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct FileIcon: View {
    let item: FTPItem

    var body: some View {
        switch item.kind {
        case .directory:
            ZStack {
                Image(systemName: "folder.fill").foregroundStyle(Theme.amber.opacity(0.2))
                Image(systemName: "folder").foregroundStyle(Theme.amber)
            }
            .font(.system(size: 13, weight: .medium))
        case .link:
            Image(systemName: "arrowshape.turn.up.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.fileIcon)
        case .file:
            Image(systemName: Self.symbol(for: item.name))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.fileIcon)
        }
    }

    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "bmp", "gif", "webp", "tga":
            return "photo"
        case "zip", "7z", "rar", "gz", "tar", "tgz":
            return "doc.zipper"
        case "chd", "cue", "bin", "iso", "img", "vhd", "cdi", "gdi", "mds", "mdf", "ccd", "toc":
            return "opticaldisc"
        case "rbf":
            return "cpu"
        case "mra", "mgl":
            return "arcade.stick"
        case "sh":
            return "terminal"
        case "ini", "txt", "cfg", "json", "xml", "log", "csv", "db":
            return "doc.text"
        case "sav", "srm", "eep", "mpk", "ss", "sta", "state":
            return "memorychip"
        case "nes", "fds", "unf", "sfc", "smc", "bs", "gb", "gbc", "gba", "md", "gen", "smd", "sms", "gg", "sg",
             "pce", "sgx", "n64", "z64", "v64", "a26", "a52", "a78", "lnx", "ws", "wsc", "ngp", "ngc", "col",
             "int", "vec", "32x", "rom", "tap", "tzx", "d64", "t64", "prg", "crt", "adf", "hdf", "st", "msa",
             "dsk", "nib", "woz", "2mg", "min", "sv", "pv", "jag", "j64", "neo":
            return "gamecontroller"
        default:
            return "doc"
        }
    }
}

private struct DropOverlay: View {
    let folder: String
    let count: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.window.opacity(0.82))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.amber, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.amber.opacity(0.16))
                    .frame(width: 64, height: 64)
                    .overlay(Image(systemName: "square.and.arrow.up").font(.system(size: 27, weight: .medium)).foregroundStyle(Theme.amber))
                VStack(spacing: 6) {
                    Text("\(folder) 폴더에 올리기")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.text)
                    if count > 0 {
                        Text("항목 \(count)개")
                            .font(Theme.mono(13))
                            .foregroundStyle(Theme.textSoft)
                    }
                }
                Text("놓으면 바로 전송을 시작해요. 같은 이름이 있으면 먼저 물어볼게요.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

private struct FileDropDelegate: DropDelegate {
    let browser: BrowserModel
    @Binding var targeted: Bool
    @Binding var count: Int

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        count = info.itemProviders(for: [.fileURL]).count
        withAnimation(.easeOut(duration: 0.15)) { targeted = true }
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.15)) { targeted = false }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.loadFileURL() { urls.append(url) }
            }
            browser.upload(urls)
        }
        return true
    }
}

private extension NSItemProvider {
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}
