// Draws the app icon from the design canvas ("앱 아이콘" artboard) and writes
// Resources/AppIcon.icns. Run: swift scripts/make_icon.swift
import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// 9×9 LED matrix: an amber up arrow and a cyan down arrow.
let pattern = [
    "..A......",
    ".AAA.....",
    "AAAAA....",
    "..A...C..",
    "..A...C..",
    "..A...C..",
    "....CCCCC",
    ".....CCC.",
    "......C..",
]

struct IconView: View {
    /// Small sizes hide the unlit dots so the arrows stay readable.
    var showUnlit: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x2E3137), Color(hex: 0x121316)], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.32), radius: 18, y: 10)
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.07), .clear], startPoint: .top, endPoint: .center))
                .frame(width: 824, height: 824)
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .strokeBorder(Color.white.opacity(0.11), lineWidth: 3)
                .frame(width: 824, height: 824)
            Canvas { context, _ in
                let pitch: CGFloat = 68
                let dot: CGFloat = 46
                let origin: CGFloat = 512 - pitch * 4
                func rect(_ x: Int, _ y: Int, _ size: CGFloat) -> CGRect {
                    CGRect(x: origin + CGFloat(x) * pitch - size / 2, y: origin + CGFloat(y) * pitch - size / 2, width: size, height: size)
                }
                // Glow under the lit dots.
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 22))
                    for (y, row) in pattern.enumerated() {
                        for (x, cell) in row.enumerated() where cell != "." {
                            let color = cell == "A" ? Color(hex: 0xFFB547) : Color(hex: 0x6CC6F5)
                            layer.fill(Path(ellipseIn: rect(x, y, 70)), with: .color(color.opacity(0.55)))
                        }
                    }
                }
                for (y, row) in pattern.enumerated() {
                    for (x, cell) in row.enumerated() {
                        let color: Color
                        switch cell {
                        case "A": color = Color(hex: 0xFFB547)
                        case "C": color = Color(hex: 0x6CC6F5)
                        default:
                            guard showUnlit else { continue }
                            color = Color(hex: 0x2A2D33)
                        }
                        context.fill(Path(roundedRect: rect(x, y, dot), cornerRadius: 12), with: .color(color))
                    }
                }
            }
            .frame(width: 1024, height: 1024)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func png(size: Int) -> Data {
    let renderer = ImageRenderer(content: IconView(showUnlit: size >= 64))
    renderer.scale = CGFloat(size) / 1024
    renderer.isOpaque = false
    guard let image = renderer.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
MainActor.assumeIsolated {
    for (name, size) in entries {
        try! png(size: size).write(to: iconset.appendingPathComponent(name))
    }
    try! png(size: 1024).write(to: root.appendingPathComponent(".build/AppIcon-1024.png"))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote \(output.path)" : "iconutil failed")
