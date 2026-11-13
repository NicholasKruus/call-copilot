import AVFoundation
import Foundation
import Speech

/// On-device transcription of one audio source with Apple's SpeechAnalyzer (macOS 26+).
/// Audio never leaves the Mac; only finished text is handed on.
final class SourceTranscriber {
    let label: String
    var onFinal: ((String) -> Void)?
    /// The results stream ended while the source was still meant to be running.
    var onEnded: ((String) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    private var finishing = false
    private var warnedDrop = false
    // Guards everything append() touches: a mic restart can briefly have two audio threads calling it.
    private let lock = NSLock()
    private var _lastAudio = Date.distantPast
    private var _lastNonZero = Date()

    init(label: String) { self.label = label }

    /// When audible audio last arrived.
    var lastAudio: Date { lock.lock(); defer { lock.unlock() }; return _lastAudio }
    /// When any non-zero sample last arrived. A tap without permission, or a stalled one, delivers exact zeros.
    var lastNonZero: Date { lock.lock(); defer { lock.unlock() }; return _lastNonZero }

    static func locale() async -> Locale {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
    }

    func start(locale: Locale) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            log("speech: downloading the \(locale.identifier) model")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw CaptureError("speech model gave no audio format")
        }
        // Live audio is bounded (tap buffers are ~10 ms, mic buffers ~85 ms, so 6000 is a minute or more), so a
        // stalled analyzer drops old audio instead of piling it up. A test file is fed faster than real time and
        // must not lose its start, so it is unbounded.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: Config.isTestRun ? .unbounded : .bufferingNewest(6000))
        lock.lock()
        targetFormat = format
        self.continuation = continuation
        _lastNonZero = Date()
        lock.unlock()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        resultsTask = Task { [weak self, label] in
            do {
                for try await result in transcriber.results where result.isFinal {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { self?.onFinal?(text) }
                }
            } catch {
                log("speech[\(label)]: results ended: \(error)")
            }
            if let self, !self.finishing { self.onEnded?(label) }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Called on a capture thread. Converts synchronously, so the caller's buffer may be reused afterwards.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        updateLevel(buffer)
        guard let continuation, let out = convert(buffer) else { return }
        if case .dropped = continuation.yield(AnalyzerInput(buffer: out)), !warnedDrop {
            warnedDrop = true
            log("speech[\(label)]: falling behind; dropping old audio")
        }
    }

    func finish() async {
        finishing = true
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.finish()
        do { try await analyzer?.finalizeAndFinishThroughEndOfInput() } catch { log("speech[\(label)]: finish: \(error)") }
        _ = await resultsTask?.value
        analyzer = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = targetFormat, buffer.frameLength > 0 else { return nil }
        if converter == nil || converter!.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { return nil }
        return out.frameLength > 0 ? out : nil
    }

    private func updateLevel(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength), stride = buffer.stride
        guard n > 0 else { return }
        var sum: Float = 0
        var nonZero = false
        for i in 0..<n {
            let s = data[0][i * stride]
            sum += s * s
            if s != 0 { nonZero = true }
        }
        let now = Date()
        if sqrt(sum / Float(n)) > 0.003 { _lastAudio = now }
        if nonZero { _lastNonZero = now }
    }
}

extension SourceTranscriber {
    /// Transcribes an audio file instead of live audio (tests and demos). `realtime` feeds it at its own pace, as if
    /// live; otherwise as fast as the analyzer takes it.
    func feed(file: URL, realtime: Bool) async throws {
        let f = try AVAudioFile(forReading: file)
        let chunk: AVAudioFrameCount = 4800
        let start = Date()
        var fed: Double = 0
        while f.framePosition < f.length, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: chunk) {
            try f.read(into: buf, frameCount: min(chunk, AVAudioFrameCount(f.length - f.framePosition)))
            if buf.frameLength == 0 { break }
            append(buf)
            if realtime {
                fed += Double(buf.frameLength) / f.processingFormat.sampleRate
                let ahead = fed - Date().timeIntervalSince(start)
                if ahead > 0 { try await Task.sleep(nanoseconds: UInt64(ahead * 1e9)) }
            }
        }
    }
}
