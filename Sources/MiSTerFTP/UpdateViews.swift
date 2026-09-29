import SwiftUI
import UpdateKit

/// "Check for Updates…" and "Update" open this sheet.
struct UpdateSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates = model.updates
        @Bindable var bindable = updates
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(updates))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(subtitle(updates))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let offer = updates.pendingOffer {
                ReleaseNotes(offer: offer)
            }

            status(updates)

            Toggle("자동으로 업데이트 확인", isOn: $bindable.autoCheck)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)

            buttons(updates)
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }

    private func title(_ updates: UpdateModel) -> String {
        switch updates.state {
        case .idle, .checking: return String(localized: "업데이트 확인")
        case .upToDate: return String(localized: "최신 버전을 쓰고 있어요")
        case .available(let offer), .downloading(let offer, _, _), .installing(let offer):
            return String(localized: "새 버전 \(offer.version.description)이 나왔어요")
        case .failed(_, let offer):
            return offer == nil ? String(localized: "업데이트를 확인하지 못했어요") : String(localized: "업데이트하지 못했어요")
        }
    }

    private func subtitle(_ updates: UpdateModel) -> String {
        switch updates.state {
        case .idle, .checking: return String(localized: "GitHub에서 새 버전이 있는지 보고 있어요.")
        case .upToDate: return String(localized: "MiSTer FTP \(updates.currentVersion)")
        default: return String(localized: "지금 쓰는 버전은 \(updates.currentVersion)이에요.")
        }
    }

    @ViewBuilder private func status(_ updates: UpdateModel) -> some View {
        switch updates.state {
        case .idle, .checking:
            HStack(spacing: 10) {
                ArcSpinner(size: 18)
                Text("확인하는 중…").font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
        case .downloading(_, let received, let total):
            VStack(alignment: .leading, spacing: 8) {
                LEDBar(progress: total > 0 ? Double(received) / Double(total) : 0)
                Text(String(localized: "받는 중… \(Format.progress(received, of: max(total, received)))"))
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textSoft)
                    .monospacedDigit()
            }
        case .installing:
            HStack(spacing: 10) {
                ArcSpinner(size: 18)
                Text("설치하고 다시 여는 중…").font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
        case .failed(let message, _):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.red)
                .fixedSize(horizontal: false, vertical: true)
        case .available where updates.isBusy():
            Label("전송이 끝나면 업데이트할 수 있어요.", systemImage: "arrow.up.arrow.down")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
        case .available, .upToDate:
            EmptyView()
        }
    }

    @ViewBuilder private func buttons(_ updates: UpdateModel) -> some View {
        HStack(spacing: 10) {
            switch updates.state {
            case .idle, .checking:
                Spacer()
                Button("닫기") { updates.later() }
                    .buttonStyle(SecondaryButtonStyle(height: 32))
                    .keyboardShortcut(.cancelAction)
            case .upToDate:
                Spacer()
                Button("확인") { updates.later() }
                    .buttonStyle(PrimaryButtonStyle(height: 32))
                    .keyboardShortcut(.defaultAction)
            case .available(let offer):
                Button("이 버전 건너뛰기") { updates.skip(offer) }
                    .buttonStyle(QuietButtonStyle(height: 32))
                Spacer()
                Button("나중에") { updates.later() }
                    .buttonStyle(SecondaryButtonStyle(height: 32))
                    .keyboardShortcut(.cancelAction)
                Button("업데이트") { updates.install(offer) }
                    .buttonStyle(PrimaryButtonStyle(height: 32))
                    .keyboardShortcut(.defaultAction)
                    .disabled(updates.isBusy())
            case .downloading:
                Spacer()
                Button("취소") { updates.cancelDownload() }
                    .buttonStyle(SecondaryButtonStyle(height: 32))
                    .keyboardShortcut(.cancelAction)
            case .installing:
                Spacer()
            case .failed(_, let offer):
                Button("릴리스 페이지 열기") { updates.openReleasePage() }
                    .buttonStyle(QuietButtonStyle(height: 32))
                Spacer()
                Button("닫기") { updates.later() }
                    .buttonStyle(SecondaryButtonStyle(height: 32))
                    .keyboardShortcut(.cancelAction)
                Button("다시 시도") {
                    if let offer { updates.install(offer) } else { updates.checkNow() }
                }
                .buttonStyle(PrimaryButtonStyle(height: 32))
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Release notes from GitHub (Markdown, shown inline).
private struct ReleaseNotes: View {
    let offer: UpdateOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("새로운 점")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
            ScrollView {
                Text(notes)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.textSoft)
                    .tint(Theme.amber)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(height: 170)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
        }
    }

    private var notes: AttributedString {
        guard !offer.notes.isEmpty else { return AttributedString(String(localized: "이 버전에는 설명이 없어요.")) }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: offer.notes, options: options)) ?? AttributedString(offer.notes)
    }
}

/// Sidebar card while a new version waits.
struct UpdateBanner: View {
    let offer: UpdateOffer
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.amberWell)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "arrow.down").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.amber))
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "새 버전 \(offer.version.description)"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("눌러서 업데이트")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.hover : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.amber.opacity(0.35)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(String(localized: "MiSTer FTP \(offer.version.description)로 업데이트해요"))
    }
}

/// Top-right badge on the screens without a sidebar.
struct UpdatePill: View {
    let offer: UpdateOffer
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                Text(String(localized: "새 버전 \(offer.version.description)"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSoft)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.amber.opacity(0.35)))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
