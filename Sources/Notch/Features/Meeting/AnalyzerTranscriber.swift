@preconcurrency import AVFoundation
import Speech

/// What MeetingService needs from a live speech-to-text stream.
@MainActor
protocol SpeechStream: AnyObject, Sendable {
    /// (segment id, text so far, isFinal)
    var onText: (UUID, String, Bool) -> Void { get set }
    var onError: (String) -> Void { get set }
    var onDevice: Bool { get }
    /// Starts listening; returns an error message instead of throwing.
    func begin() async -> String?
    func stop()
    nonisolated func append(_ b: AVAudioPCMBuffer)
    nonisolated func append(_ sb: CMSampleBuffer)
}

enum Speech2 {
    /// macOS 26's SpeechAnalyzer when available (several can run at once, fast, accurate);
    /// otherwise the older SFSpeechRecognizer (only one on-device stream at a time).
    @MainActor
    static func make(locale: String) -> any SpeechStream {
        if #available(macOS 26.0, *) { return AnalyzerTranscriber(locale: locale) }
        return Transcriber(locale: locale)
    }

    /// ScreenCaptureKit hands over CMSampleBuffers; the analyzer wants AVAudioPCMBuffers.
    nonisolated static func pcm(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = sb.formatDescription, var asbd = desc.audioStreamBasicDescription,
              let fmt = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(sb.numSamples)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames),
                                                          into: buf.mutableAudioBufferList) == noErr else { return nil }
        return buf
    }
}

@available(macOS 26.0, *)
@MainActor
final class AnalyzerTranscriber: SpeechStream {
    var onText: (UUID, String, Bool) -> Void = { _, _, _ in }
    var onError: (String) -> Void = { _ in }
    let onDevice = true

    private let module: any SpeechModule
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var current: UUID?
    private let hindi: Bool

    private let lock = NSLock()
    nonisolated(unsafe) private var input: AsyncStream<AnalyzerInput>.Continuation?
    nonisolated(unsafe) private var target: AVAudioFormat?
    nonisolated(unsafe) private var converter: AVAudioConverter?

    init(locale: String) {
        let loc = Locale(identifier: locale)
        hindi = locale.hasPrefix("hi")
        if locale.hasPrefix("hi") {
            // Hindi is only offered by the dictation model.
            module = DictationTranscriber(locale: loc, contentHints: [], transcriptionOptions: [.punctuation],
                                          reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
        } else {
            module = SpeechTranscriber(locale: loc, transcriptionOptions: [],
                                       reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        }
    }

    func begin() async -> String? {
        do {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                MeetingService.shared.status = "Downloading the speech model (one time)…"; VoiceService.shared.status = MeetingService.shared.status
                try await req.downloadAndInstall()
            }
            target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
            let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
            input = cont
            let a = SpeechAnalyzer(modules: [module])
            analyzer = a
            resultsTask = Task { [weak self] in await self?.readResults() }
            try await a.start(inputSequence: stream)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func readResults() async {
        do {
            if let st = module as? SpeechTranscriber {
                for try await r in st.results { handle(String(r.text.characters), r.isFinal) }
            } else if let dt = module as? DictationTranscriber {
                for try await r in dt.results { handle(String(r.text.characters), r.isFinal) }
            }
        } catch {
            onError(error.localizedDescription)
        }
    }

    /// Volatile results keep updating the current line; a final result closes it.
    private func handle(_ text: String, _ final: Bool) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Hindi comes back in Devanagari; show it in Roman letters like Hinglish chat.
        if hindi { t = Self.roman(t) }
        guard !t.isEmpty else { if final { current = nil }; return }
        let id = current ?? UUID()
        current = final ? nil : id
        onText(id, t, final)
    }

    /// "क्या आप हैं" → "kya apa hain" (anusvara as n, accents dropped).
    nonisolated static func roman(_ s: String) -> String {
        // Scalar-level: ं sits inside a grapheme, so String replacing misses it.
        var u = String.UnicodeScalarView()
        for c in s.unicodeScalars { if c == "\u{902}" { u.append("\u{928}"); u.append("\u{94D}") } else { u.append(c) } }
        return String(u).applyingTransform(StringTransform("Devanagari-Latin; Latin-ASCII"), reverse: false) ?? s
    }

    func stop() {
        lock.lock(); input?.finish(); input = nil; lock.unlock()
        let a = analyzer
        analyzer = nil
        Task { try? await a?.finalizeAndFinishThroughEndOfInput() }
    }

    nonisolated func append(_ sb: CMSampleBuffer) {
        if let b = Speech2.pcm(sb) { append(b) }
    }

    /// Converts to the analyzer's format (e.g. 48 kHz mic → 16 kHz) and queues it. Audio thread.
    nonisolated func append(_ b: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let input, let target, b.frameLength > 0 else { return }
        if b.format == target { input.yield(AnalyzerInput(buffer: b)); return }
        if converter == nil || converter?.inputFormat != b.format { converter = AVAudioConverter(from: b.format, to: target) }
        guard let conv = converter else { return }
        let cap = AVAudioFrameCount(Double(b.frameLength) * target.sampleRate / b.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return b
        }
        if out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }
}
