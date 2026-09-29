import SwiftUI
import FTPKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var autoFind = true
    @State private var host = ""
    @State private var port = "21"
    @State private var user = AppSettings.defaultUser
    @State private var password = AppSettings.defaultPassword
    @State private var downloadFolder = URL(fileURLWithPath: NSHomeDirectory())
    @State private var showHidden = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("설정")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.text)

            // "연결" alone is also the Connect button, so this title has its own key.
            group(LocalizedStringResource("settings.connection", defaultValue: "연결", comment: "Settings section title")) {
                Picker("", selection: $autoFind) {
                    Text("자동으로 찾기").tag(true)
                    Text("고정 주소 사용").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if !autoFind {
                    field("주소") {
                        TextField("", text: $host, prompt: Text("192.168.1.11 또는 MiSTer.local"))
                            .font(Theme.mono(13))
                            .fieldStyle()
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    field("사용자") {
                        TextField("", text: $user).font(Theme.mono(13)).fieldStyle()
                    }
                    field("비밀번호") {
                        SecureField("", text: $password).fieldStyle()
                    }
                    field("포트") {
                        TextField("", text: $port).font(Theme.mono(13)).fieldStyle()
                    }
                    .frame(width: 76)
                }
                HStack {
                    Text("MiSTer 기본값은 root / 1, 포트 21이에요.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                    Spacer()
                    Button("기본값으로") {
                        user = AppSettings.defaultUser
                        password = AppSettings.defaultPassword
                        port = "21"
                        autoFind = true
                    }
                    .buttonStyle(QuietButtonStyle(height: 24))
                }
            }

            group("받은 파일 저장 위치") {
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(Theme.cyan)
                    Text(downloadFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textSoft)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("변경…") { chooseFolder() }
                        .buttonStyle(SecondaryButtonStyle(height: 28))
                }
            }

            group("표시") {
                Toggle("숨김 파일 보기 (이름이 .으로 시작하는 파일)", isOn: $showHidden)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSoft)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
            }

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle(height: 32))
                    .keyboardShortcut(.cancelAction)
                Button("저장") { save() }
                    .buttonStyle(PrimaryButtonStyle(height: 32))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
    }

    private func group<Content: View>(_ title: LocalizedStringResource, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
            content()
        }
    }

    private func field<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.text2)
            content()
        }
    }

    private func load() {
        let settings = model.settings
        autoFind = settings.fixedHost.isEmpty
        host = settings.fixedHost
        port = String(settings.port)
        user = settings.username
        password = settings.password
        downloadFolder = settings.downloadFolder
        showHidden = settings.showHidden
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "선택")
        panel.directoryURL = downloadFolder
        if panel.runModal() == .OK, let url = panel.url { downloadFolder = url }
    }

    private func save() {
        guard let portValue = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(portValue) else {
            error = String(localized: "포트는 1부터 65535 사이의 숫자예요.")
            return
        }
        let fixed = autoFind ? "" : host.trimmingCharacters(in: .whitespaces)
        if !autoFind && fixed.isEmpty {
            error = String(localized: "고정 주소를 입력하세요.")
            return
        }
        let settings = model.settings
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        let connectionChanged = settings.fixedHost != fixed || settings.port != portValue
            || settings.username != (trimmedUser.isEmpty ? AppSettings.defaultUser : trimmedUser) || settings.password != password
        settings.fixedHost = fixed
        settings.port = portValue
        settings.username = trimmedUser.isEmpty ? AppSettings.defaultUser : trimmedUser
        settings.setPassword(password.isEmpty ? AppSettings.defaultPassword : password)
        settings.downloadFolder = downloadFolder
        if settings.showHidden != showHidden {
            settings.showHidden = showHidden
            model.browser?.rebuild()
        }
        model.resetForm()
        dismiss()
        if connectionChanged { model.requestRediscover() }
    }
}
