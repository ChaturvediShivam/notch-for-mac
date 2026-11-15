import AppKit
import AVFoundation
import ScreenCaptureKit
import Speech

struct Suggestion: Identifiable {
    let id = UUID()
    let title: String            // the question heard, or "Samjhao" / "Summary"
    var text = ""
    let auto: Bool
    var done = false
    var failed: String?
    let time = Date()
}

struct MeetLine: Identifiable, Equatable {
    let id: UUID
    let speaker: String          // "Me" or "Them"
    var text: String
    let time: Date
    var final: Bool
}

/// Meeting mode: transcribes the other people (Mac's audio, via ScreenCaptureKit) and you
/// (microphone) at the same time, labelled Them / Me, and lets you ask Claude about it.
@MainActor
final class MeetingService: NSObject, ObservableObject {
    static let shared = MeetingService()

    @Published private(set) var lines: [MeetLine] = []
    @Published private(set) var active = false
    @Published private(set) var startedAt: Date?
    @Published var status = ""
    @Published var question = ""
    @Published private(set) var savedTo: URL?
    /// 0...1 loudness of what reaches us, so you can see each side is being heard.
    @Published private(set) var themLevel: Double = 0
    @Published private(set) var meLevel: Double = 0
    @Published private(set) var needsScreenPermission = false
    /// Live answers: when someone asks a question, Claude suggests a reply without a click.
    @Published var autoAnswer = true
    @Published private(set) var suggestions: [Suggestion] = []
    private var running: Task<Void, Never>?
    private var pending: (title: String, prompt: String, auto: Bool)?
    private var answered = Set<UUID>()

    nonisolated(unsafe) private static var themPeak: Float = 0, mePeak: Float = 0
    nonisolated(unsafe) private static var themBuffers = 0, meBuffers = 0
    private var meterTimer: Timer?
    private var lastLog = Date.distantPast

    private var them: (any SpeechStream)? { didSet { Self.themTap = them } }
    /// Same transcriber, reachable from ScreenCaptureKit's audio queue.
    nonisolated(unsafe) private static var themTap: (any SpeechStream)?
    private var me: (any SpeechStream)?
    private var questionWork: DispatchWorkItem?
    private var stream: SCStream?
    private let engine = AVAudioEngine()

    static let languages: [(id: String, name: String)] = [
        ("en-IN", "Hindi + English (Hinglish)"), ("hi-IN", "Hindi only (देवनागरी)"),
        ("en-US", "English (US)"), ("en-GB", "English (UK)"),
    ]

    func toggle() { if active { stop() } else { Task { await start() } } }

    /// Step-by-step log for troubleshooting: ~/.notch/meeting.log
    func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date()))  \(s)\n"
        let url = Paths.home.appendingPathComponent("meeting.log")
        DispatchQueue.global(qos: .utility).async {
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func start() async {
        guard !active else { return }
        log("— Start pressed. language=\(Store.shared.config.meetingLocale) output=\(AudioService.shared.outputs.first { $0.id == AudioService.shared.defaultOutput }?.name ?? "?") input=\(AudioService.shared.inputs.first { $0.id == AudioService.shared.defaultInput }?.name ?? "?")")
        if VoiceService.shared.mode == .dictating { VoiceService.shared.stopDictation() }
        if VoiceService.shared.mode == .listening { VoiceService.shared.stopListen() }
        NotchModel.shared.show(.meeting)

        // Permissions, asked the first time: Speech, Microphone, Screen Recording (for meeting audio).
        let speech: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        log("speech permission: \(speech.rawValue) (3 = allowed)")
        guard speech == .authorized else { status = "Allow Speech Recognition for Notch in System Settings → Privacy & Security."; return }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        log("microphone permission: \(mic)")

        let locale = Store.shared.config.meetingLocale
        let t = Speech2.make(locale: locale), m = Speech2.make(locale: locale)
        log("engine=\(String(describing: type(of: t))) onDevice=\(t.onDevice)")
        for (tr, who) in [(t, "Them"), (m, "Me")] {
            tr.onText = { [weak self] id, text, final in self?.upsert(id, who, text, final) }
            tr.onError = { [weak self] e in self?.status = e; self?.log("\(who) recognition error: \(e)") }
        }
        them = t; me = m
        lines = []; savedTo = nil; suggestions = []; answered = []
        if let e = await t.begin() {
            status = "Speech engine error: \(e)"; log("them engine FAILED: \(e)"); them = nil; me = nil; return
        }
        status = t.onDevice ? "Transcribing on this Mac" : "Transcribing with Apple's speech service (this language has no on-device model)"

        // Other people: the Mac's audio output.
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw NSError(domain: "Notch", code: 1) }
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 16000
            cfg.channelCount = 1
            cfg.width = 2; cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            try await s.startCapture()
            stream = s
            needsScreenPermission = false
            log("system audio capture started")
        } catch {
            t.stop()
            log("system audio capture FAILED: \(error.localizedDescription)")
            needsScreenPermission = true
            status = "Can't hear the meeting: turn on Notch under Screen & System Audio Recording, then quit and reopen Notch."
            if !mic { them = nil; me = nil; return }
        }

        // You: the microphone.
        if mic {
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            // Echo cancellation: on speakers the mic also hears the other side. Apple's voice
            // processing removes most of it; leftovers are dropped by isEcho() below.
            do {
                try input.setVoiceProcessingEnabled(true)
                if #available(macOS 14.0, *) {
                    input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
                }
                log("voice processing (echo cancellation) on")
            } catch { log("voice processing unavailable: \(error.localizedDescription)") }
            installMicTap(input, m)
            if let e = await m.begin() { log("me engine FAILED: \(e)") }
            do { try engine.start(); log("microphone started") }
            catch {
                // Some devices refuse voice processing: retry plain.
                log("microphone with voice processing failed: \(error.localizedDescription); retrying without")
                input.removeTap(onBus: 0)
                try? input.setVoiceProcessingEnabled(false)
                installMicTap(input, m)
                do { try engine.start(); log("microphone started (no echo cancellation)") }
                catch { m.stop(); status = "Microphone error: \(error.localizedDescription)"; log("microphone FAILED: \(error.localizedDescription)") }
            }
        } else {
            status = "Microphone not allowed: only the other side is transcribed."
        }

        active = true
        startedAt = Date()
        Self.themBuffers = 0; Self.meBuffers = 0
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingService.shared.tickMeters() }
        }
        NSSound(named: "Morse")?.play()
    }

    func stop() {
        guard active else { return }
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        running?.cancel(); running = nil; pending = nil
        questionWork?.cancel()
        them?.stop(); me?.stop()
        meterTimer?.invalidate(); meterTimer = nil
        themLevel = 0; meLevel = 0
        log("stopped. lines=\(lines.count) themBuffers=\(Self.themBuffers) meBuffers=\(Self.meBuffers)")
        active = false
        // Let the last segments finish, then save.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.save() }
    }

    private func tickMeters() {
        themLevel = Double(min(1, Self.themPeak * 4)); meLevel = Double(min(1, Self.mePeak * 4))
        Self.themPeak *= 0.5; Self.mePeak *= 0.5
        if Date().timeIntervalSince(lastLog) > 10 {
            lastLog = Date()
            log(String(format: "audio so far: them buffers=%d level=%.2f, me buffers=%d level=%.2f, lines=%d",
                       Self.themBuffers, themLevel, Self.meBuffers, meLevel, lines.count))
        }
    }

    /// Voice processing hands the mic over as several channels; the recogniser wants plain mono,
    /// so channel 0 is copied into a mono Float32 buffer first.
    private func installMicTap(_ input: AVAudioInputNode, _ m: any SpeechStream) {
        let fmt = input.outputFormat(forBus: 0)
        log("mic format: \(fmt.channelCount) ch, \(Int(fmt.sampleRate)) Hz, \(fmt.commonFormat == .pcmFormatFloat32 ? "float32" : "other"), interleaved=\(fmt.isInterleaved)")
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fmt.sampleRate, channels: 1, interleaved: false) else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in
            guard let src = buf.floatChannelData, buf.frameLength > 0,
                  let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buf.frameLength) else { return }
            let n = Int(buf.frameLength)
            out.frameLength = buf.frameLength
            if fmt.isInterleaved && fmt.channelCount > 1 {
                let stride = Int(fmt.channelCount)
                for i in 0..<n { out.floatChannelData![0][i] = src[0][i * stride] }
            } else {
                out.floatChannelData![0].update(from: src[0], count: n)
            }
            m.append(out)
            MeetingService.meBuffers += 1
            MeetingService.mePeak = max(MeetingService.mePeak, MeetingService.peak(out.floatChannelData![0], n))
        }
    }

    nonisolated static func peak(_ p: UnsafePointer<Float>, _ n: Int) -> Float {
        var m: Float = 0
        for i in 0..<n { m = max(m, abs(p[i])) }
        return m
    }

    private func upsert(_ id: UUID, _ who: String, _ text: String, _ final: Bool) {
        // On speakers the mic picks up the other side too: drop "Me" text that repeats "Them".
        if who == "Me", isEcho(text) {
            lines.removeAll { $0.id == id }
            return
        }
        if let i = lines.lastIndex(where: { $0.id == id }) {
            lines[i].text = text; lines[i].final = final
        } else {
            lines.append(MeetLine(id: id, speaker: who, text: text, time: Date(), final: final))
        }
        guard who == "Them", autoAnswer, active, !answered.contains(id), Self.isQuestion(text) else { return }
        questionWork?.cancel()
        if final {
            answered.insert(id)
            autoSuggest(for: text)
        } else {
            // Don't wait for the sentence to be finalised: once the question text holds still
            // for a moment, answer it.
            let w = DispatchWorkItem { [weak self] in
                guard let self, !self.answered.contains(id),
                      let line = self.lines.last(where: { $0.id == id }) else { return }
                self.answered.insert(id)
                self.autoSuggest(for: line.text)
            }
            questionWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
        }
    }

    nonisolated private static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
    }

    /// True when most of these words were just said by the other side (last 12 s).
    func isEcho(_ text: String) -> Bool {
        let mine = Self.words(text)
        guard mine.count >= 2 else { return false }
        let recent = Date().addingTimeInterval(-12)
        let theirs = Set(lines.filter { $0.speaker == "Them" && $0.time >= recent }.flatMap { Self.words($0.text) })
        guard !theirs.isEmpty else { return false }
        let hits = mine.filter { theirs.contains($0) }.count
        return Double(hits) / Double(mine.count) >= 0.6
    }

    /// English and Hinglish/Hindi question cues. Speech recognition adds "?" for many English questions.
    nonisolated static func isQuestion(_ raw: String) -> Bool {
        let t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard words(t).count >= 3 else { return false }
        if t.hasSuffix("?") || t.contains("?") { return true }
        let w = words(t)
        let starts = ["what", "why", "how", "when", "where", "who", "which", "whose", "can", "could", "would", "will",
                      "do", "does", "did", "is", "are", "was", "were", "should", "shall", "have", "has", "may"]
        // First word as spoken (one-letter words like "I" count here, unlike in words()).
        let first = t.components(separatedBy: CharacterSet.alphanumerics.inverted).first { !$0.isEmpty }
        if let f = first, starts.contains(f) { return true }
        let anywhere: Set<String> = ["kya", "kyun", "kyon", "kaise", "kab", "kaun", "kaunsa", "kitna", "kitne", "kitni",
                                     "kahan", "kidhar"]
        let hindi: [String] = ["क्या", "क्यों", "कैसे", "कब", "कौन", "कितना", "कितने", "कितनी", "कहाँ", "कहां"]
        if w.contains(where: anywhere.contains) || hindi.contains(where: t.contains) { return true }
        for phrase in ["can you", "could you", "do you", "tell me", "explain", "bata sakte", "batao", "bataiye",
                       "sakte ho", "sakte hain", "sakti ho", "what about", "any idea", "your view", "thoughts on"] where t.contains(phrase) {
            return true
        }
        return false
    }

    // MARK: Live suggestions

    private func autoSuggest(for question: String) {
        let prompt = """
        I'm in a live meeting. Someone just asked me (speech-to-text, may have errors): "\(question)"

        Recent transcript ("Them" = other people, "Me" = me):
        \(transcript(lastMinutes: 4))

        Suggest what I can say right now: at most 3 short lines I can read aloud, natural and confident. \
        If it needs facts I might not know, give a safe answer, then one line starting "Check:". Nothing else. \
        Reply in the same language and style the question was asked in (Hinglish if they used Hinglish). No preamble.
        """
        run(title: question, prompt: prompt, auto: true)
        if !NotchModel.shared.isOpen { NotchModel.shared.show(.meeting) }
    }

    /// One answer at a time; a newer request waits (only the latest waiting one is kept).
    private func run(title: String, prompt: String, auto: Bool) {
        if running != nil { pending = (title, prompt, auto); return }
        suggestions.insert(Suggestion(title: title, auto: auto), at: 0)
        if suggestions.count > 20 { suggestions.removeLast() }
        let sid = suggestions[0].id
        log("asking Claude (\(auto ? "auto" : "manual")): \(title.prefix(80))")
        running = Task { @MainActor in
            do {
                for try await chunk in ClaudeRunner.stream(prompt) {
                    if let i = self.suggestions.firstIndex(where: { $0.id == sid }) { self.suggestions[i].text += chunk }
                }
            } catch {
                if let i = self.suggestions.firstIndex(where: { $0.id == sid }) { self.suggestions[i].failed = error.localizedDescription }
                self.log("Claude error: \(error.localizedDescription)")
            }
            if let i = self.suggestions.firstIndex(where: { $0.id == sid }) { self.suggestions[i].done = true }
            self.running = nil
            if let p = self.pending { self.pending = nil; self.run(title: p.title, prompt: p.prompt, auto: p.auto) }
        }
    }

    var busy: Bool { running != nil }
    private func run(title: String, auto: Bool, prompt: String) { run(title: title, prompt: prompt, auto: auto) }

    // MARK: Transcript

    func transcript(lastMinutes: Double? = nil) -> String {
        let since = lastMinutes.map { Date().addingTimeInterval(-$0 * 60) } ?? .distantPast
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return lines.filter { $0.time >= since && !$0.text.isEmpty }
            .map { "[\(f.string(from: $0.time))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    private func save() {
        let text = transcript()
        guard !text.isEmpty else { return }
        let dir = Paths.home.appendingPathComponent("transcripts")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        let url = dir.appendingPathComponent("Meeting \(f.string(from: startedAt ?? Date())).md")
        let header = "# Meeting \(f.string(from: startedAt ?? Date()))\n\nThem = other people, Me = you.\n\n"
        try? (header + text + "\n").write(to: url, atomically: true, encoding: .utf8)
        savedTo = url
    }

    // MARK: Ask Claude

    /// "Samjhao": explain the recent conversation, or answer the typed question about it.
    func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let recent = transcript(lastMinutes: 6)
        guard !recent.isEmpty else { status = "Nothing transcribed yet"; return }
        let task = q.isEmpty
            ? "Explain in simple words what was just discussed, especially the last few lines. Define any jargon or terms. Then suggest one or two things I could say or ask next."
            : "My question: \(q)"
        let prompt = """
        I'm in a live meeting right now. Recent transcript (speech-to-text, may have errors; "Them" = other people, "Me" = me):

        \(recent)

        \(task)
        Keep it short enough to read in a few seconds. Answer in the same language/style as my question (Hinglish is fine).
        """
        run(title: q.isEmpty ? "Samjhao: what was just said?" : q, prompt: prompt, auto: false)
        question = ""
    }

    func summarize() {
        let all = transcript()
        guard !all.isEmpty else { return }
        run(title: "Meeting summary", auto: false, prompt: """
        Here is a meeting transcript (speech-to-text; "Them" = other people, "Me" = me):

        \(all)

        Summarise it: key points, decisions, action items (who/what), and open questions. Keep it brief.
        """)
    }

    func clear() { lines = []; savedTo = nil }
}

extension MeetingService: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        Self.themTap?.append(sb)
        Self.themBuffers += 1
        // Loudness for the meter (ScreenCaptureKit gives Float32 PCM).
        var abl = AudioBufferList()
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: &abl, bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr,
              let data = abl.mBuffers.mData else { return }
        let n = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        Self.themPeak = max(Self.themPeak, Self.peak(data.assumingMemoryBound(to: Float.self), n))
    }
}
