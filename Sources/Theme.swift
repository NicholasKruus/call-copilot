import AppKit
import SwiftUI

/// The look of the AI Automations database (ai-automations-db.vercel.app): white paper, near-black ink, hairlines,
/// IBM Plex Mono uppercase labels with square bullets, Inter Tight Black titles, #007fff accent, notched buttons.
/// Dark mode inverts paper and ink and keeps the accent.
enum K {
    private static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }
    private static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    static let paperNS = dyn(hex(0xFFFFFF), hex(0x0B0F17))
    static let paper = Color(nsColor: paperNS)
    static let ink = Color(nsColor: dyn(hex(0x0B0F17), hex(0xF2F4F7)))
    static let muted = Color(nsColor: dyn(hex(0x535A67), hex(0xA0A7B4)))
    static let line = Color(nsColor: dyn(hex(0x0B0F17, 0.12), hex(0xFFFFFF, 0.14)))
    static let accent = Color(nsColor: hex(0x007FFF))
    static let accentDeep = Color(nsColor: hex(0x0070E0)) // filled controls: white text passes AA on it
    static let accentInk = Color(nsColor: dyn(hex(0x0052A8), hex(0x7DBCFF))) // small accent text
    static let accentTint = Color(nsColor: dyn(hex(0xF5F9FF), hex(0x007FFF, 0.10)))
    static let ghost = Color(nsColor: dyn(hex(0x0B0F17, 0.07), hex(0xFFFFFF, 0.12)))
    static let ghostPressed = Color(nsColor: dyn(hex(0x0B0F17, 0.14), hex(0xFFFFFF, 0.22)))
    static let green = Color(nsColor: hex(0x3FCF86))
    static let amber = Color(nsColor: hex(0xE9B80F))
    static let red = Color(nsColor: dyn(hex(0xD93036), hex(0xFF6B6B)))

    // The site's fonts (IBM Plex Mono, Inter, Inter Tight) if they're installed; otherwise the matching system font
    // (SF Mono, SF Pro), so labels stay monospaced and titles stay heavy.
    private static var installed: [String: Bool] = [:]
    private static func has(_ name: String) -> Bool {
        if let known = installed[name] { return known }
        let ok = NSFont(name: name, size: 12) != nil
        installed[name] = ok
        return ok
    }
    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        let name = bold ? "IBMPlexMono-SemiBold" : "IBMPlexMono-Medium"
        return has(name) ? .custom(name, size: size) : .system(size: size, weight: bold ? .semibold : .medium, design: .monospaced)
    }
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name = weight == .semibold ? "Inter-SemiBold" : weight == .medium ? "Inter-Medium" : "Inter-Regular"
        return has(name) ? .custom(name, size: size) : .system(size: size, weight: weight)
    }
    static func display(_ size: CGFloat) -> Font {
        has("InterTight-Black") ? .custom("InterTight-Black", size: size) : .system(size: size, weight: .black)
    }
    /// One colour per watcher, in settings order.
    static let watcherColors = [accent, amber, green, Color(nsColor: hex(0x8B5CF6)), red]
}

/// Uppercase mono label with the site's square bullet.
struct MonoLabel: View {
    let text: String
    var size: CGFloat = 10
    var color: Color = K.ink
    var bullet: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let bullet { Rectangle().fill(bullet).frame(width: 5, height: 5) }
            Text(text.uppercased()).font(K.mono(size)).tracking(size * 0.06).foregroundStyle(color).lineLimit(1)
        }
    }
}

/// The site's button silhouette: top-left and bottom-right corners cut.
struct Notch: Shape {
    var cut: CGFloat = 6
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(K.mono(10, bold: true)).tracking(0.6).textCase(.uppercase)
            .foregroundStyle(filled ? Color.white : K.ink)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(Notch().fill(filled ? (configuration.isPressed ? K.ink : K.accentDeep)
                                            : (configuration.isPressed ? K.ghostPressed : K.ghost)))
            .contentShape(Notch())
    }
}

/// The site's underlined mono text link.
struct KLink: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(K.mono(9.5)).tracking(0.6).textCase(.uppercase)
            .foregroundStyle(K.accentInk)
            .underline()
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(K.line).frame(height: 1) }
}
