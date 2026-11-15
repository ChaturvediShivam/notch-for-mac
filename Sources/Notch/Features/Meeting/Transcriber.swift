import AVFoundation
import Speech

/// One continuous speech-to-text stream (one speaker source). Splits into segments on a
/// short pause or every 50 s (Apple's server recognition stops after about a minute), and
/// swaps in the next request *before* ending the old one so no audio is dropped.
@MainActor
final class Transcriber: SpeechStream {
    /// (segment id, text so far, isFinal)
    var onText: (UUID, String, Bool) -> Void = { _, _, _ in }
    var onError: (String) -> Void = { _ in }

    private let recognizer: SFSpeechRecognizer?
    nonisolated(unsafe) private var live: SFSpeechAudioBufferRecognitionRequest?
    private var tasks: [UUID: SFSpeechRecognitionTask] = [:]
    private var current: UUID?
    private var pauseWork: DispatchWorkItem?
    private var maxWork: DispatchWorkItem?
    private var running = false
    private let allowOnDevice: Bool

    /// Only one on-device recognition runs at a time on macOS, so a second, simultaneous
    /// transcriber must use Apple's server recognition (`onDevice: false`).
    init(locale: String, onDevice: Bool = true) {
        allowOnDevice = onDevice
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) ?? SFSpeechRecognizer()
    }

    var available: Bool { recognizer?.isAvailable == true }
    var onDevice: Bool { allowOnDevice && recognizer?.supportsOnDeviceRecognition == true }

    func start() { running = true; roll() }

    func begin() async -> String? {
        guard available else { return "Speech recognition for this language isn't available right now." }
        start()
        return nil
    }

    func stop() {
        running = false
        pauseWork?.cancel(); maxWork?.cancel()
        live?.endAudio(); live = nil
    }

    // Called from audio threads; appending to a request is thread-safe.
    nonisolated func append(_ b: AVAudioPCMBuffer) { live?.append(b) }
    nonisolated func append(_ sb: CMSampleBuffer) { live?.appendAudioSampleBuffer(sb) }

    private func roll() {
        let old = live
        pauseWork?.cancel(); maxWork?.cancel()
        guard running, let recognizer else { old?.endAudio(); return }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.addsPunctuation = true
        r.requiresOnDeviceRecognition = onDevice
        let id = UUID()
        current = id
        live = r
        tasks[id] = recognizer.recognitionTask(with: r) { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    self?.update(id, text, final: final, failed: failed, error: error)
                }
            }
        }
        old?.endAudio()
        let w = DispatchWorkItem { [weak self] in self?.roll() }
        maxWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 50, execute: w)
    }

    private func update(_ id: UUID, _ text: String?, final: Bool, failed: Bool, error: Error?) {
        if let text, !text.isEmpty { onText(id, text, final || failed) }
        if final || failed { tasks[id] = nil }
        if failed, id == current, running {
            // 1110 = no speech heard (silence): just start a fresh segment. Everything is logged.
            if let e = error as NSError? {
                MeetingService.shared.log("recognition ended: \(e.domain) \(e.code) \(e.localizedDescription)")
                if e.code != 1110, e.code != 216 { onError(e.localizedDescription) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.current == id else { return }
                self.roll()
            }
            return
        }
        // New words in the current segment: a 1.6 s pause ends the line.
        guard id == current, !final, text?.isEmpty == false else { return }
        pauseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.roll() }
        pauseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: w)
    }
}

extension Transcriber {
    /// `NOTCH_TEST_AUDIO=<file> open build/Notch.app`: transcribe a file into ~/.notch/test-transcript.txt and quit.
    static func testFile(_ path: String) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let out = Paths.home.appendingPathComponent("test-transcript.txt")
                    guard status == .authorized, let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
                        try? "speech not authorized or bad file (status \(status.rawValue))".write(to: out, atomically: true, encoding: .utf8)
                        exit(1)
                    }
                    // NOTCH_TEST_PARALLEL=2 runs two recognisers on the same audio (like Them + Me).
                    let count = Int(ProcessInfo.processInfo.environment["NOTCH_TEST_PARALLEL"] ?? "1") ?? 1
                    var segs: [UUID: String] = [:], order: [UUID] = []
                    let all = (0..<count).map { k -> any SpeechStream in
                        let t = Speech2.make(locale: Store.shared.config.meetingLocale)
                        t.onText = { id, text, _ in if segs[id] == nil { order.append(id) }; segs[id] = "[\(k)] " + text }
                        Task { if let e = await t.begin() { segs[UUID()] = "error: \(e)" } }
                        return t
                    }
                    // Feed in 0.25 s chunks at real-time pace so pause detection behaves as live.
                    let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 4)
                    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
                        guard let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                              (try? file.read(into: b, frameCount: chunk)) != nil, b.frameLength > 0 else {
                            timer.invalidate()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                                MainActor.assumeIsolated {
                                    all.forEach { $0.stop() }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {   // let final results land
                                        let text = order.compactMap { segs[$0] }.joined(separator: "\n")
                                        try? "segments: \(order.count)\n\(text)".write(to: out, atomically: true, encoding: .utf8)
                                        exit(0)
                                    }
                                }
                            }
                            return
                        }
                        all.forEach { $0.append(b) }
                    }
                }
            }
        }
    }
}
