import SwiftUI
import UIKit

/// The look of the AI Automations database, as on the Mac: white paper, near-black ink, hairlines, uppercase mono
/// labels with square bullets, heavy titles, #007fff accent, notched buttons. Dark mode inverts paper and ink.
enum K {
    private static func hex(_ v: UInt32, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }
    private static func dyn(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    static let paper = dyn(hex(0xFFFFFF), hex(0x0B0F17))
    static let ink = dyn(hex(0x0B0F17), hex(0xF2F4F7))
    static let muted = dyn(hex(0x535A67), hex(0xA0A7B4))
    static let line = dyn(hex(0x0B0F17, 0.12), hex(0xFFFFFF, 0.14))
    static let accent = Palette.accent
    static let accentDeep = Color(hex(0x0070E0)) // filled controls: white text passes AA on it
    static let accentInk = dyn(hex(0x0052A8), hex(0x7DBCFF)) // small accent text
    static let accentTint = dyn(hex(0xF5F9FF), hex(0x007FFF, 0.10))
    static let ghost = dyn(hex(0x0B0F17, 0.07), hex(0xFFFFFF, 0.12))
    static let green = Palette.green
    static let amber = Palette.amber
    static let red = dyn(hex(0xD93036), hex(0xFF6B6B))

    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        .system(size: size, weight: bold ? .semibold : .medium, design: .monospaced)
    }
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .black) }
}

/// Uppercase mono label with the site's square bullet.
struct MonoLabel: View {
    let text: String
    var size: CGFloat = 11
    var color: Color = K.ink
    var bullet: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let bullet { Rectangle().fill(bullet).frame(width: 6, height: 6) }
            Text(text.uppercased()).font(K.mono(size)).tracking(size * 0.06).foregroundStyle(color).lineLimit(1)
        }
    }
}

/// The site's button silhouette: top-left and bottom-right corners cut.
struct Notch: Shape {
    var cut: CGFloat = 8
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + cut, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - cut))
        p.addLine(to: CGPoint(x: r.maxX - cut, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + cut))
        p.closeSubpath()
        return p
    }
}

struct KButton: ButtonStyle {
    var filled = false
    var tint: Color = K.accentDeep
    var wide = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: wide ? .infinity : nil)
            .font(K.mono(13, bold: true)).tracking(0.8).textCase(.uppercase)
            .foregroundStyle(filled ? Color.white : K.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Notch().fill(filled ? tint : K.ghost).opacity(configuration.isPressed ? 0.75 : 1))
            .contentShape(Notch())
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(K.line).frame(height: 1) }
}
