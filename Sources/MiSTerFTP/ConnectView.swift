import SwiftUI
import FTPKit

/// Screen 4 of the design: nothing found, a login problem, or a manual address.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    let problem: ConnectProblem

    var body: some View {
        HStack(alignment: .center, spacing: 72) {
            VStack(alignment: .leading, spacing: 26) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.ledOff))
                    .overlay(Image(systemName: symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(Theme.text2))
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(message)
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !tips.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(tips.enumerated()), id: \.offset) { index, tip in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.amber)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Theme.control))
                                Text(tip)
                                    .font(.system(size: 14))
                                    .lineSpacing(3)
                                    .foregroundStyle(Theme.textSoft)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        model.startDiscovery()
                    } label: {
                        Label("다시 찾기", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 34))

                    if problem == .blocked {
                        Button("시스템 설정 열기") { openLocalNetworkSettings() }
                            .buttonStyle(PrimaryButtonStyle(height: 34))
                    }
                    if keepsSearching {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.mini)
                            Text(problem == .blocked ? "허용하면 바로 다시 찾아요" : "MiSTer가 켜지면 자동으로 연결해요")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text3)
                        }
                        .padding(.leading, 6)
                    }
                }
            }
            .frame(width: 440, alignment: .leading)

            ManualConnectForm(emphasizePassword: isLoginProblem)
        }
        .padding(.horizontal, 72)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.discovery)
        .overlay(alignment: .top) { DragStrip() }
    }

    /// These screens keep searching in the background (see AppModel.scheduleQuietRetry).
    private var keepsSearching: Bool {
        switch problem {
        case .loginFailed: return false
        default: return true
        }
    }

    private var isLoginProblem: Bool {
        if case .loginFailed = problem { return true }
        return false
    }

    private var symbol: String {
        switch problem {
        case .notFound, .noNetwork: return "wifi.slash"
        case .loginFailed: return "lock"
        case .blocked: return "hand.raised"
        case .failed: return "exclamationmark.triangle"
        case .manual: return "network"
        }
    }

    private var title: String {
        switch problem {
        case .notFound: return String(localized: "MiSTer를 찾지 못했어요")
        case .loginFailed: return String(localized: "비밀번호가 필요해요")
        case .blocked: return String(localized: "로컬 네트워크 권한이 필요해요")
        case .noNetwork: return String(localized: "네트워크에 연결되어 있지 않아요")
        case .failed: return String(localized: "연결하지 못했어요")
        case .manual: return String(localized: "주소로 연결하기")
        }
    }

    private var message: String {
        switch problem {
        case .notFound(let scanned, let label):
            return String(localized: "\(label) 네트워크의 주소 \(scanned)개를 모두 확인했지만 MiSTer의 FTP 서버가 응답하지 않았어요.")
        case .loginFailed(let host):
            return String(localized: "\(host)에서 MiSTer를 찾았지만 로그인하지 못했어요. MiSTer의 root 비밀번호를 바꿨다면 오른쪽에 입력하세요.")
        case .blocked:
            return String(localized: "MiSTer를 찾으려면 로컬 네트워크 권한이 필요해요. 허용하면 이 화면에서 자동으로 다시 찾아요.")
        case .noNetwork:
            return String(localized: "Wi-Fi나 이더넷을 연결한 다음 다시 찾기를 누르세요.")
        case .failed(let host, let message):
            return "\(host): \(message)"
        case .manual:
            return String(localized: "MiSTer의 IP 주소를 알고 있다면 직접 입력하세요. 연결에 성공하면 다음부터 이 주소를 먼저 확인해요.")
        }
    }

    private var tips: [String] {
        switch problem {
        case .notFound, .failed:
            return [
                String(localized: "MiSTer가 켜져 있고 랜선이나 Wi-Fi가 연결되어 있는지 확인하세요."),
                String(localized: "이 Mac과 MiSTer는 같은 공유기에 연결되어 있어야 해요."),
                String(localized: "공유기 관리 화면에서 MiSTer의 IP 주소를 찾았다면 오른쪽에 직접 입력하세요."),
            ]
        case .blocked:
            return [
                String(localized: "‘로컬 네트워크의 기기를 찾고 연결’하도록 묻는 창이 떴다면 ‘허용’을 누르세요."),
                String(localized: "창이 없다면 시스템 설정 › 개인정보 보호 및 보안 › 로컬 네트워크에서 MiSTer FTP를 켜세요."),
            ]
        default:
            return []
        }
    }

    private func openLocalNetworkSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}

private struct ManualConnectForm: View {
    @Environment(AppModel.self) private var model
    let emphasizePassword: Bool
    @FocusState private var focus: Field?

    enum Field { case host, port, user, password }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("직접 연결")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("연결에 성공하면 다음부터 이 주소를 먼저 확인해요.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            }

            HStack(alignment: .top, spacing: 12) {
                labeled("주소") {
                    TextField("", text: $model.formHost, prompt: Text("192.168.1.11 또는 MiSTer.local").foregroundStyle(Theme.text3))
                        .font(Theme.mono(13))
                        .focused($focus, equals: .host)
                        .fieldStyle(focused: focus == .host)
                }
                labeled("포트") {
                    TextField("", text: $model.formPort)
                        .font(Theme.mono(13))
                        .focused($focus, equals: .port)
                        .fieldStyle(focused: focus == .port)
                }
                .frame(width: 76)
            }

            HStack(alignment: .top, spacing: 12) {
                labeled("사용자") {
                    TextField("", text: $model.formUser)
                        .font(Theme.mono(13))
                        .focused($focus, equals: .user)
                        .fieldStyle(focused: focus == .user)
                }
                labeled("비밀번호") {
                    SecureField("", text: $model.formPassword)
                        .font(.system(size: 13))
                        .focused($focus, equals: .password)
                        .fieldStyle(focused: focus == .password)
                }
            }

            Text("MiSTer 기본 계정은 root / 1이에요. 바꾼 비밀번호는 키체인에 저장돼요.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)

            if let error = model.formError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await model.connectFromForm() }
            } label: {
                HStack(spacing: 8) {
                    if model.isConnecting { ProgressView().controlSize(.small).tint(Theme.amberInk) }
                    Text(model.isConnecting ? "연결하는 중…" : "연결")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(height: 38))
            .keyboardShortcut(.defaultAction)
            .disabled(model.isConnecting)
        }
        .padding(24)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
        .onAppear {
            focus = emphasizePassword ? .password : (model.formHost.isEmpty ? .host : nil)
        }
    }

    private func labeled<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
            content()
        }
    }
}
