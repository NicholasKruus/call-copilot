import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

signal(SIGPIPE, SIG_IGN) // a dead claude child must not kill the app when we write to its stdin

/// Global hotkeys through Carbon, which needs no Accessibility permission.
enum HotKeys {
    static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef?] = []

    static func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            log("hotkey \(id) pressed")
            DispatchQueue.main.async { HotKeys.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    static func register(id: UInt32, keyCode: Int, _ handler: @escaping () -> Void) {
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(controlKey | optionKey),
                                         EventHotKeyID(signature: OSType(0x4343_4F50), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        log("hotkey \(id): register status \(status)")
        refs.append(ref)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let copilot = Copilot()
    let detector = CallDetector()
    var panel: HUDPanel!
    var statusItem: NSStatusItem!
    var unseen = 0
    var askPanel: AskPanel!
    var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ note: Notification) {
        trimLog()
        log("launch \(Bundle.main.bundlePath)")
        panel = HUDPanel.make(copilot: copilot)
        askPanel = AskPanel.make(copilot: copilot)
        askPanel.onDone = { [weak self] in self?.handBack() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        copilot.$phase.receive(on: DispatchQueue.main).sink { [weak self] phase in
            guard let self else { return }
            if phase == .starting { self.showPanel() }
            self.updateIcon()
        }.store(in: &bag)
        copilot.onCardsAdded = { [weak self] in
            guard let self, !self.panel.isVisible else { return }
            self.unseen += 1
            self.updateIcon()
        }

        // Esc closes the ask bar (a text field's editor would otherwise swallow it).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.askPanel.isKeyWindow else { return event }
            self.askPanel.finish()
            return nil
        }

        HotKeys.install()
        HotKeys.register(id: 1, keyCode: kVK_Space) { [weak self] in self?.focusAsk() }
        HotKeys.register(id: 2, keyCode: kVK_ANSI_C) { [weak self] in
            guard let self else { return }
            self.copilot.toggleManual(snapshot: self.detector.latest)
        }

        detector.onUpdate = { [weak self] app in self?.copilot.callUpdate(app) }
        detector.start()
        registerLoginItem()
    }

    /// Opening the app again (Spotlight, Alfred, Finder) opens the ask box.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        focusAsk()
        return false
    }

    func showPanel() {
        panel.orderFrontRegardless()
        unseen = 0
        updateIcon()
    }

    func focusAsk() {
        log("ask: opened")
        showPanel()
        askPanel.present()
    }

    /// The ask bar holds the keyboard for this app even after it closes, so a keystroke would be lost. Hiding the
    /// app gives the keyboard back to the app underneath; unhiding without activation brings the panel back.
    func handBack() {
        let hudVisible = panel.isVisible
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.unhideWithoutActivation()
            if hudVisible { self.panel.orderFrontRegardless() }
        }
    }

    func updateIcon() {
        let symbol = copilot.isListening ? "waveform.circle.fill" : "waveform.circle"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Call Copilot")
        statusItem.button?.title = unseen > 0 ? " \(unseen)" : ""
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = copilot.isListening ? "Listening\(copilot.callApp.map { " · \($0)" } ?? "")" : "Not listening"
        let header = NSMenuItem(title: state, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(item(copilot.isListening ? "Stop listening  ⌃⌥C" : "Start listening  ⌃⌥C", #selector(toggle)))
        if copilot.isListening { menu.addItem(item("Skip this call", #selector(skip))) }
        menu.addItem(item("Show panel", #selector(show)))
        menu.addItem(item("Ask…  ⌃⌥Space", #selector(askItem)))
        menu.addItem(.separator())
        menu.addItem(item("Edit watchers…", #selector(editWatchers)))
        menu.addItem(item("Quit Call Copilot", #selector(quit)))
    }

    private func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc func toggle() { copilot.toggleManual(snapshot: detector.latest) }
    @objc func skip() { copilot.skipCall() }
    @objc func show() { showPanel() }
    @objc func askItem() { focusAsk() }
    /// Opens settings.json in the default editor for .json files. Changes apply from the next call.
    @objc func editWatchers() {
        _ = Settings.load() // creates the file from the defaults if it isn't there yet
        NSWorkspace.shared.open(Config.settingsURL)
    }
    @objc func quit() { copilot.stop(reason: "quit"); NSApp.terminate(nil) }

    private func registerLoginItem() {
        let service = SMAppService.mainApp
        guard service.status != .enabled else { return }
        do { try service.register(); log("login item: registered") } catch { log("login item: \(error)") }
    }
}

/// `CallCopilot --test-file <audio> [--ask <question>]`: transcribe a file as the other side of a call, run it
/// through the same Claude session, print what the panel would show, and exit. No capture, no UI.
final class TestRunner {
    let copilot = Copilot()
    var stage = 0
    var forced = false
    let ask: String?
    let started = Date()

    init(file: URL, ask: String?) {
        self.ask = ask
        copilot.echo = true
        copilot.start(app: "Test", auto: false, processes: [], testFiles: [("Them", file)])
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.step() }
    }

    func step() {
        if Date().timeIntervalSince(started) > 360 { finish("TIMEOUT stage \(stage)", code: 1) }
        if case .failed(let e) = copilot.phase { finish("FAILED \(e)", code: 1) }
        switch stage {
        case 0:
            if copilot.phase == .listening && copilot.referencesReady {
                print("WATCHERS \(copilot.watchStatus)")
                copilot.tick(force: true)
                stage = 1
            }
        case 1:
            if copilot.idle {
                if let q = ask { copilot.ask(q); stage = 2 } else { stage = 3 }
            }
        case 2:
            if !copilot.asking { stage = 3 }
        default:
            for c in copilot.cards {
                print("CARD \(c.watcher): \(c.title) | \(c.body) | “\(c.quote)” | \(c.links.map(\.absoluteString).joined(separator: " "))")
            }
            if let n = copilot.setupNote { print("NOTE \(n)") }
            if let a = copilot.answer { print("ANSWER \(a)") }
            if let e = copilot.turnError { print("ERROR \(e)") }
            finish("DONE in \(Int(Date().timeIntervalSince(started))) s", code: 0)
        }
    }

    func finish(_ msg: String, code: Int32) {
        print(msg)
        copilot.stop(reason: "test done")
        exit(code)
    }
}

/// `CallCopilot --test-preview [light|dark]`: shows the panel and ask bar filled with sample cards for 25 s, without
/// capture, hotkeys or taking the keyboard. For checking the look; prints the window numbers for screenshots.
final class PreviewRunner {
    let copilot = Copilot()
    var hud: HUDPanel!
    var ask: AskPanel!

    init(dark: Bool) {
        copilot.phase = .listening
        copilot.callApp = "Zoom"
        copilot.watchStatus = "Evidence · Automations (31)"
        copilot.cards = [
            Card(watcher: "Evidence", watcherIndex: 0, title: "Public views on AI sentience have been surveyed",
                 body: "Sentience Institute's AIMS survey (US adults) found about 1 in 5 think some AI systems are already sentient.",
                 quote: "I don't think anyone has surveyed it properly",
                 links: [URL(string: "https://www.sentienceinstitute.org/aims-survey-2023")!]),
            Card(watcher: "Automations", watcherIndex: 1, title: "Find and Chase Missing Payment Receipts",
                 body: "Chasing staff for company card receipts at month end",
                 quote: "chasing staff for receipts on the company card",
                 links: [URL(string: "https://ai-automations-db.vercel.app/?q=Find%20and%20Chase%20Missing%20Payment%20Receipts")!]),
            Card(watcher: "Automations", watcherIndex: 1, title: "No automation yet: tracking funder report deadlines",
                 body: "", quote: "which funder needs which report by when", links: []),
        ]
        copilot.answer = "Lead with receipt chasing: it's their worst monthly pain and runs off the card statement "
            + "they already export. The expense-claim checker uses the same stack, so pitch them together."
        copilot.lastLine = "[Them] We also spend hours each week writing grant reports."
        hud = HUDPanel.make(copilot: copilot)
        ask = AskPanel.make(copilot: copilot)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hud.appearance = appearance
        ask.appearance = appearance
        hud.orderFrontRegardless()
        ask.setFrameOrigin(NSPoint(x: hud.frame.minX - ask.frame.width - 20, y: hud.frame.maxY - ask.frame.height))
        ask.orderFrontRegardless()
        print("HUD \(hud.windowNumber) ASK \(ask.windowNumber)")
        fflush(stdout)
        Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { _ in exit(0) }
    }
}

/// `CallCopilot --test-demo <me audio> <them audio> [--ask-at <seconds> <question>] [--dark]`: feeds a scripted call
/// through the real pipeline (on-device transcription, Claude, watchers, cards) at real-time pace, with a stage window
/// showing captions, for recording a demo. Prints the stage's screen rectangle and when the audio starts.
final class DemoRunner {
    let copilot = Copilot()
    var stage: NSWindow!
    var hud: HUDPanel!
    var ask: AskPanel!
    var asked = false
    var answeredAt: Date?

    init(me: URL, them: URL, askAt: Double?, question: String?, dark: Bool) {
        let screen = NSScreen.main!
        let v = screen.visibleFrame
        let rect = NSRect(x: v.minX + 40, y: v.maxY - 720 - 30, width: 1180, height: 720)
        stage = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        stage.backgroundColor = K.paperNS
        stage.contentView = NSHostingView(rootView: StageView(copilot: copilot))
        hud = HUDPanel.make(copilot: copilot)
        hud.setFrame(NSRect(x: rect.maxX - 400, y: rect.minY + 20, width: 380, height: rect.height - 40), display: true)
        ask = AskPanel.make(copilot: copilot)
        ask.setFrameOrigin(NSPoint(x: rect.minX + 40, y: rect.minY + 70))
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        [stage, hud, ask].forEach { $0?.appearance = appearance }
        stage.orderFrontRegardless()
        hud.orderFrontRegardless()
        // Screen coordinates with the origin at the top left, as ScreenCaptureKit uses them.
        print("STAGE pid=\(getpid()) x=\(Int(rect.minX)) y=\(Int(screen.frame.maxY - rect.maxY)) w=\(Int(rect.width)) h=\(Int(rect.height))")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [self] in // time for the recorder to start
            print("DEMO_FEED_START \(Date().timeIntervalSince1970)")
            fflush(stdout)
            copilot.start(app: "Demo", auto: false, processes: [], testFiles: [("Me", me), ("Them", them)], realtime: true)
            if let askAt, let question {
                DispatchQueue.main.asyncAfter(deadline: .now() + askAt) { [self] in type(question) }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] _ in
            if case .failed(let e) = copilot.phase { print("FAILED \(e)"); exit(1) }
            if asked, !copilot.asking, copilot.answer != nil, answeredAt == nil { answeredAt = Date() }
            if let at = answeredAt, Date().timeIntervalSince(at) > 12 { print("DEMO_DONE"); fflush(stdout); exit(0) }
        }
    }

    /// Shows the ask bar and types the question into it without taking the keyboard, then asks.
    private func type(_ question: String) {
        ask.orderFrontRegardless()
        var i = 0
        Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [self] t in
            i += 1
            copilot.demoTyping = String(question.prefix(i))
            guard i >= question.count else { return }
            t.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
                copilot.ask(question)
                asked = true
                copilot.demoTyping = nil
                ask.orderOut(nil)
            }
        }
    }
}

/// The demo's backdrop: what's being said, as captions.
struct StageView: View {
    @ObservedObject var copilot: Copilot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MonoLabel(text: "Simulated call", size: 11, bullet: K.red)
                Spacer()
                MonoLabel(text: "Call Copilot demo", size: 11, color: K.muted)
            }
            .padding(.horizontal, 28).frame(height: 52)
            Hairline()
            VStack(alignment: .leading, spacing: 16) {
                MonoLabel(text: "What's being said", size: 10, color: K.muted)
                ForEach(Array(copilot.recentLines.suffix(5).enumerated()), id: \.offset) { i, line in
                    let isThem = line.hasPrefix("[Them]")
                    let text = line.replacingOccurrences(of: isThem ? "[Them] " : "[Me] ", with: "")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isThem ? "THEM · OPERATIONS LEAD" : "ME · CONSULTANT").font(K.mono(9.5)).tracking(0.6)
                            .foregroundStyle(isThem ? K.accentInk : K.muted)
                        Text(text).font(K.sans(19, weight: i == copilot.recentLines.suffix(5).count - 1 ? .medium : .regular))
                            .foregroundStyle(K.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(28)
            .frame(width: 720, alignment: .leading)
            Spacer()
            Text("The audio is a scripted conversation fed to the app. Transcription, Claude, the watchers and the cards are live.")
                .font(K.sans(12)).foregroundStyle(K.muted)
                .padding(.horizontal, 28).padding(.bottom, 22)
                .frame(width: 740, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(K.paper)
    }
}

let args = CommandLine.arguments
let app = NSApplication.shared
var testRunner: TestRunner?
var previewRunner: PreviewRunner?
var demoRunner: DemoRunner?
let delegate = AppDelegate()
if let i = args.firstIndex(of: "--test-file"), i + 1 < args.count {
    let ask = args.firstIndex(of: "--ask").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    app.setActivationPolicy(.prohibited)
    testRunner = TestRunner(file: URL(fileURLWithPath: args[i + 1]), ask: ask)
} else if let i = args.firstIndex(of: "--test-demo"), i + 2 < args.count {
    let askAt = args.firstIndex(of: "--ask-at").flatMap { $0 + 2 < args.count ? Double(args[$0 + 1]) : nil }
    let question = args.firstIndex(of: "--ask-at").flatMap { $0 + 2 < args.count ? args[$0 + 2] : nil }
    app.setActivationPolicy(.accessory)
    demoRunner = DemoRunner(me: URL(fileURLWithPath: args[i + 1]), them: URL(fileURLWithPath: args[i + 2]),
                            askAt: askAt, question: question, dark: args.contains("--dark"))
} else if let i = args.firstIndex(of: "--test-preview") {
    app.setActivationPolicy(.accessory)
    previewRunner = PreviewRunner(dark: i + 1 < args.count && args[i + 1] == "dark")
} else {
    // One copy only: a second one (say, a build opened from elsewhere) would add a second menu-bar icon.
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        .filter { $0.processIdentifier != getpid() }
    if let other = others.first {
        log("another copy is running (pid \(other.processIdentifier)); quitting \(Bundle.main.bundlePath)")
        exit(0)
    }
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
}
app.run()
