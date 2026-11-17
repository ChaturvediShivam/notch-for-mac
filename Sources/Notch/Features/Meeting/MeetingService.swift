import AppKit
import AVFoundation
import ScreenCaptureKit
import PDFKit
import Speech
import UniformTypeIdentifiers

/// A saved meeting file. Unkept ones are deleted 24 h after they were saved.
struct MeetSession: Identifiable, Equatable {
    let url: URL
    let date: Date
    let kept: Bool
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

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
    private var runningSid: UUID?
    private var pending: (title: String, prompt: String, auto: Bool)?
    /// Line id → how many words it had when answered (a line that grows a lot gets answered again).
    private var answered: [UUID: Int] = [:]

    nonisolated(unsafe) private static var themPeak: Float = 0, mePeak: Float = 0
    nonisolated(unsafe) private static var themBuffers = 0, meBuffers = 0
    private var meterTimer: Timer?
    private var lastLog = Date.distantPast

    private var them: (any SpeechStream)? { didSet { Self.themTap = them } }
    /// Same transcriber, reachable from ScreenCaptureKit's audio queue.
    nonisolated(unsafe) private static var themTap: (any SpeechStream)?
    private var me: (any SpeechStream)?
    private var questionWork: [String: DispatchWorkItem] = [:]
    private var stream: SCStream?
    private let engine = AVAudioEngine()
    private var saveWork: DispatchWorkItem?

    // MARK: Carry on after a dropped call

    /// The meeting that just stopped, in memory only, so a call that drops and rejoins can carry on.
    private var last: (lines: [MeetLine], suggestions: [Suggestion], startedAt: Date, ended: Date)?
    static let resumeWindow: TimeInterval = 30 * 60
    /// Set while this meeting carries on from an earlier one (its start time), for the "New meeting" choice.
    @Published private(set) var resumed: Date?
    /// Start time of the meeting that can still be rejoined (stopped < 30 min ago), for "Rejoin / New".
    @Published private(set) var resumable: Date?

    /// Started again within 30 min of the last stop: pick up its transcript and answers. Else start empty.
    private func beginTranscript(fresh: Bool) {
        if !fresh, let l = last, Date().timeIntervalSince(l.ended) < Self.resumeWindow {
            lines = l.lines; suggestions = l.suggestions; resumed = l.startedAt
            log("continuing the meeting from \(l.startedAt)")
        } else {
            lines = []; suggestions = []; resumed = nil
        }
        last = nil; resumable = nil; savedTo = nil; answered = [:]
        turn = nil; turns = []; cardEvents = []; lastThemAt = nil
    }

    /// "New meeting": drop what was carried over (it's already saved) and start this one empty.
    func startFresh() {
        guard resumed != nil else { return }
        lines = []; suggestions = []; answered = [:]; resumed = nil
        if active { startedAt = Date() }
        log("started fresh instead of continuing")
    }

    // MARK: Saved sessions (24 h unless kept)

    @Published private(set) var sessions: [MeetSession] = []
    static let lifetime: TimeInterval = 24 * 3600
    private static var dir: URL { Paths.home.appendingPathComponent("transcripts") }
    private static var keptDir: URL { dir.appendingPathComponent("Kept") }

    /// Deletes unkept meetings older than 24 h, then lists what's left (newest first).
    func refreshSessions() {
        let fm = FileManager.default
        func list(_ d: URL, kept: Bool) -> [MeetSession] {
            ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("Meeting ") && $0.pathExtension == "md" }
                .map { MeetSession(url: $0, date: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date(), kept: kept) }
        }
        var temp = list(Self.dir, kept: false)
        for s in temp where Date().timeIntervalSince(s.date) > Self.lifetime {
            try? fm.removeItem(at: s.url); log("auto-deleted \(s.name)")
        }
        temp.removeAll { !fm.fileExists(atPath: $0.url.path) }
        var kept = list(Self.keptDir, kept: true)
        let keptDays = Store.shared.config.keptDays
        if keptDays > 0 {
            for s in kept where Date().timeIntervalSince(s.date) > Double(keptDays) * Retention.day {
                try? fm.removeItem(at: s.url); log("auto-deleted kept \(s.name)")
            }
            kept.removeAll { !fm.fileExists(atPath: $0.url.path) }
        }
        sessions = (temp + kept).sorted { $0.date > $1.date }
    }

    /// Keep moves the file into Kept/ (never auto-deleted); un-keep moves it back and restarts its 24 h.
    func setKept(_ s: MeetSession, _ keep: Bool) {
        let fm = FileManager.default
        let to = (keep ? Self.keptDir : Self.dir).appendingPathComponent(s.url.lastPathComponent)
        try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: s.url, to: to)
        log("\(keep ? "kept" : "un-kept") \(s.name)")
        if !keep { try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: to.path) }
        if savedTo == s.url { savedTo = to }
        refreshSessions()
    }

    func delete(_ s: MeetSession) {
        try? FileManager.default.removeItem(at: s.url)
        log("deleted by you: \(s.name)\(s.kept ? " (kept)" : "")")
        if savedTo == s.url { savedTo = nil }
        refreshSessions()
    }

    static let languages: [(id: String, name: String)] = [
        ("en-IN", "Hindi + English (Hinglish)"), ("hi-IN", "Hindi only (देवनागरी)"),
        ("en-US", "English (US)"), ("en-GB", "English (UK)"),
    ]

    /// Rejoin / New buttons: a manual start, so call-watching treats it like pressing Start.
    func startManually(fresh: Bool) {
        CallWatch.shared.userToggled(nowActive: true)
        Task { await start(fresh: fresh) }
    }

    func toggle() {
        CallWatch.shared.userToggled(nowActive: !active)
        if active { stop() } else { Task { await start() } }
    }

    /// Step-by-step log for troubleshooting: ~/.notch/meeting.log
    private static let logQueue = DispatchQueue(label: "notch.meeting.log", qos: .utility)

    /// What people said never outlives the 24 h transcript in the store edition: the log keeps only a word count.
    /// The master build keeps the text for debugging.
    nonisolated static func redact(_ t: String, _ n: Int) -> String {
        Skin.isMaster ? String(t.prefix(n)) : "[\(t.split(separator: " ").count) words]"
    }

    /// Drops log lines older than the cutoff, to the second (lines start "yyyy-MM-dd HH:mm:ss").
    static func trimLog(before cutoff: Date) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let keepFrom = f.string(from: cutoff)
        let url = Paths.home.appendingPathComponent("meeting.log")
        logQueue.async {
            guard let s = try? String(contentsOf: url, encoding: .utf8) else { return }
            let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            let kept = lines.filter { $0.count < 19 || !($0.prefix(4).allSatisfy(\.isNumber)) || String($0.prefix(19)) >= keepFrom }
            if kept.count != lines.count { try? kept.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    /// Delete all my data: every transcript (kept too), what's on screen, and the log.
    func wipeAll() {
        if active { stop() }
        saveWork?.cancel(); saveWork = nil
        lines = []; suggestions = []; answered = [:]; savedTo = nil; last = nil; resumed = nil; resumable = nil
        try? FileManager.default.removeItem(at: Self.dir)
        let url = Paths.home.appendingPathComponent("meeting.log")
        Self.logQueue.async { try? FileManager.default.removeItem(at: url) }
        refreshSessions()
    }

    func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let line = "\(f.string(from: Date()))  \(s)\n"
        let url = Paths.home.appendingPathComponent("meeting.log")
        Self.logQueue.async {   // serial: parallel appends were losing lines
            if let h = try? FileHandle(forWritingTo: url) {
                // Over 1 MB: keep the newest 256 KB, so the log never eats disk.
                if h.seekToEndOfFile() > 1_000_000, let d = try? Data(contentsOf: url) {
                    try? h.close(); try? (d.suffix(256_000) + Data(line.utf8)).write(to: url, options: .atomic); return
                }
                h.write(Data(line.utf8)); try? h.close()
            }
            else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// `fresh`: start empty even if the last meeting could be rejoined. Calls and the hotkey rejoin by default.
    func start(fresh: Bool = false) async {
        guard !active else { return }
        saveWork?.perform(); saveWork?.cancel(); saveWork = nil   // stopped < 2 s ago: save that one first
        beginTranscript(fresh: fresh)
        log("— Start pressed. mode=\(Store.shared.config.meetingRole) language=\(Store.shared.config.meetingLocale) output=\(AudioService.shared.outputs.first { $0.id == AudioService.shared.defaultOutput }?.name ?? "?") input=\(AudioService.shared.inputs.first { $0.id == AudioService.shared.defaultInput }?.name ?? "?")")
        if VoiceService.shared.mode == .dictating { VoiceService.shared.stopDictation() }
        if VoiceService.shared.mode == .listening { VoiceService.shared.stopListen() }
        // Open the notch once setup is done, so the open animation doesn't run during audio setup.
        defer { NotchModel.shared.show(.meeting) }

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
            // Turning it on takes ~0.7 s; off the main thread so hover and clicks don't freeze meanwhile.
            // The engine isn't running yet and nothing else touches it until this returns.
            nonisolated(unsafe) let node = input
            let t0 = Date()
            let vpError: String? = await Task.detached {
                do {
                    try node.setVoiceProcessingEnabled(true)
                    if #available(macOS 14.0, *) {
                        node.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
                    }
                    return nil
                } catch { return error.localizedDescription }
            }.value
            if let vpError { log("voice processing unavailable: \(vpError)") }
            else { log(String(format: "voice processing (echo cancellation) on, %.2f s off the main thread", Date().timeIntervalSince(t0))) }
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
        startedAt = resumed ?? Date()
        if coaching { GazeTracker.shared.start(); log("delivery coach on (camera, nothing recorded)") }
        Self.themBuffers = 0; Self.meBuffers = 0
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingService.shared.tickMeters() }
        }
    }

    func stop() {
        guard active else { return }
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        running?.cancel(); running = nil; runningSid = nil; pending = nil
        questionWork.values.forEach { $0.cancel() }; questionWork = [:]
        flushWork?.cancel(); flushWork = nil; volatile = [:]
        probeWork?.cancel(); probeWork = nil; probedUpTo = nil
        them?.stop(); me?.stop()
        meterTimer?.invalidate(); meterTimer = nil
        themLevel = 0; meLevel = 0
        if GazeTracker.shared.running { finishTurn(); deliverySummary(); GazeTracker.shared.stop() }
        log("stopped. lines=\(lines.count) themBuffers=\(Self.themBuffers) meBuffers=\(Self.meBuffers)")
        active = false
        // Let the last segments finish, then save.
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    private func tickMeters() {
        // Rounded to 0.1 so an unchanged level doesn't redraw the notch.
        let t = (Double(min(1, Self.themPeak * 4)) * 10).rounded() / 10, m = (Double(min(1, Self.mePeak * 4)) * 10).rounded() / 10
        if t != themLevel { themLevel = t }
        if m != meLevel { meLevel = m }
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

    /// Live (volatile) text arrives many times a second; redrawing the open notch for each one
    /// was the main CPU/heat cost. Batch it to ~3 updates a second; final text goes straight in.
    private var volatile: [UUID: (who: String, text: String)] = [:]
    private var flushWork: DispatchWorkItem?

    private func upsert(_ id: UUID, _ who: String, _ text: String, _ final: Bool) {
        if !final {
            volatile[id] = (who, text)
            if flushWork == nil {
                let w = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.flushWork = nil
                    let batch = self.volatile; self.volatile = [:]
                    for (id, v) in batch { self.apply(id, v.who, v.text, false) }
                }
                flushWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
            }
            return
        }
        volatile[id] = nil
        log("heard (\(who), final): \(Self.redact(text, 60))")
        apply(id, who, text, true)
    }

    func apply(_ id: UUID, _ who: String, _ text: String, _ final: Bool) {   // internal: Bench feeds it fake speech
        // On speakers the mic picks up the other side too: drop "Me" text that repeats "Them".
        if who == "Me", isEcho(text) {
            lines.removeAll { $0.id == id }
            return
        }
        // Recogniser sometimes emits only punctuation (", , , ,"): not a line.
        guard text.contains(where: \.isLetter) else { lines.removeAll { $0.id == id }; return }
        if let i = lines.lastIndex(where: { $0.id == id }) {
            lines[i].text = text; lines[i].final = final
        } else {
            lines.append(MeetLine(id: id, speaker: who, text: text, time: Date(), final: final))
        }
        questionWork[who]?.cancel()   // that speaker kept talking: re-judge from this text
        noteDelivery(who)
        guard autoAnswer, active else { return }
        // Interviewing: their talk is an answer to judge. Practice: my talk is an answer to coach.
        // Neither gets a "what to say" card.
        if interviewing, who == "Them" { scheduleProbe("Them"); return }
        if practicing { if who == "Me" { scheduleProbe("Me") }; return }
        // Answering (I'm the one being asked): my own questions get no card. "Any questions for us?" →
        // the card suggests what to ask; reading out "what a strong answer is" while I ask it only distracts.
        if who == "Me", !interviewing { return }
        // Interviewing: my lines count as questions only when the recogniser heard a "?": answers are full of
        // "where", "how", "tell me" ("…what our customers tell me").
        let strict = who == "Me"
        guard needsAnswer(id, text), Self.isQuestion(text, strict: strict) else { return }
        if final {
            answered[id] = Self.words(text).count
            autoSuggest(for: text, mine: who == "Me")
        } else if Self.words(text).count >= 5 {
            // Don't wait for the sentence to be finalised: once the question text holds still
            // for a moment, answer it. Shorter fragments ("so can you please") wait for more.
            let w = DispatchWorkItem { [weak self] in
                guard let self, let line = self.lines.last(where: { $0.id == id }),
                      self.needsAnswer(id, line.text), Self.isQuestion(line.text, strict: strict) else { return }
                self.answered[id] = Self.words(line.text).count
                self.autoSuggest(for: line.text, mine: who == "Me")
            }
            questionWork[who] = w
            // "?" means the recogniser thinks the question is done; otherwise give the speaker longer.
            DispatchQueue.main.asyncAfter(deadline: .now() + (text.contains("?") ? 0.7 : 1.5), execute: w)
        }
    }

    /// Not answered yet, or the question grew by 3+ words since (it was cut off when we answered).
    private func needsAnswer(_ id: UUID, _ text: String) -> Bool {
        guard let n = answered[id] else { return true }
        return Self.words(text).count >= n + 3
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
    /// `strict`: only a heard "?" counts (used for my own lines).
    nonisolated static func isQuestion(_ raw: String, strict: Bool = false) -> Bool {
        let t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix("?") && words(t).count >= 2 { return true }   // "A funnel account?"
        guard words(t).count >= 3 else { return false }
        if t.contains("?") { return true }
        if strict { return false }
        let w = words(t)
        let starts = ["what", "why", "how", "when", "where", "who", "which", "whose", "can", "could", "would", "will",
                      "do", "does", "did", "is", "are", "was", "were", "should", "shall", "have", "has", "may"]
        // First word as spoken (one-letter words like "I" count here, unlike in words()).
        let first = t.components(separatedBy: CharacterSet.alphanumerics.inverted).first { !$0.isEmpty }
        // "When everything is ready, we will launch." The recogniser ends questions with "?", so a
        // finished sentence ending in "." isn't one, whatever its first word.
        if let f = first, starts.contains(f), !t.hasSuffix(".") { return true }
        let anywhere: Set<String> = ["kya", "kyun", "kyon", "kaise", "kab", "kaun", "kaunsa", "kitna", "kitne", "kitni",
                                     "kahan", "kidhar"]
        let hindi: [String] = ["क्या", "क्यों", "कैसे", "कब", "कौन", "कितना", "कितने", "कितनी", "कहाँ", "कहां"]
        if w.contains(where: anywhere.contains) || hindi.contains(where: t.contains) { return true }
        // Asks phrased as requests ("So please introduce yourself."). Only near the start of the line:
        // "…and what our customers tell me" is a statement, "Tell me about…" is a question.
        let opening = (t.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            .drop { ["so", "okay", "ok", "um", "uh", "and", "now", "then", "alright", "right", "please", "like", "well"].contains($0) })
            .prefix(8).joined(separator: " ")
        for phrase in ["can you", "could you", "do you", "tell me", "explain", "introduce yourself", "walk me through",
                       "describe", "give me an example", "share an example", "talk about", "talk me through", "elaborate",
                       "i would like to know", "i'd like to know", "i want to know", "help me understand", "what about",
                       "any idea", "your view", "thoughts on", "bata sakte", "batao", "bataiye", "sakte ho", "sakte hain",
                       "sakti ho", "samjhao"] where opening.contains(phrase) {
            return true
        }
        return t.contains("introduce yourself") || t.contains("about yourself")
    }

    /// Fill the context box from a text, Markdown or PDF file (e.g. a resume).
    func loadContextFile(into key: WritableKeyPath<Config, String> = \.meetingCV) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.plainText, .pdf, UTType(filenameExtension: "md") ?? .plainText]
        p.level = .popUpMenu
        NSApp.activate(ignoringOtherApps: true)
        defer { NotchModel.shared.show(.meeting) }
        guard p.runModal() == .OK, let url = p.url else { return }
        let text = url.pathExtension.lowercased() == "pdf" ? PDFDocument(url: url)?.string
                                                           : try? String(contentsOf: url, encoding: .utf8)
        guard let text, !text.isEmpty else { status = "Couldn't read text from \(url.lastPathComponent)"; return }
        let cur = Store.shared.config[keyPath: key].trimmingCharacters(in: .whitespacesAndNewlines)
        Store.shared.config[keyPath: key] = (cur.isEmpty ? "" : cur + "\n\n") + text
    }

    // MARK: Live suggestions

    static let minePrefix = "You asked: "

    var interviewing: Bool { Store.shared.config.meetingRole == "interview" }
    /// Practice: a friend interviews me on a call; no answers to read out, feedback after each of mine.
    var practicing: Bool { Store.shared.config.meetingRole == "practice" }

    /// The three context boxes, labelled for the current role.
    static func contextFields(interviewing: Bool) -> [(key: WritableKeyPath<Config, String>, label: String, hint: String)] {
        [(\.meetingCV, interviewing ? "Candidate's CV" : "My CV",
          interviewing ? "Paste the candidate's resume, or load a PDF" : "Paste your resume, or load a PDF"),
         (\.meetingJD, "Job / agenda", "Paste the job description, or the meeting agenda"),
         (\.meetingTopic, interviewing ? "What to check" : "My words",
          interviewing ? "Skills to test, doubts about the candidate, must-ask questions…"
                       : "Your work in plain words, any language. Answers turn it into professional language.")]
    }

    /// Shared by every prompt: the context boxes, and how to treat speech-to-text mistakes.
    private var context: String {
        let c = Store.shared.config
        // ponytail: hard cap keeps prompts fast; summarise first if people paste whole books.
        func box(_ v: String, _ n: Int) -> String { String(v.trimmingCharacters(in: .whitespacesAndNewlines).prefix(n)) }
        let cv = box(c.meetingCV, 12_000), jd = box(c.meetingJD, 6_000), notes = box(c.meetingTopic, 6_000)
        var parts: [String] = []
        if !cv.isEmpty { parts.append((interviewing ? "The candidate's resume" : "My resume") + ":\n<<<\n\(cv)\n>>>") }
        if !jd.isEmpty { parts.append("The job description / agenda:\n<<<\n\(jd)\n>>>") }
        if !notes.isEmpty {
            parts.append(interviewing
                ? "What I want to check in this interview:\n<<<\n\(notes)\n>>>"
                : "My work and notes in my own rough words (any language). When you use them, say them in clear, " +
                  "professional language, but never add facts that aren't there:\n<<<\n\(notes)\n>>>")
        }
        return (parts.isEmpty ? "" : parts.joined(separator: "\n\n") + """

        Use this for facts about \(interviewing ? "the candidate, the role" : "me, my work") and the subject. \
        Never invent experience, numbers or names that aren't in it or in the transcript.

        """) + """
        The text is live speech-to-text and often mishears words. Read every line in the meaning that fits \
        the topic and the conversation (e.g. in a money-laundering talk "structured cat deposit" is "structured \
        cash deposit", "SR" is "SAR"). If a question is still too garbled to know what was asked, don't guess: \
        reply with only one line: "Unclear — ask them to repeat."
        """
    }

    // MARK: Delivery coach: how I said it (pauses, pace, fillers, eyes)

    /// On in Answering and Practice when the switch is on; Interviewing judges the other person instead.
    var coaching: Bool { Store.shared.config.deliveryCoach && !interviewing }
    private var turn: (start: Date, progress: [(Date, Int)], after: Date?)?
    private var lastThemAt: Date?
    private var cardEvents: [Date] = []
    private var deliveryWork: DispatchWorkItem?
    private var turns: [(words: Int, secs: Double, pauses: Int, waited: Int, fillers: Int)] = []
    nonisolated static let fillerWords: Set<String> = ["uh", "um", "umm", "uhh", "hmm", "er", "ah"]

    /// Called on every recognised update: stamps when my word count grows, so silences show up as gaps.
    private func noteDelivery(_ who: String) {
        guard coaching, active else { return }
        if who == "Them" { lastThemAt = Date(); if turn != nil { finishTurn() }; return }
        let n = myTurnText().split(separator: " ").count
        if turn == nil { turn = (Date(), [], lastThemAt) }
        if n > (turn?.progress.last?.1 ?? 0) { turn?.progress.append((Date(), n)) }
        deliveryWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.finishTurn() }
        deliveryWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: w)
    }

    private func myTurnText() -> String {
        let lastThem = lines.lastIndex { $0.speaker == "Them" }
        return lines[(lastThem.map { $0 + 1 } ?? 0)...].filter { $0.speaker == "Me" }.map(\.text).joined(separator: " ")
    }

    /// My answer ended (they spoke, or I was quiet 3.5 s): add a Delivery card. Local maths, no AI.
    private func finishTurn() {
        deliveryWork?.cancel(); deliveryWork = nil
        guard let t = turn else { return }
        turn = nil
        let text = myTurnText()
        let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        guard words.count >= 12, let first = t.progress.first?.0, let last = t.progress.last?.0 else { return }
        let r = Self.deliveryReport(progress: t.progress.map(\.0), questionEnded: t.after, cardEvents: cardEvents, words: words,
                                    gaze: GazeTracker.summarize(GazeTracker.shared.frames(from: first, to: last),
                                                                baseline: GazeTracker.shared.allFrames()))
        turns.append((words.count, last.timeIntervalSince(first), r.pauses, r.waited, r.fillers))
        suggestions.insert(Suggestion(title: "Delivery: " + String(text.prefix(60)), text: r.text, auto: false, done: true), at: 0)
        log("delivery: \(r.text.replacingOccurrences(of: "\n", with: " | "))")
    }

    /// Pure: turns timings into the card text (kept apart so SelfTest can check it).
    nonisolated static func deliveryReport(progress: [Date], questionEnded: Date?, cardEvents: [Date], words: [String],
                                           gaze: GazeTracker.Gaze?) -> (text: String, pauses: Int, waited: Int, fillers: Int) {
        let secs = max(progress.last!.timeIntervalSince(progress.first!), 1)
        let wpm = Int(Double(words.count) / secs * 60)
        // A silence of 2 s+ mid-answer. "Waited for the card": the silence ended within 1.5 s of a card's words arriving.
        var pauses: [Double] = [], waited = 0
        for (a, b) in zip(progress, progress.dropFirst()) where b.timeIntervalSince(a) >= 2 {
            pauses.append(b.timeIntervalSince(a))
            if cardEvents.contains(where: { $0 > a && b.timeIntervalSince($0) >= 0 && b.timeIntervalSince($0) < 1.5 }) { waited += 1 }
        }
        let start = questionEnded.map { progress.first!.timeIntervalSince($0) }
        let fillers = words.filter { fillerWords.contains($0) }.count
        var lines: [String] = []
        var head = "\(wpm) words/min"
        if let start, start >= 0 { head = String(format: "Started %.1f s after the question · ", start) + head }
        lines.append(head)
        lines.append(pauses.isEmpty ? "No long pauses" :
            String(format: "%d pause%@ over 2 s (longest %.1f s)", pauses.count, pauses.count == 1 ? "" : "s", pauses.max()!)
            + (waited > 0 ? " · \(waited) while a card was loading: you waited for it" : ""))
        lines.append("Fillers (uh, um): \(fillers)")
        if let g = gaze {
            lines.append(String(format: "Eyes: up at the notch %.0f%% · level %.0f%% · down %.0f%% · away %.0f%% · reading sweeps %d",
                                g.up * 100, g.level * 100, g.down * 100, g.away * 100, g.sweeps))
        }
        // One tip, the most useful first.
        let perMin = Double(gaze?.sweeps ?? 0) / max(gaze?.seconds ?? secs, 1) * 60
        let tip: String
        if waited > 0 { tip = "Don't wait for the card: start with your own first line (\"Sure, so at my current role I…\"), then glance for the next point." }
        else if perMin >= 8 { tip = "Your eyes moved like reading lines. Glance at one keyword, look back at the camera, and say it your own way." }
        else if (start ?? 0) > 3 { tip = "You took a while to start. Open with a short bridge (\"Good question, so…\") while you think." }
        else if Double(fillers) / secs * 60 > 6 { tip = "Lots of uh/um: a short silent pause sounds more confident than a filler." }
        else if wpm > 170 { tip = "A bit fast: slow down on the key numbers so they land." }
        else if wpm < 100 { tip = "A bit slow: shorter sentences will keep the energy up." }
        else { tip = "Natural pace. Keep looking at the camera when you make your main point." }
        lines.append("Tip: " + tip)
        return (lines.joined(separator: "\n"), pauses.count, waited, fillers)
    }

    /// At stop: the whole session in one card (it's saved with the transcript).
    private func deliverySummary() {
        guard !turns.isEmpty else { return }
        let w = turns.map(\.words).reduce(0, +), s = turns.map(\.secs).reduce(0, +)
        var text = "\(turns.count) answers · \(Int(Double(w) / max(s, 1) * 60)) words/min on average\n"
        text += "Pauses over 2 s: \(turns.map(\.pauses).reduce(0, +)) · waited for a card: \(turns.map(\.waited).reduce(0, +)) · fillers: \(turns.map(\.fillers).reduce(0, +))"
        if let g = GazeTracker.summarize(GazeTracker.shared.allFrames(), baseline: GazeTracker.shared.allFrames()) {
            text += String(format: "\nEyes over the session: up at the notch %.0f%% · away %.0f%% · reading sweeps %d", g.up * 100, g.away * 100, g.sweeps)
        }
        suggestions.insert(Suggestion(title: "Delivery summary", text: text, auto: false, done: true), at: 0)
        turns = []
    }

    // MARK: Interviewing: next questions after the candidate answers

    private var probeWork: DispatchWorkItem?
    private var probedUpTo: UUID?

    /// Someone finished an answer (3 s quiet): interviewing → judge the candidate and suggest what to ask;
    /// practice → coach my answer.
    private func scheduleProbe(_ who: String) {
        probeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.probe(who) }
        probeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    private func probe(_ who: String) {
        // Their answer = their lines since the other side last spoke; the question = the other side's turn before it.
        let other = who == "Me" ? "Them" : "Me"
        let lastOther = lines.lastIndex { $0.speaker == other }
        let turn = lines[(lastOther.map { $0 + 1 } ?? 0)...].filter { $0.speaker == who }
        guard let last = turn.last, last.id != probedUpTo,
              turn.flatMap({ Self.words($0.text) }).count >= 12 else { return }
        probedUpTo = last.id
        let asked = lastOther.map { turnText(endingAt: $0) } ?? ""
        let title = (asked.isEmpty ? "Your answer" : String(asked.suffix(90)))
        if who == "Me" {
            run(title: "Feedback: " + title, prompt: """
            I'm practising for an interview: a friend is interviewing me on a call. \(context)
            Recent transcript ("Them" = interviewer, "Me" = me):
            \(transcript(lastMinutes: 8))

            The question was: "\(asked)"
            I just finished answering. Coach me, short:
            Score: x/10 and the main reason in a few words.
            Good: one line.
            Fix: one or two lines (vague? no numbers or example? didn't answer what was asked? too long? \
            filler words? missed something from my resume or the job description?).
            Better: how I could say it, 2–3 sentences in first person, using only facts from my resume, notes \
            or what I said.
            No markdown headers. Same language and style as the interview (Hinglish if they used Hinglish).
            """, auto: true)
        } else {
            run(title: asked.isEmpty ? "Next questions" : "After: \(title)", prompt: """
            I'm interviewing a candidate live. \(context)
            Recent transcript ("Me" = me, the interviewer; "Them" = the candidate):
            \(transcript(lastMinutes: 8))

            The candidate just finished answering. Give me:
            1. One line judging the answer: strong / okay / weak, and why in a few words (vague? no numbers? \
            didn't answer what I asked? doesn't match their resume?).
            2. Two or three sharp follow-up questions I can ask next, the best first: dig into what was vague, \
            check claims from the resume, or cover a skill from the job description not tested yet.
            Short lines, no preamble, no markdown headers. Same language and style I asked in (Hinglish if I used Hinglish).
            """, auto: true)
        }
        if !NotchModel.shared.isOpen { NotchModel.shared.show(.meeting) }
    }

    /// One speaker's whole turn ending at line `i` (their lines back to the other side's last line).
    /// Questions often come in parts: "This role has no direct authority." … "How do you handle that?"
    private func turnText(endingAt i: Int) -> String {
        let who = lines[i].speaker
        var j = i
        while j > 0, lines[j - 1].speaker == who, i - j < 5 { j -= 1 }
        return lines[j...i].map(\.text).joined(separator: " ")
    }

    /// Same question again within a minute (people repeat themselves, "what if" vs "what is").
    private func isRepeat(_ q: String) -> Bool {
        let w = Set(Self.words(q))
        guard !w.isEmpty else { return false }
        return suggestions.contains { s in
            guard s.auto, Date().timeIntervalSince(s.time) < 60 else { return false }
            let o = Set(Self.words(s.title.replacingOccurrences(of: Self.minePrefix, with: "")))
            return Double(w.intersection(o).count) / Double(max(w.count, o.count)) >= 0.7
        }
    }

    private func autoSuggest(for line: String, mine: Bool) {
        // The whole turn: the setup before "How do you handle that?" is part of the question.
        let question = lines.lastIndex { $0.text == line }.map { turnText(endingAt: $0) } ?? line
        let prompt = mine ? """
        I'm in a live meeting and I just asked them: "\(question)"
        \(context)

        Recent transcript ("Them" = other people, "Me" = me):
        \(transcript(lastMinutes: 8))

        Tell me what a strong answer to my question would contain, so I can judge their reply as they talk: \
        at most 3 short plain sentences (under 60 words), the key points first. Then one last line starting "Follow-up:" with a sharp \
        follow-up question I could ask next. No lists, no markdown, no preamble. Use the same language and style \
        I asked in (Hinglish if I used Hinglish).
        """ : """
        I'm in a live meeting. Someone just asked me: "\(question)"
        \(context)

        Recent transcript ("Them" = other people, "Me" = me):
        \(transcript(lastMinutes: 8))

        \(Store.shared.config.keywordCards ? """
        First line: "Points:" then 3 or 4 keywords or very short phrases (2–4 words each, facts and numbers \
        from my background where they fit), separated by " · ", in the order I'd say them. They're for a quick \
        glance so I can talk in my own words, not read. Then a blank line, then the full answer below.

        """ : "")Write exactly what I'd say out loud right now, like a real person talking in a meeting: first person, \
        contractions, everyday words, 1 to 3 short sentences, the direct answer first. No lists, no markdown \
        (apart from the Points line), no "Great question", no preamble. If it needs facts I might not know, keep it safe and add one last line \
        starting "Check:". Use the same language and style they asked in (Hinglish if they used Hinglish).
        """
        // A cut-off version of this question was answered already: replace that card.
        let title = (mine ? Self.minePrefix : "") + line
        let stale = suggestions.filter { $0.auto && title.hasPrefix($0.title) }.map(\.id)
        if stale.isEmpty, isRepeat(line) { log("skipped repeat: \(Self.redact(line, 60))"); return }
        if let r = runningSid, stale.contains(r) { running?.cancel(); running = nil }
        suggestions.removeAll { stale.contains($0.id) }
        run(title: title, prompt: prompt, auto: true)
        if !NotchModel.shared.isOpen { NotchModel.shared.show(.meeting) }
    }

    /// One answer at a time; a newer request waits (only the latest waiting one is kept).
    private func run(title: String, prompt: String, auto: Bool) {
        if running != nil { pending = (title, prompt, auto); return }
        suggestions.insert(Suggestion(title: title, auto: auto), at: 0)
        if suggestions.count > 20 { suggestions.removeLast() }
        let sid = suggestions[0].id
        runningSid = sid
        log("asking AI (\(auto ? "auto" : "manual")): \(Self.redact(title, 80))")
        let asked = Date()
        running = Task { @MainActor in
            var first = true
            do {
                for try await chunk in ClaudeRunner.stream(prompt) {
                    if first { first = false; self.cardEvents.append(Date()); self.log(String(format: "first words after %.2f s", Date().timeIntervalSince(asked))) }
                    if let i = self.suggestions.firstIndex(where: { $0.id == sid }) { self.suggestions[i].text += chunk }
                }
            } catch {
                if let i = self.suggestions.firstIndex(where: { $0.id == sid }) { self.suggestions[i].failed = error.localizedDescription }
                self.log("Claude error: \(error.localizedDescription)")
            }
            if let i = self.suggestions.firstIndex(where: { $0.id == sid }) { self.suggestions[i].done = true }
            self.log(String(format: "answer done after %.2f s", Date().timeIntervalSince(asked)))
            guard self.runningSid == sid else { return }   // replaced by a newer answer meanwhile
            self.running = nil; self.runningSid = nil
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

    /// Writes transcript + answers, then clears the screen so the next meeting starts empty.
    private func save() {
        saveWork = nil
        let text = transcript()
        if !lines.isEmpty {
            let ended = Date()
            last = (lines, suggestions, startedAt ?? ended, ended); resumable = startedAt
            // The Rejoin button goes when the 30 min window does.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.resumeWindow) { [weak self] in
                if self?.last?.ended == ended { self?.resumable = nil }
            }
        }
        defer { lines = []; suggestions = []; answered = [:]; refreshSessions() }
        guard !text.isEmpty else { return }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        let url = Self.dir.appendingPathComponent("Meeting \(f.string(from: startedAt ?? Date())).md")
        var md = "# Meeting \(f.string(from: startedAt ?? Date()))\n\nThem = other people, Me = you.\n\n" + text + "\n"
        let answers = suggestions.reversed().filter { !$0.text.isEmpty }
        if !answers.isEmpty {
            md += "\n## Answers and notes\n" + answers.map { "\n### \($0.title)\n\n\($0.text)\n" }.joined()
        }
        try? md.write(to: url, atomically: true, encoding: .utf8)
        savedTo = url
        log("saved \(url.lastPathComponent)")
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
        I'm in a live meeting right now. \(context)
        Recent transcript ("Them" = other people, "Me" = me):

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

    func clear() { lines = []; suggestions = []; savedTo = nil }
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
