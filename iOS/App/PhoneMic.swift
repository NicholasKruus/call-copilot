import AVFoundation

/// The iPhone's microphone for one listening session. It keeps going with the screen locked or another app open
/// (the app's audio background mode). A phone call or another app that records interrupts it; it resumes when the
/// interruption ends, or, if iOS won't allow that from the background, when the app is next opened.
final class PhoneMic {
    /// Called on an audio thread.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// true: interrupted; false: running again. Main queue.
    var onInterruption: ((Bool) -> Void)?
    /// The mic stopped and couldn't be restarted. Main queue.
    var onFailure: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var observers: [NSObjectProtocol] = []
    private(set) var running = false
    private(set) var interrupted = false
    private var lastRestart = Date.distantPast

    func start() throws {
        try Self.configureSession()
        try startEngine()
        observe()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Tries to get the mic going again after an interruption or an audio change.
    @discardableResult
    func restart() -> Bool {
        lastRestart = Date()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        do {
            try Self.configureSession()
            try startEngine()
            interrupted = false
            log("mic: running again")
            return true
        } catch {
            log("mic: restart failed: \(error)")
            return false
        }
    }

    /// Recording only (nothing plays), from the built-in mic or a wired one. Bluetooth headsets aren't used: in a
    /// meeting room their mic hears only the wearer.
    private static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError("no microphone input available") }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in self?.onBuffer?(buffer) }
        engine.prepare()
        try engine.start()
        running = true
    }

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) {
            [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                log("mic: interrupted")
                self.running = false
                self.interrupted = true
                self.onInterruption?(true)
            case .ended:
                if self.restart() { self.onInterruption?(false) }
                else { self.onFailure?("Paused: open Call Copilot to start the microphone again.") }
            @unknown default:
                break
            }
        })
        // A new route (headphones in or out) or sample rate stops the engine.
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) {
            [weak self] _ in
            // A restart can itself post this; ignore those, so it can't loop.
            guard let self, !self.interrupted, Date().timeIntervalSince(self.lastRestart) > 2 else { return }
            log("mic: audio configuration changed; restarting")
            if !self.restart() { self.onFailure?("The microphone stopped after an audio change. Open Call Copilot to resume.") }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            guard let self else { return }
            log("mic: media services were reset; restarting")
            if !self.restart() { self.onFailure?("The microphone stopped. Open Call Copilot to resume.") }
        })
    }
}
