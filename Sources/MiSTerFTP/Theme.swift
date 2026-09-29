import SwiftUI

/// Colors, type and control styles from the "MiSTer FTP — Mac 앱 디자인" canvas.
enum Theme {
    // Surfaces
    static let window = Color(hex: 0x15171A)
    static let discovery = Color(hex: 0x121316)
    static let sidebar = Color(hex: 0x101113)
    static let panel = Color(hex: 0x17191D)
    static let well = Color(hex: 0x0D0E10)
    static let field = Color(hex: 0x1B1D21)
    static let fieldDeep = Color(hex: 0x111215)
    static let tray = Color(hex: 0x111215)
    static let trayRow = Color(hex: 0x16181B)
    static let trayRowActive = Color(hex: 0x1A1C20)
    static let control = Color(hex: 0x1F2226)
    static let navSelected = Color(hex: 0x23262B)
    static let hover = Color(hex: 0x1C1E22)
    static let rowSelected = Color(hex: 0xFFB547).opacity(0.14)

    // Lines
    static let line = Color(hex: 0x1F2226)
    static let lineSoft = Color(hex: 0x1D2024)
    static let border = Color(hex: 0x24272C)
    static let fieldBorder = Color(hex: 0x2A2D32)
    static let controlBorder = Color(hex: 0x2E3238)

    // Text
    static let text = Color(hex: 0xF2EFE9)
    static let textRow = Color(hex: 0xECE9E3)
    static let textSoft = Color(hex: 0xD9D6D0)
    static let text2 = Color(hex: 0xA9ABB0)
    static let text3 = Color(hex: 0x878B92)
    static let icon = Color(hex: 0xC9C6C0)
    static let fileIcon = Color(hex: 0x8E9298)

    // Accents
    static let amber = Color(hex: 0xFFB547)
    static let amberInk = Color(hex: 0x1C1405)
    static let amberWell = Color(hex: 0x2A2215)
    static let cyan = Color(hex: 0x6CC6F5)
    static let green = Color(hex: 0x7BD88F)
    static let greenText = Color(hex: 0x9FE3AE)
    static let red = Color(hex: 0xFF6E5E)
    static let ledOff = Color(hex: 0x2A2D33)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double(hex >> 16 & 0xFF) / 255,
            green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 30
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.amberInk)
            .padding(.horizontal, 13)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.amber.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 30
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration) { hovering in
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(hex: 0xE6E3DD))
                .padding(.horizontal, 12)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(configuration.isPressed ? Theme.navSelected : (hovering ? Color(hex: 0x25282D) : Theme.control))
                )
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.controlBorder))
        }
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Transparent until the pointer is over it.
struct QuietButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var horizontalPadding: CGFloat = 8
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration) { hovering in
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(configuration.isPressed ? Theme.navSelected : (hovering ? Theme.hover : .clear))
                )
        }
        .opacity(isEnabled ? 1 : 0.35)
    }
}

/// Full-width button on the sidebar footer.
struct PanelButtonStyle: ButtonStyle {
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration) { hovering in
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSoft)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(configuration.isPressed ? Theme.navSelected : (hovering ? Theme.hover : Theme.panel))
                )
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.fieldBorder))
                .contentShape(Rectangle())
        }
    }
}

/// Square icon button, optionally with a hairline border.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var bordered = true
    var circle = false
    var fill: Color = .clear
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration) { hovering in
            let shape = RoundedRectangle(cornerRadius: circle ? size / 2 : 8, style: .continuous)
            configuration.label
                .foregroundStyle(Theme.icon)
                .frame(width: size, height: size)
                .background(shape.fill(configuration.isPressed ? Theme.navSelected : (hovering ? Theme.hover : fill)))
                .overlay(shape.strokeBorder(bordered ? Theme.fieldBorder : .clear))
                .contentShape(shape)
        }
        .opacity(isEnabled ? 1 : 0.35)
    }
}

/// Gives a button style a hover flag without repeating `@State` in every style.
private struct HoverBody<Content: View>: View {
    let configuration: ButtonStyleConfiguration
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}

// MARK: Fields

struct FieldBackground: ViewModifier {
    var focused = false
    var height: CGFloat = 36

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 11)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fieldDeep))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? Theme.amber : Theme.controlBorder)
            )
            .shadow(color: focused ? Theme.amber.opacity(0.18) : .clear, radius: 0)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(focused ? Theme.amber.opacity(0.18) : .clear, lineWidth: 3)
                    .padding(-1.5)
            )
    }
}

extension View {
    func fieldStyle(focused: Bool = false, height: CGFloat = 36) -> some View {
        modifier(FieldBackground(focused: focused, height: height))
    }
}
