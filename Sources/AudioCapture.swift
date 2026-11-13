import AVFoundation
import CoreAudio
import Foundation

struct CaptureError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Retries a failed restart after 0.5, 1, 2 and 5 s, then reports the failure.
private func retrying(_ what: String, attempt: Int = 0, _ body: @escaping () throws -> Void,
                      failed: @escaping (String) -> Void) {
    let delays: [TimeInterval] = [0.5, 1, 2, 5]
    do { try body() } catch {
        guard attempt < delays.count else {
            log("\(what): restart failed for good: \(error)")
            failed("\(error)")
            return
        }
        log("\(what): restart failed (\(error)); retrying")
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) {
            retrying(what, attempt: attempt + 1, body, failed: failed)
        }
    }
}

/// Your side: the default input device, via AVAudioEngine. Restarts when the device changes (for example when a
/// call app switches AirPods into headset mode).
final class MicCapture {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// A restart that kept failing. Called on the main queue.
    var onFailure: ((String) -> Void)?
    private var engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var running = false

    func start() throws {
        running = true
        try startEngine()
    }

    private func startEngine() throws {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        let engine = AVAudioEngine()
        self.engine = engine
        // Observe before starting, so a change during start isn't missed.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in self?.restart() }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError("no microphone input available") }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in self?.onBuffer?(buf) }
        engine.prepare()
        try engine.start()
    }

    private func restart() {
        guard running else { return }
        log("mic: device changed, restarting")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        retrying("mic", { [weak self] in
            guard let self, self.running else { return }
            try self.startEngine()
        }, failed: { [weak self] in self?.onFailure?($0) })
    }

    func stop() {
        running = false
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// The other side, via a Core Audio process tap hosted by a tap-only private aggregate device (as in Apple's
/// "Capturing system audio with Core Audio taps"). Taps only the call app's processes; with no targets it taps
/// everything the Mac plays. Rebuilds when the tap's format, the device's sample rate or the default output changes,
/// because buffers read with a stale format come out garbled or silent.
final class SystemAudioCapture {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// A rebuild that kept failing. Called on the main queue.
    var onFailure: ((String) -> Void)?
    private(set) var targets: [AudioObjectID]?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private let queue = DispatchQueue(label: "call-copilot.system-audio", qos: .userInitiated)
    private var running = false
    private var rebuildPending = false
    /// Bumped by each scheduled rebuild and by stop(); a retry chain from an older rebuild stops quietly.
    private var rebuildToken = 0
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var warnedLayout = false

    /// `targets` nil = everything the Mac plays.
    init(targets: [AudioObjectID]?) { self.targets = targets }

    func start() throws {
        running = true
        do { try build() } catch { teardown(); throw error }
    }

    func retarget(_ new: [AudioObjectID]?) {
        guard running, new != targets else { return }
        targets = new
        log("system audio: call app processes changed, rebuilding")
        scheduleRebuild()
    }

    /// Rebuild now (for example when the tap has gone silent).
    func rebuild() { scheduleRebuild() }

    func stop() {
        running = false
        rebuildToken += 1
        teardown()
    }

    private func scheduleRebuild() {
        guard running, !rebuildPending else { return }
        rebuildPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in // coalesce bursts of notifications
            guard let self, self.running else { return }
            self.rebuildPending = false
            self.rebuildToken += 1
            let token = self.rebuildToken
            self.teardown()
            retrying("system audio", { [weak self] in
                guard let self, self.running, token == self.rebuildToken else { return } // superseded
                do { try self.build() } catch { self.teardown(); throw error }
            }, failed: { [weak self] in
                guard let self, token == self.rebuildToken else { return }
                self.onFailure?($0)
            })
        }
    }

    private func build() throws {
        if tapID != kAudioObjectUnknown || aggID != kAudioObjectUnknown { teardown() } // never leak a running tap
        let desc: CATapDescription
        if let targets, !targets.isEmpty {
            desc = CATapDescription(stereoMixdownOfProcesses: targets)
        } else {
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        desc.uuid = UUID()
        desc.name = "Call Copilot"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw CaptureError("couldn't create the call-audio tap (\(err))") }

        var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &size, &asbd)
        guard err == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError("couldn't read the tap's audio format (\(err))")
        }
        format = fmt

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Call Copilot Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        err = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
        guard err == noErr else { throw CaptureError("couldn't create the capture device (\(err))") }

        let channels = Int(fmt.channelCount), interleaved = fmt.isInterleaved
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { [weak self] _, inInput, _, _, _ in
            guard let self, let fmt = self.format else { return }
            // The buffer list must be exactly the tap's stream; anything else would be read with the wrong layout.
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            let ok = interleaved ? (list.count == 1 && Int(list[0].mNumberChannels) == channels)
                                 : (list.count == channels)
            guard ok else {
                if !self.warnedLayout { self.warnedLayout = true; log("system audio: unexpected buffer layout, dropping") }
                return
            }
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inInput, deallocator: nil) else { return }
            self.onBuffer?(buf) // the consumer converts (copies) synchronously
        }
        guard err == noErr else { throw CaptureError("couldn't attach to the capture device (\(err))") }
        err = AudioDeviceStart(aggID, procID)
        guard err == noErr else { throw CaptureError("couldn't start call-audio capture (\(err))") }

        builtOutput = Self.defaultOutput()
        listen(tapID, kAudioTapPropertyFormat)
        listen(aggID, kAudioDevicePropertyNominalSampleRate)
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        log("system audio: capturing \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch, "
            + (targets?.isEmpty == false ? "\(targets!.count) call-app process(es)" : "all audio"))
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                // Notifications also fire while a device settles; rebuild only for a real change, or we'd loop.
                guard let self, self.changedSinceBuild() else { return }
                log("system audio: format or device changed, rebuilding")
                self.scheduleRebuild()
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &addr, DispatchQueue.main, block) == noErr {
            listeners.append((object, addr, block))
        }
    }

    private var builtOutput = AudioObjectID(kAudioObjectUnknown)

    /// Whether the tap's format, the device's sample rate or the default output differ from what was built.
    private func changedSinceBuild() -> Bool {
        guard running, let fmt = format, tapID != kAudioObjectUnknown else { return false }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr,
           asbd.mSampleRate != fmt.sampleRate || asbd.mChannelsPerFrame != fmt.channelCount { return true }
        var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        size = UInt32(MemoryLayout<Float64>.size)
        if aggID != kAudioObjectUnknown, AudioObjectGetPropertyData(aggID, &rateAddr, 0, nil, &size, &rate) == noErr,
           rate > 0, rate != fmt.sampleRate { return true }
        return Self.defaultOutput() != builtOutput
    }

    private static func defaultOutput() -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return dev
    }

    private func teardown() {
        for (object, addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(object, &a, DispatchQueue.main, block)
        }
        listeners = []
        if aggID != kAudioObjectUnknown {
            if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}
