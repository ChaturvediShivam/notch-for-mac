import AppKit
import AVFoundation
import ScreenCaptureKit
import Speech

/// Dictate (microphone → text pasted where you type) and Listen (live captions of the Mac's
/// own audio via ScreenCaptureKit). Recognition is Apple's Speech framework, on-device when available.
@MainActor
final class VoiceService: NSObject, ObservableObject {
    static let shared = VoiceService()

    enum Mode { case idle, dictating, listening }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var text = ""          // live transcript of the current session
    @Published private(set) var finished = ""      // listen: committed text so far
    @Published var status = ""

    private var speech: (any SpeechStream)?
    private var finals: [String] = []
    private let engine = AVAudioEngine()
    private var stream: SCStream?
    private var silenceTimer: Timer?
    private var listenStarted = Date()
    /// Audio thread → main: when we last heard speech, and whether any was heard at all.
    nonisolated(unsafe) private static var lastVoice = Date()
    nonisolated(unsafe) private static var heard = false
    nonisolated(unsafe) private static var live: (any SpeechStream)?

    // MARK: Permissions (asked only when you first use the feature)

    private func authorize() async -> Bool {
        let s: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard s == .authorized else { status = "Allow Speech Recognition for Notch in System Settings → Privacy"; return false }
        return true
    }

    // MARK: Dictation

    func toggleDictation() {
        if mode == .dictating { stopDictation(); return }
        if mode == .listening { stopListen() }
        Task { await startDictation() }
    }

    private func startDictation() async {
        guard await authorize() else { NotchModel.shared.show(.tools); return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            status = "Allow Microphone for Notch in System Settings → Privacy"; NotchModel.shared.show(.tools); return
        }
        guard await beginRecognition() else { return }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        Self.heard = false; Self.lastVoice = Date()
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in
            // ponytail: energy gate instead of Silero VAD; fine for a headset or quiet room.
            if let ch = buf.floatChannelData?[0], buf.frameLength > 0 {
                var sum: Float = 0
                for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
                if (sum / Float(buf.frameLength)).squareRoot() > 0.015 { Self.heard = true; Self.lastVoice = Date() }
            }
            Self.live?.append(buf)
        }
        do { try engine.start(); mode = .dictating; NSSound(named: "Morse")?.play() }
        catch { status = "Microphone error: \(error.localizedDescription)"; endRecognition(); return }
        // Stop by itself: 1.5 s quiet after you spoke, or 8 s with nothing said.
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                let quiet = Date().timeIntervalSince(Self.lastVoice)
                if quiet > (Self.heard ? 1.5 : 8) { VoiceService.shared.stopDictation() }
            }
        }
    }

    func stopDictation() {
        guard mode == .dictating else { return }
        silenceTimer?.invalidate()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        speech?.stop()
        mode = .idle
        // Give the recogniser a moment to deliver the final result, then paste it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.endRecognition()
            let t = (self.finished + " " + self.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            Self.paste(t)
        }
    }

    /// Copies, then presses ⌘V for you if Notch has Accessibility (opt-in in Settings).
    static func paste(_ t: String) {
        let pb = NSPasteboard.general
        pb.clearContents(); pb.setString(t, forType: .string)
        guard AXIsProcessTrusted() else {
            AlertsService.shared.add(title: "Dictation copied", body: t, source: "Voice"); return
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)   // V
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    }

    // MARK: Listen (system audio captions)

    func toggleListen() {
        if mode == .listening { stopListen(); return }
        if mode == .dictating { stopDictation() }
        Task { await startListen() }
    }

    private func startListen() async {
        guard await authorize() else { NotchModel.shared.show(.tools); return }
        do {
            // First use triggers macOS's Screen Recording prompt (needed for system audio).
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { status = "No display"; return }
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 16000
            cfg.channelCount = 1
            cfg.width = 2; cfg.height = 2                       // we only want audio
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            guard await beginRecognition() else { return }
            try await s.startCapture()
            stream = s
            mode = .listening
            listenStarted = Date()
        } catch {
            status = "Listen needs Screen Recording permission for Notch (System Settings → Privacy & Security). \(error.localizedDescription)"
            NotchModel.shared.show(.tools)
            endRecognition()
        }
    }

    func stopListen() {
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
        speech?.stop()
        mode = .idle
        saveTranscript()
        endRecognition()
    }

    private func saveTranscript() {
        let all = (finished + " " + text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !all.isEmpty else { return }
        let fm = FileManager.default
        let dir = Paths.home.appendingPathComponent("listen")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        try? all.write(to: dir.appendingPathComponent("\(f.string(from: Date())).txt"), atomically: true, encoding: .utf8)
        // Keep the newest 20 (names sort by date).
        let old = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".txt") }.sorted().dropLast(20)
        for n in old { try? fm.removeItem(at: dir.appendingPathComponent(n)) }
    }

    // MARK: Recognition

    /// Same engine and language as Meeting mode. Volatile text shows live; finals are kept.
    private func beginRecognition() async -> Bool {
        text = ""; finished = ""; status = ""; finals = []
        let sp = Speech2.make(locale: Store.shared.config.meetingLocale)
        sp.onText = { [weak self] _, t, final in
            guard let self else { return }
            if final { self.finals.append(t); self.text = "" } else { self.text = t }
            // Listen keeps a rolling 3 h window (~30k words); older text drops off.
            if self.finals.count > 3000 { self.finals.removeFirst(self.finals.count - 3000) }
            self.finished = self.finals.joined(separator: " ")
            if self.mode == .listening, Date().timeIntervalSince(self.listenStarted) > 3 * 3600 { self.stopListen() }
        }
        sp.onError = { [weak self] e in self?.status = e }
        if let e = await sp.begin() { status = "Speech error: \(e)"; NotchModel.shared.show(.tools); return false }
        speech = sp; Self.live = sp
        return true
    }

    private func endRecognition() {
        silenceTimer?.invalidate()
        Self.live = nil; speech = nil
    }

    /// Last few words, for the pill.
    var tail: String {
        let words = (text.isEmpty ? finished : text).split(separator: " ")
        return words.suffix(6).joined(separator: " ")
    }
}

extension VoiceService: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        Self.live?.append(sb)
    }
}
