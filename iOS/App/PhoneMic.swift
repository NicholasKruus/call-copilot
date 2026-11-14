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

    private var engine = AVAudioEngine()
    private var observers: [NSObjectProtocol] = []
    private(set) var running = false
    private(set) var interrupted = false
    private var lastRestart = Date.distantPast

    func start() throws {
        do {
            try Self.configureSession()
            try startEngine()
        } catch {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
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
    func restart(newEngine: Bool = false) -> Bool {
        lastRestart = Date()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if newEngine { engine = AVAudioEngine() } // after a media-services reset the old engine can't run again
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
        // nil: the tap takes whatever the hardware delivers, so a format change between the check and here can't
        // raise an exception (the transcriber converts any format).
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in self?.onBuffer?(buffer) }
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
                // Resume only when iOS says so: after a phone call the user may be somewhere they don't want recorded.
                let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                guard AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume) else {
                    self.onFailure?("Paused: open Call Copilot to start listening again.")
                    return
                }
                if self.restart() { self.onInterruption?(false) }
                else { self.onFailure?("Paused: open Call Copilot to start the microphone again.") }
            @unknown default:
                break
            }
        })
        // A new route (headphones in or out) or sample rate stops the engine.
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) {
            [weak self] note in
            guard let self, (note.object as AnyObject?) === self.engine else { return } // the current engine, if replaced
            // A restart can itself post this; ignore those, so it can't loop.
            guard !self.interrupted, Date().timeIntervalSince(self.lastRestart) > 2 else { return }
            log("mic: audio configuration changed; restarting")
            if !self.restart() { self.onFailure?("The microphone stopped after an audio change. Open Call Copilot to resume.") }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            guard let self else { return }
            log("mic: media services were reset; restarting")
            if !self.restart(newEngine: true) { self.onFailure?("The microphone stopped. Open Call Copilot to resume.") }
        })
    }
}
