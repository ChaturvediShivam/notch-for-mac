import AppKit
import UniformTypeIdentifiers

struct Attachment: Identifiable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var thumbnail: NSImage? { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true ? NSImage(contentsOf: url) : nil }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String                 // "user" | "assistant"
    var text: String
    var attachments: [String] = []
    var tools: [String] = []         // e.g. "Read notes.md", shown as small chips
    var note: String?
    var blocks: [[String: Any]] = [] // API backend only: exact content replayed next turn (thinking blocks included)
}

/// Two backends, switched in one click (Settings or the Claude tab):
/// - "code": Claude Code (`claude -p … --output-format stream-json`), your Claude Code login and tools;
///   follow-ups resume the same session.
/// - "api": the Messages API with your key from the Keychain (see ClaudeAPI.swift).
@MainActor
final class ClaudeService: ObservableObject {
    static let shared = ClaudeService()

    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var attachments: [Attachment] = []
    @Published private(set) var streaming = false
    @Published var error: String?
    @Published private(set) var claudePath: String?

    @Published private(set) var hasKey = Keychain.get("anthropic") != nil
    var apiTask: Task<Void, Never>?
    private var sessionID: String?
    private var proc: Process?
    private var buffer = Data()
    private var turnText = ""        // text of the current assistant message within the turn

    private init() { locateClaude() }

    /// GUI apps don't get your shell PATH, so look in the usual install spots, then ask a login shell.
    func locateClaude() {
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let p = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { claudePath = p; return }
        Task {
            let (_, out) = await Shell.run("/bin/zsh", ["-lc", "command -v claude"])
            let p = out.trimmingCharacters(in: .whitespacesAndNewlines)
            claudePath = FileManager.default.isExecutableFile(atPath: p) ? p : nil
        }
    }

    var useAPI: Bool { Store.shared.config.claudeBackend == "api" }

    /// One-click switch. The two histories don't mix, so it starts a new chat.
    func setBackend(_ b: String) {
        guard b != Store.shared.config.claudeBackend else { return }
        newChat()
        Store.shared.config.claudeBackend = b
    }

    func saveKey(_ k: String) {
        Keychain.set("anthropic", k.trimmingCharacters(in: .whitespacesAndNewlines))
        hasKey = Keychain.get("anthropic") != nil
    }

    var apiKey: String? { Keychain.get("anthropic") ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] }

    func newChat() { stop(); messages = []; attachments = []; error = nil; sessionID = nil }

    func stop() {
        proc?.terminate(); proc = nil
        apiTask?.cancel(); apiTask = nil
        streaming = false
    }

    func setStreaming(_ v: Bool) { streaming = v }

    // MARK: Attachments (Claude Code reads them from disk itself)

    func addFiles(_ urls: [URL]) {
        for u in urls where !attachments.contains(where: { $0.url == u }) { attachments.append(Attachment(url: u)) }
    }

    func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.level = .popUpMenu
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { addFiles(p.urls) }
        NotchModel.shared.show(.claude, focus: true)
    }

    /// Hotkey ⌃⌥S: select a screen region, attach it, open Claude ready to type.
    func askAboutScreen() {
        NotchModel.shared.setOpen(false)
        Task {
            let dir = Paths.home.appendingPathComponent("screenshots")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970)).png")
            try? await Task.sleep(nanoseconds: 250_000_000)       // let the notch close first
            await Shell.run("/usr/sbin/screencapture", ["-i", "-x", url.path])
            guard FileManager.default.fileExists(atPath: url.path) else { return }     // cancelled with Esc
            attachments.append(Attachment(url: url))
            if draft.isEmpty { draft = "What's on this screenshot?" }
            NotchModel.shared.show(.claude, focus: true)
        }
    }

    // MARK: Sending

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !streaming, !text.isEmpty || !attachments.isEmpty else { return }
        guard Store.shared.config.netClaude else { error = "Claude is turned off in Settings → Privacy"; return }
        if useAPI { sendAPI(text); return }
        guard let claude = claudePath else { error = "Claude Code not found. Install it, then reopen this tab."; return }

        var prompt = text.isEmpty ? "Please look at the attached file(s)." : text
        if !attachments.isEmpty {
            prompt += "\n\nAttached files (read them):\n" + attachments.map { "- \($0.url.path)" }.joined(separator: "\n")
        }
        let cfg = Store.shared.config
        let cwd = cfg.claudeCwd.isEmpty ? NSHomeDirectory() : (cfg.claudeCwd as NSString).expandingTildeInPath
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--append-system-prompt", "You are answering inside a small Dynamic-Island-style panel on the user's Mac. Be concise; short paragraphs, simple Markdown."]
        if let s = sessionID { args += ["--resume", s] }
        if !cfg.claudeModel.isEmpty { args += ["--model", cfg.claudeModel] }
        for dir in Set(attachments.map { $0.url.deletingLastPathComponent().path }) { args += ["--add-dir", dir] }

        messages.append(ChatMessage(role: "user", text: text, attachments: attachments.map(\.name)))
        messages.append(ChatMessage(role: "assistant", text: ""))
        draft = ""; attachments = []; error = nil; turnText = ""; committed = ""; buffer = Data()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\((claude as NSString).deletingLastPathComponent):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["NOTCH_INTERNAL"] = "1"
        p.environment = env
        let out = Pipe(), inp = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardInput = inp; p.standardError = err
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { ClaudeService.shared.received(d) } }
        }
        p.terminationHandler = { proc in
            let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let status = proc.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { ClaudeService.shared.finished(status, errText) } }
        }
        do {
            try p.run()
            proc = p
            streaming = true
            inp.fileHandleForWriting.write(Data(prompt.utf8))
            try? inp.fileHandleForWriting.close()
        } catch {
            self.error = "Couldn't start Claude Code: \(error.localizedDescription)"
            messages.removeLast()
        }
    }

    private func received(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(o) }
        }
    }

    private func handle(_ o: [String: Any]) {
        if let s = o["session_id"] as? String { sessionID = s }
        let j: Any? = o
        switch o["type"] as? String {
        case "stream_event":
            switch j["event"]["type"].str {
            case "message_start":
                // A new model turn after tool use: keep what was said so far.
                if !turnText.isEmpty { committed += turnText + "\n\n"; turnText = "" }
            case "content_block_delta" where j["event"]["delta"]["type"].str == "text_delta":
                turnText += j["event"]["delta"]["text"].str ?? ""
                setText(turnText)
            default: break
            }
        case "assistant":
            // Complete message: note any tool calls so the user sees what Claude Code is doing.
            for b in j["message"]["content"].arr {
                let b: Any? = b
                guard b["type"].str == "tool_use", let name = b["name"].str else { continue }
                let target = (b["input"]["file_path"].str ?? b["input"]["command"].str ?? b["input"]["pattern"].str ?? b["input"]["url"].str)
                    .map { " " + (($0 as NSString).lastPathComponent.prefix(40)) } ?? ""
                if let i = messages.indices.last { messages[i].tools.append(name + target) }
            }
        case "result":
            if o["is_error"] as? Bool == true || (o["subtype"] as? String).map({ $0 != "success" }) == true {
                setNote((o["result"] as? String) ?? "Claude Code stopped: \(o["subtype"] ?? "error")")
            } else if let r = o["result"] as? String, let i = messages.indices.last, messages[i].text.isEmpty {
                messages[i].text = r
            }
        default: break
        }
    }

    /// Text across tool-use turns: earlier turns are kept, the current one streams in.
    private var committed = ""
    private func setText(_ t: String) {
        guard let i = messages.indices.last, messages[i].role == "assistant" else { return }
        messages[i].text = committed + t
    }

    private func finished(_ status: Int32, _ stderr: String) {
        streaming = false
        proc = nil
        committed = ""
        if status != 0, let i = messages.indices.last, messages[i].text.isEmpty {
            let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            error = e.isEmpty ? "Claude Code exited with status \(status). Is it logged in? Run `claude` once in Terminal." : String(e.prefix(400))
            messages.removeLast()
            if let u = messages.popLast(), draft.isEmpty { draft = u.text }
        }
    }

    private func setNote(_ s: String) {
        guard let i = messages.indices.last else { return }
        messages[i].note = s
    }
}
