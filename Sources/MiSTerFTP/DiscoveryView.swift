import SwiftUI
import FTPKit

/// Screen 1 of the design: looking for the MiSTer.
struct DiscoveryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.discovery
        HStack(alignment: .center, spacing: 80) {
            VStack(alignment: .leading, spacing: 30) {
                PixelWordmark(unit: 7, dotted: true)

                VStack(alignment: .leading, spacing: 10) {
                    Text(state.found == nil ? "MiSTer를 찾고 있어요" : "MiSTer를 찾았어요")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .contentTransition(.opacity)
                    Text(subtitle(state))
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 14) {
                    StepRow(state: state.nameState, title: "이름으로 찾기", detail: state.nameDetail)
                    StepRow(state: state.sweepState, title: "네트워크 스캔", detail: sweepDetail(state))
                    StepRow(state: state.loginState, title: "FTP 로그인 확인", detail: state.loginDetail)
                }

                HStack(spacing: 10) {
                    Button("주소 직접 입력") { model.showManualConnect() }
                        .buttonStyle(SecondaryButtonStyle(height: 34))
                    Button {
                        model.showSettings = true
                    } label: {
                        Label("설정", systemImage: "slider.horizontal.3")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(QuietButtonStyle(height: 34, horizontalPadding: 12))
                }
            }
            .frame(width: 430, alignment: .leading)

            GridCard(state: state)
        }
        .padding(.horizontal, 72)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.discovery)
        .overlay(alignment: .top) { DragStrip() }
    }

    private func subtitle(_ state: DiscoveryState) -> String {
        if let found = state.found {
            return String(localized: "\(found.address)에 연결하는 중이에요.")
        }
        return String(localized: "같은 네트워크에 있는 MiSTer의 FTP 서버를 찾으면 바로 연결할게요. 따로 설정할 것은 없어요.")
    }

    private func sweepDetail(_ state: DiscoveryState) -> String {
        if state.sweepState == .skipped { return String(localized: "\(state.gridLabel) · 먼저 찾아서 멈췄어요") }
        guard state.sweepTotal > 0 else { return state.hasGrid ? String(localized: "\(state.gridLabel) · 준비 중") : state.gridLabel }
        return String(localized: "\(state.gridLabel) · \(state.sweepTotal)개 중 \(state.sweepDone)개")
    }
}

private struct StepRow: View {
    let state: StepState
    let title: LocalizedStringKey
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(state == .pending || state == .skipped ? Theme.text3 : Theme.text)
                Text(detail)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .pending:
            Circle().strokeBorder(Color(hex: 0x2E3238), lineWidth: 2.4)
        case .running:
            ArcSpinner()
        case .done:
            Circle().fill(Theme.green.opacity(0.14))
                .overlay(Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.green))
        case .failed, .skipped:
            Circle().fill(Color(hex: 0x1F2226))
                .overlay(Image(systemName: "minus").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text3))
        }
    }
}

private struct GridCard: View {
    let state: DiscoveryState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.gridLabel)
                    .font(Theme.mono(13))
                    .foregroundStyle(Theme.textSoft)
                Spacer()
                Text(state.sweepTotal > 0 ? "\(state.sweepDone) / \(state.sweepTotal)" : "")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text3)
                    .monospacedDigit()
            }
            LEDGrid(cells: state.cells)
                .accessibilityElement()
                .accessibilityLabel("네트워크 스캔 진행 상황")
                .accessibilityValue(state.found.map { String(localized: "\($0.address)에서 MiSTer 발견") } ?? String(localized: "\(state.sweepTotal)개 중 \(state.sweepDone)개 확인"))
            HStack(spacing: 16) {
                Legend(color: Theme.amber, glow: true, text: "MiSTer")
                Legend(color: Color(hex: 0x15303F), ring: Theme.cyan, text: "이 Mac")
                Legend(color: Color(hex: 0x6E5630), text: "다른 FTP")
                Legend(color: Color(hex: 0x30343A), text: "응답 없음")
            }
        }
        .frame(width: 410)
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.well))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.border))
    }
}

private struct Legend: View {
    let color: Color
    var ring: Color?
    var glow = false
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(ring ?? .clear, lineWidth: 2))
                .frame(width: 10, height: 10)
                .shadow(color: glow ? color.opacity(0.6) : .clear, radius: 4)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
        }
    }
}

/// An invisible strip along the top edge that moves the window, like a title bar.
struct DragStrip: View {
    var height: CGFloat = 52

    var body: some View {
        Color.clear
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
    }
}
