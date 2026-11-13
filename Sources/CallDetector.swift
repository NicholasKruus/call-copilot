import CoreAudio
import Foundation

/// Core Audio's per-process audio objects (macOS 14+): who is using input and output.
enum AudioProcesses {
    struct Proc { let object: AudioObjectID; let pid: pid_t; let bundleID: String; let input: Bool; let output: Bool }

    static func list() -> [Proc] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            Proc(object: id,
                 pid: pid_t(u32(id, kAudioProcessPropertyPID)),
                 bundleID: string(id, kAudioProcessPropertyBundleID) ?? "",
                 input: u32(id, kAudioProcessPropertyIsRunningInput) != 0,
                 output: u32(id, kAudioProcessPropertyIsRunningOutput) != 0)
        }
    }

    private static func u32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : 0
    }

    static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let s = cf else { return nil }
        return s.takeRetainedValue() as String
    }
}

/// What the call apps are doing right now.
struct CallSnapshot: Equatable {
    /// Call apps using the mic, by display name.
    var apps: [String] = []
    /// Audio objects of every process belonging to those apps (helpers included), Granola excepted: what "Them"
    /// taps. Granola records alongside calls but never plays the other side, so with only Granola this is empty and
    /// "Them" falls back to all audio.
    var processes: [AudioObjectID] = []
    /// Whether any of those processes is playing audio.
    var playing = false

    /// The app to show. Granola often records alongside the real call app, so another app wins.
    var primary: String? { apps.first { $0 != "Granola" } ?? apps.first }
}

/// Polls every 2 s, off the main thread, and reports each snapshot on the main queue.
final class CallDetector {
    var onUpdate: ((CallSnapshot) -> Void)?
    private(set) var latest = CallSnapshot()
    private let queue = DispatchQueue(label: "call-copilot.detector", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let myPID = getpid()

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let snap = self.snapshot()
            DispatchQueue.main.async {
                self.latest = snap
                self.onUpdate?(snap)
            }
        }
        t.resume()
        timer = t
    }

    func snapshot() -> CallSnapshot {
        let procs = AudioProcesses.list().filter { $0.pid != myPID && !$0.bundleID.isEmpty }
        func app(_ p: AudioProcesses.Proc) -> (prefix: String, name: String)? {
            Config.callApps.first { p.bundleID.hasPrefix($0.prefix) }
        }
        let active = procs.filter(\.input).compactMap(app)
        let names = active.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let tapped = names.filter { $0 != "Granola" }
        let members = procs.filter { p in app(p).map { a in tapped.contains(a.name) } ?? false }
        return CallSnapshot(apps: names, processes: members.map(\.object).sorted(), playing: members.contains(where: \.output))
    }
}
