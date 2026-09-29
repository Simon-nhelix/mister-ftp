import SwiftUI
import FTPKit

/// The transfer tray at the bottom of the browser (design screen 2).
struct TransferTray: View {
    @Bindable var queue: TransferQueue

    var body: some View {
        VStack(spacing: 6) {
            header
            if queue.expanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(queue.jobs) { job in
                                TransferRow(job: job, queue: queue)
                                    .id(job.id)
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: listHeight)
                    .onChange(of: queue.jobs.count) { old, new in
                        if new > old, let last = queue.jobs.last {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .padding(.top, 10)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .background(Theme.tray)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var listHeight: CGFloat {
        let rows = min(CGFloat(queue.jobs.count), 3.5)
        return max(40, rows * 44 - 4)
    }

    private var failedCount: Int {
        queue.jobs.filter { if case .failed = $0.state { return true } else { return false } }.count
    }

    private var summary: String {
        let total = queue.jobs.count
        let done = queue.jobs.filter { $0.state == .done }.count
        var text = queue.isBusy ? String(localized: "\(total)개 중 \(done)개 완료") : String(localized: "\(done)개 완료")
        if failedCount > 0 { text += String(localized: " · \(failedCount)개 실패") }
        return text
    }

    private var speedText: String {
        guard queue.isBusy else { return Format.bytes(queue.totalBytes) }
        guard queue.speed > 0 else { return "" }
        var text = Format.speed(queue.speed)
        if let seconds = queue.remainingSeconds, seconds.isFinite {
            let remaining = Format.remaining(seconds)
            if !remaining.isEmpty { text += " · \(remaining)" }
        }
        return text
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("전송")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .fixedSize()
            LEDBar(progress: queue.overallProgress, color: queue.isBusy || failedCount > 0 ? Theme.amber : Theme.green)
            Text(speedText)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textSoft)
                .monospacedDigit()
                .fixedSize()
            if queue.isBusy {
                Button("모두 취소") { queue.cancelAll() }
                    .buttonStyle(QuietButtonStyle(height: 26))
            } else {
                Button("목록 지우기") { queue.clearFinished() }
                    .buttonStyle(QuietButtonStyle(height: 26))
            }
            Button {
                withAnimation(.easeOut(duration: 0.2)) { queue.expanded.toggle() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(queue.expanded ? 0 : 180))
            }
            .buttonStyle(IconButtonStyle(size: 26, bordered: false))
            .accessibilityLabel(queue.expanded ? "전송 목록 접기" : "전송 목록 펼치기")
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
    }
}

private struct TransferRow: View {
    let job: TransferJob
    let queue: TransferQueue

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(job.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textRow)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if job.isFolder {
                    Text(job.fileCount > 0 ? String(localized: "폴더 · 파일 \(job.fileCount)개") : String(localized: "폴더"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                        .fixedSize()
                }
                Text(job.direction == .upload ? "→ \(job.destinationLabel)" : "→ Mac · \(job.destinationLabel)")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            statusArea
                .frame(width: 220, alignment: .leading)

            Text(sizeText)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(job.state == .running ? Theme.textSoft : Theme.text2)
                .lineLimit(1)
                .frame(width: 112, alignment: .trailing)

            actionButton
                .frame(width: 26)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(job.state == .running ? Theme.trayRowActive : Theme.trayRow)
        )
    }

    private var accent: Color { job.direction == .upload ? Theme.amber : Theme.cyan }

    @ViewBuilder private var statusIcon: some View {
        let (symbol, color, fill): (String, Color, Color) = {
            switch job.state {
            case .done: return ("checkmark", Theme.green, Theme.green.opacity(0.14))
            case .failed: return ("exclamationmark", Theme.red, Theme.red.opacity(0.14))
            case .cancelled: return ("xmark", Theme.text3, Theme.control)
            case .running: return (job.direction == .upload ? "arrow.up" : "arrow.down", accent, accent.opacity(0.16))
            case .waiting, .preparing: return (job.direction == .upload ? "arrow.up" : "arrow.down", Theme.text3, Theme.control)
            }
        }()
        Circle()
            .fill(fill)
            .frame(width: 24, height: 24)
            .overlay(Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(color))
    }

    @ViewBuilder private var statusArea: some View {
        switch job.state {
        case .running:
            ProgressTrack(progress: job.progress, color: accent)
        case .waiting:
            Text("대기 중").font(.system(size: 12)).foregroundStyle(Theme.text3)
        case .preparing:
            Text("준비 중…").font(.system(size: 12)).foregroundStyle(Theme.text3)
        case .done:
            Text("완료").font(.system(size: 12)).foregroundStyle(Theme.greenText)
        case .cancelled:
            Text("취소됨").font(.system(size: 12)).foregroundStyle(Theme.text3)
        case .failed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.red)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(message)
        }
    }

    private var sizeText: String {
        switch job.state {
        case .running:
            return job.totalBytes > 0 ? Format.progress(job.doneBytes, of: job.totalBytes) : Format.bytes(job.doneBytes)
        case .preparing:
            return "—"
        default:
            return job.totalBytes > 0 || job.state == .done ? Format.bytes(job.totalBytes) : "—"
        }
    }

    @ViewBuilder private var actionButton: some View {
        if !job.isFinished {
            Button { queue.cancel(job) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 26, bordered: false, circle: true, fill: Color(hex: 0x24272C)))
            .help("전송 취소")
            .accessibilityLabel("\(job.name) 전송 취소")
        } else if job.direction == .download, job.state == .done, job.resultURL != nil {
            Button { queue.reveal(job) } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(size: 26, bordered: false, circle: true, fill: Color(hex: 0x24272C)))
            .help("Finder에서 보기")
            .accessibilityLabel("\(job.name) Finder에서 보기")
        } else {
            Button { queue.remove(job) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 26, bordered: false, circle: true))
            .help("목록에서 지우기")
            .accessibilityLabel("\(job.name) 목록에서 지우기")
        }
    }
}

private struct ProgressTrack: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ledOff)
                Capsule()
                    .fill(color)
                    .frame(width: max(6, proxy.size.width * progress))
                    .animation(.linear(duration: 0.15), value: progress)
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("진행률")
        .accessibilityValue("\(Int(progress * 100))%")
    }
}
