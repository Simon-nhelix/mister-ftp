import SwiftUI
import FTPKit

/// The "MiSTer FTP" pixel wordmark. Same 5×7 glyphs as the design canvas.
struct PixelWordmark: View {
    var unit: CGFloat = 3
    var dotted = false

    private static let glyphs: [Character: [String]] = [
        "M": ["X...X", "XX.XX", "X.X.X", "X.X.X", "X...X", "X...X", "X...X"],
        "i": ["X", ".", "X", "X", "X", "X", "X"],
        "S": [".XXX", "X...", "X...", ".XX.", "...X", "...X", "XXX."],
        "T": ["XXXXX", "..X..", "..X..", "..X..", "..X..", "..X..", "..X.."],
        "e": ["....", "....", ".XX.", "X..X", "XXXX", "X...", ".XXX"],
        "r": ["....", "....", "X.XX", "XX..", "X...", "X...", "X..."],
        "F": ["XXXX", "X...", "X...", "XXX.", "X...", "X...", "X..."],
        "P": ["XXX.", "X..X", "X..X", "XXX.", "X...", "X...", "X..."],
    ]

    private struct Pixel { let x: Int; let y: Int; let accent: Bool }

    private static let layout: (pixels: [Pixel], width: Int) = {
        var pixels: [Pixel] = []
        var x = 0
        for (wordIndex, word) in [("MiSTer", false), ("FTP", true)].enumerated() {
            if wordIndex > 0 { x += 2 }
            for character in word.0 {
                let rows = glyphs[character]!
                for (y, row) in rows.enumerated() {
                    for (dx, cell) in row.enumerated() where cell == "X" {
                        pixels.append(Pixel(x: x + dx, y: y, accent: word.1))
                    }
                }
                x += rows[0].count + 1
            }
        }
        return (pixels, x - 1)
    }()

    var body: some View {
        let layout = Self.layout
        Canvas { context, _ in
            for pixel in layout.pixels {
                let rect = CGRect(x: CGFloat(pixel.x) * unit, y: CGFloat(pixel.y) * unit, width: unit, height: unit)
                let color = pixel.accent ? Theme.amber : Theme.text
                if dotted {
                    let inset = unit * 0.11
                    context.fill(Path(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerRadius: unit * 0.18), with: .color(color))
                } else {
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(layout.width) * unit, height: 7 * unit)
        .accessibilityElement()
        .accessibilityLabel("MiSTer FTP")
    }
}

/// 16×16 LED matrix: one light per address in this Mac's /24 network.
struct LEDGrid: View {
    let cells: [DiscoveryCellState]
    var cell: CGFloat = 20
    var gap: CGFloat = 6

    var body: some View {
        let side = cell * 16 + gap * 15
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, _ in
                for index in 0..<min(256, cells.count) {
                    let rect = CGRect(
                        x: CGFloat(index % 16) * (cell + gap),
                        y: CGFloat(index / 16) * (cell + gap),
                        width: cell, height: cell
                    )
                    let shape = Path(roundedRect: rect, cornerRadius: 4)
                    switch cells[index] {
                    case .waiting:
                        context.fill(shape, with: .color(Color(hex: 0x1B1D21)))
                    case .probing:
                        let wave = 0.5 + 0.5 * sin(time * 7 - Double(index) * 0.45)
                        context.fill(shape, with: .color(Color(hex: 0x3A3F47).opacity(0.55 + 0.45 * wave)))
                    case .silent:
                        context.fill(shape, with: .color(Color(hex: 0x30343A)))
                    case .ftp:
                        context.fill(shape, with: .color(Color(hex: 0x6E5630)))
                    case .mister:
                        let pulse = 0.75 + 0.25 * sin(time * 3)
                        context.drawLayer { layer in
                            layer.addFilter(.shadow(color: Theme.amber.opacity(0.75 * pulse), radius: 9))
                            layer.fill(shape, with: .color(Theme.amber))
                        }
                    case .thisMac:
                        context.fill(shape, with: .color(Color(hex: 0x15303F)))
                        context.stroke(Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 3.5), with: .color(Theme.cyan), lineWidth: 2)
                    case .outside:
                        context.fill(shape, with: .color(Theme.well))
                        context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3.5), with: .color(Theme.line), lineWidth: 1)
                    }
                }
            }
        }
        .frame(width: side, height: side)
    }
}

/// Segmented progress bar, like the level meter on old hardware.
struct LEDBar: View {
    let progress: Double
    var segments = 48
    var color: Color = Theme.amber

    var body: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 2
            let width = max(1, (proxy.size.width - gap * CGFloat(segments - 1)) / CGFloat(segments))
            let lit = Int((min(max(progress, 0), 1) * Double(segments)).rounded(.down))
            HStack(spacing: gap) {
                ForEach(0..<segments, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(index < lit ? color : Theme.ledOff)
                        .frame(width: width)
                }
            }
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel("전체 진행률")
        .accessibilityValue("\(Int(progress * 100))%")
    }
}

/// Small circular spinner that matches the discovery steps.
struct ArcSpinner: View {
    var size: CGFloat = 22
    @State private var angle = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(Color(hex: 0x2E3238), lineWidth: 2.4)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(Theme.amber, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .rotationEffect(.degrees(angle))
        }
        .padding(1.5)
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { angle = 360 }
        }
    }
}
