import AppKit
import SwiftUI

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    static func make(copilot: Copilot) -> HUDPanel {
        let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
                             styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow,
                                         .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.title = "Call Copilot"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = K.paperNS
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Ask macOS to leave this window out of screen captures and screen sharing.
        if !Config.showInCapture { panel.sharingType = .none }
        let titlebar = max(22, panel.frame.height - panel.contentLayoutRect.height)
        panel.contentView = NSHostingView(rootView: HUDView(copilot: copilot, titlebarHeight: titlebar))
        if !panel.setFrameUsingName("CallCopilotHUD"), let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - 360 - 16, y: v.maxY - 480 - 16))
        }
        panel.setFrameAutosaveName("CallCopilotHUD")
        return panel
    }
}

struct HUDView: View {
    @ObservedObject var copilot: Copilot
    let titlebarHeight: CGFloat
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sits in the transparent title bar, beside the close button; like the site's top bar.
            MonoLabel(text: "Call Copilot", size: 10, bullet: K.ink)
                .frame(maxWidth: .infinity)
                .frame(height: titlebarHeight)
            Hairline()
            header
            Hairline()
            ForEach([copilot.setupNote, copilot.captureNote, copilot.turnError].compactMap { $0 }, id: \.self) { e in
                Text(e).font(K.sans(11.5)).foregroundStyle(K.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                Hairline()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if copilot.cards.isEmpty {
                        Text(emptyText).font(K.sans(12)).foregroundStyle(K.muted)
                            .padding(14)
                    }
                    ForEach(copilot.cards) { card in
                        CardView(card: card)
                        Hairline()
                    }
                }
            }
            if copilot.asking || copilot.answer != nil {
                Hairline()
                answer
            }
            Hairline()
            askField
            if let line = copilot.lastLine {
                Text(line).font(K.sans(10.5)).foregroundStyle(K.muted).lineLimit(1)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
        .background(K.paper)
        .ignoresSafeArea(.container, edges: .top) // the first row shares the title bar with the close button
        .frame(minWidth: 300, minHeight: 260)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Rectangle().fill(dotColor).frame(width: 7, height: 7)
                Text(statusText.uppercased()).font(K.mono(10.5, bold: true)).tracking(0.6)
                    .foregroundStyle(K.ink).lineLimit(1)
                Spacer(minLength: 8)
                if copilot.isListening {
                    Button("Skip this call") { copilot.skipCall() }.buttonStyle(KButton())
                } else {
                    Button("Listen") { copilot.toggleManual(snapshot: copilot.currentSnapshot) }.buttonStyle(KButton(filled: true))
                }
            }
            HStack(spacing: 12) {
                meter("Me", copilot.meActive)
                meter(copilot.themIsAllAudio ? "Them: all audio" : "Them", copilot.themActive)
                Spacer(minLength: 8)
                if !copilot.watchStatus.isEmpty {
                    Text(copilot.watchStatus.uppercased()).font(K.mono(9.5)).tracking(0.5)
                        .foregroundStyle(K.muted).lineLimit(2).multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                MonoLabel(text: copilot.asking ? "Asking…" : "Answer", size: 9.5, color: K.accentInk, bullet: K.accent)
                Spacer()
                if let a = copilot.answer {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(a, forType: .string)
                    }.buttonStyle(KLink())
                    Button("Clear") { copilot.answer = nil }.buttonStyle(KLink()).padding(.leading, 6)
                }
            }
            if let a = copilot.answer {
                Text(a).font(K.sans(12.5)).foregroundStyle(K.ink).textSelection(.enabled)
                    .lineLimit(14) // Copy takes the whole answer
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(K.accentTint)
        .overlay(alignment: .leading) { Rectangle().fill(K.accent).frame(width: 2) }
    }

    /// Like the site's search bar: blue prompt, mono placeholder.
    private var askField: some View {
        HStack(spacing: 10) {
            Text(">").font(K.mono(13, bold: true)).foregroundStyle(K.accent)
            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("ASK ABOUT THIS CALL").font(K.mono(10.5)).tracking(0.7).foregroundStyle(K.muted)
                        .allowsHitTesting(false)
                }
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .font(K.sans(12.5))
                    .foregroundStyle(K.ink)
                    .onSubmit {
                        copilot.ask(query)
                        query = ""
                    }
            }
            Text("⌃⌥SPACE").font(K.mono(9)).tracking(0.5).foregroundStyle(K.muted)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private var emptyText: String {
        copilot.isListening ? "Cards from your watchers appear here as the call gives them a reason."
                            : "Starts by itself when a call app uses the mic. ⌃⌥C starts it by hand."
    }

    private var statusText: String {
        switch copilot.phase {
        case .idle: return "Not listening"
        case .starting: return "Starting…"
        case .listening: return "Listening" + (copilot.callApp.map { " · \($0)" } ?? "")
        case .ended: return "Not listening · last call below"
        case .failed: return "Stopped"
        }
    }

    private var dotColor: Color {
        switch copilot.phase {
        case .listening: return K.green
        case .starting: return K.amber
        case .failed: return K.red
        default: return K.line
        }
    }

    private func meter(_ label: String, _ active: Bool) -> some View {
        HStack(spacing: 5) {
            Rectangle().fill(active ? K.green : K.line).frame(width: 6, height: 6)
            Text(label.uppercased()).font(K.mono(9.5)).tracking(0.5).foregroundStyle(K.muted)
        }
    }
}

struct CardView: View {
    let card: Card
    @State private var hover = false

    private var color: Color { K.watcherColors[card.watcherIndex % K.watcherColors.count] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                MonoLabel(text: card.watcher, size: 9.5, color: K.muted, bullet: color)
                Spacer()
                if !card.links.isEmpty {
                    Text("OPEN ↗").font(K.mono(9.5)).tracking(0.5).foregroundStyle(K.accentInk).opacity(hover ? 1 : 0.55)
                }
            }
            Text(card.title.uppercased()).font(K.display(15)).tracking(-0.3).foregroundStyle(K.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !card.body.isEmpty {
                Text(card.body).font(K.sans(12, weight: .medium)).foregroundStyle(K.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 2) }
            }
            if !card.quote.isEmpty {
                Text("“\(card.quote)”").font(K.sans(11.5)).foregroundStyle(K.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.links.isEmpty {
                HStack(spacing: 12) {
                    ForEach(card.links, id: \.self) { url in
                        Link(destination: url) {
                            Text(((url.host ?? "link").replacingOccurrences(of: "www.", with: "") + " ↗").uppercased())
                                .font(K.mono(9)).tracking(0.4).foregroundStyle(K.accentInk).underline()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(hover && !card.links.isEmpty ? K.accentTint : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if let u = card.links.first { NSWorkspace.shared.open(u) } }
    }
}

/// Spotlight-style ask bar for ⌃⌥Space. It takes the keyboard without activating the app (macOS 14+ won't let a
/// background app activate itself, even from its own hotkey) and closes on Return, Esc or a click elsewhere,
/// which hands the keyboard back to the app you were in. The answer shows in the main panel.
final class AskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// Called after Return or Esc, to hand the keyboard back to the app you were in.
    var onDone: (() -> Void)?

    static func make(copilot: Copilot) -> AskPanel {
        let p = AskPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 56),
                         styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                         backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.backgroundColor = K.paperNS
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if !Config.showInCapture { p.sharingType = .none }
        p.contentView = NSHostingView(rootView: AskView(copilot: copilot) { [weak p] in p?.finish() })
        return p
    }

    func present() {
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            setFrameOrigin(NSPoint(x: v.midX - frame.width / 2, y: v.maxY - v.height * 0.25))
        }
        orderFrontRegardless() // makeKeyAndOrderFront would ask to activate the app; macOS refuses and takes key back
        makeKey()
        if let field = Self.textField(in: contentView) { makeFirstResponder(field) }
    }

    /// Return or Esc: close and hand the keyboard back.
    func finish() {
        guard isVisible else { return }
        orderOut(nil)
        onDone?()
    }

    /// Clicked elsewhere: the keyboard has already gone there, so just close.
    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    override func cancelOperation(_ sender: Any?) { finish() }

    static func textField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let f = view as? NSTextField, f.isEditable { return f }
        for sub in view.subviews { if let f = textField(in: sub) { return f } }
        return nil
    }
}

struct AskView: View {
    @ObservedObject var copilot: Copilot
    var close: () -> Void
    @State private var query = ""

    var body: some View {
        HStack(spacing: 12) {
            Text(">").font(K.mono(17, bold: true)).foregroundStyle(K.accent)
            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("ASK ABOUT THIS CALL").font(K.mono(12.5)).tracking(1).foregroundStyle(K.muted)
                        .allowsHitTesting(false)
                }
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .font(K.sans(16))
                    .foregroundStyle(K.ink)
                    .onSubmit {
                        copilot.ask(query)
                        query = ""
                        close()
                    }
                    .onChange(of: copilot.demoTyping) { query = copilot.demoTyping ?? "" }
            }
            Text("↵ ASK · ESC").font(K.mono(9)).tracking(0.5).foregroundStyle(K.muted)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(K.paper)
        .ignoresSafeArea()
    }
}
