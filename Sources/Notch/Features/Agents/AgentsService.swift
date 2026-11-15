import AppKit

struct Approval: Identifiable {
    let id: UUID
    let session: String
    let cwd: String
    let tool: String
    let summary: String
    let date = Date()
    let resolve: (String?) -> Void      // "allow", "deny", or nil = let Claude Code ask as usual
}

struct AgentSession: Identifiable {
    let id: String
    var cwd: String
    var status: String                   // "Working", "Waiting for you", "Finished"
    var last: Date
}

/// Claude Code hooks → Notch. PreToolUse waits here until you press Allow / Deny.
/// If Notch isn't running the hook script prints nothing and Claude Code behaves normally.
@MainActor
final class AgentsService: ObservableObject {
    static let shared = AgentsService()

    @Published private(set) var pending: [Approval] = []
    @Published private(set) var history: [(Date, String, String)] = []    // date, summary, decision
    @Published private(set) var sessions: [String: AgentSession] = [:]
    @Published var askInNotch = true
    @Published private(set) var installed = false
    @Published var installMessage = ""

    private static let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")
    private static let hookURL = Paths.home.appendingPathComponent("hooks/notch-hook.sh")

    private init() {
        installed = Self.hooksInstalled()
        if installed { writeHookScript() }
        let s = LocalServer.shared
        s.route("POST", "/hook/pretooluse") { r in await AgentsService.shared.preToolUse(r.json) }
        s.route("POST", "/hook/notification") { r in
            let j = r.json
            AgentsService.shared.touch(j, status: "Waiting for you")
            AlertsService.shared.add(title: j["title"] as? String ?? "Claude Code",
                                     body: j["message"] as? String ?? "", source: "Claude Code")
            return (200, [String: Any]())
        }
        s.route("POST", "/hook/stop") { r in
            let j = r.json
            AgentsService.shared.touch(j, status: "Finished")
            let dir = (j["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
            AlertsService.shared.add(title: "Claude Code finished", body: dir, source: "Claude Code")
            return (200, [String: Any]())
        }
    }

    private func touch(_ j: [String: Any], status: String) {
        guard let id = j["session_id"] as? String else { return }
        sessions[id] = AgentSession(id: id, cwd: j["cwd"] as? String ?? sessions[id]?.cwd ?? "", status: status, last: Date())
    }

    private func preToolUse(_ j: [String: Any]) async -> (Int, Any) {
        touch(j, status: "Working")
        guard askInNotch else { return (200, [String: Any]()) }
        let tool = j["tool_name"] as? String ?? "Tool"
        let input = j["tool_input"] as? [String: Any] ?? [:]
        let summary = (input["command"] ?? input["file_path"] ?? input["url"] ?? input["notebook_path"]).map { "\($0)" }
            ?? String(describing: input).prefix(200).description

        let decision: String? = await withCheckedContinuation { cont in
            var done = false
            let id = UUID()
            let a = Approval(id: id, session: j["session_id"] as? String ?? "", cwd: j["cwd"] as? String ?? "",
                             tool: tool, summary: summary) { d in
                guard !done else { return }
                done = true
                AgentsService.shared.pending.removeAll { $0.id == id }
                cont.resume(returning: d)
            }
            pending.append(a)
            touch(j, status: "Waiting for you")
            NSSound(named: "Pop")?.play()
            NotchModel.shared.show(.agents)
            // Give up after 5 minutes and let Claude Code ask in the terminal.
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { a.resolve(nil) }
        }
        touch(j, status: "Working")
        history.insert((Date(), "\(tool): \(summary)", decision ?? "asked in terminal"), at: 0)
        if history.count > 30 { history.removeLast() }
        if pending.isEmpty, NotchModel.shared.tab == .agents { NotchModel.shared.pinned = false }
        guard let decision else { return (200, [String: Any]()) }
        return (200, ["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": decision == "allow" ? "Approved in Notch" : "Denied in Notch",
        ]])
    }

    // MARK: Install hooks into ~/.claude/settings.json

    static func hooksInstalled() -> Bool {
        guard let s = try? String(contentsOf: settingsURL, encoding: .utf8) else { return false }
        return s.contains("notch-hook.sh")
    }

    private func writeHookScript() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.hookURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let port = Store.shared.config.apiPort
            let script = """
            #!/bin/sh
            # Forwards a Claude Code hook event to Notch. If Notch isn't running this prints
            # nothing and exits 0, so Claude Code carries on exactly as normal.
            # Notch's own Claude runs (chat, meeting answers) don't need "finished" alerts.
            case "$1" in stop|notification) [ -n "$NOTCH_INTERNAL" ] && exit 0;; esac
            TOKEN=$(cat "$HOME/.notch/token" 2>/dev/null) || exit 0
            curl -s --max-time 310 -X POST "http://127.0.0.1:\(port)/hook/$1" \\
              -H "X-Notch-Token: $TOKEN" -H 'Content-Type: application/json' --data-binary @- || true
            exit 0

            """
        try? script.write(to: Self.hookURL, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.hookURL.path)
    }

    func installHooks() {
        do {
            let fm = FileManager.default
            writeHookScript()

            var root: [String: Any] = [:]
            if let d = try? Data(contentsOf: Self.settingsURL) {
                guard let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                    installMessage = "~/.claude/settings.json isn't a JSON object; left untouched"; return
                }
                root = obj
                try d.write(to: Self.settingsURL.appendingPathExtension("notch-backup"))
            }
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            let cmd = Self.hookURL.path
            func entry(_ event: String, matcher: String?, timeout: Int) -> [String: Any] {
                var e: [String: Any] = ["hooks": [["type": "command", "command": "\(cmd) \(event)", "timeout": timeout]]]
                if let matcher { e["matcher"] = matcher }
                return e
            }
            for (event, arg, matcher, timeout) in [("PreToolUse", "pretooluse", "Bash|Edit|Write|MultiEdit|NotebookEdit", 320),
                                                   ("Notification", "notification", nil, 10),
                                                   ("Stop", "stop", nil, 10)] as [(String, String, String?, Int)] {
                var list = (hooks[event] as? [[String: Any]] ?? []).filter { !"\($0)".contains("notch-hook.sh") }
                list.append(entry(arg, matcher: matcher, timeout: timeout))
                hooks[event] = list
            }
            root["hooks"] = hooks
            try fm.createDirectory(at: Self.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
                .write(to: Self.settingsURL, options: .atomic)
            installed = true
            installMessage = "Installed. Backup at ~/.claude/settings.json.notch-backup"
        } catch {
            installMessage = "Install failed: \(error.localizedDescription)"
        }
    }

    func uninstallHooks() {
        guard let d = try? Data(contentsOf: Self.settingsURL),
              var root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else { installed = false; return }
        for (k, v) in hooks {
            let list = (v as? [[String: Any]] ?? []).filter { !"\($0)".contains("notch-hook.sh") }
            hooks[k] = list.isEmpty ? nil : list
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            .write(to: Self.settingsURL, options: .atomic)
        installed = Self.hooksInstalled()
        installMessage = installed ? "Couldn't remove hooks" : "Removed"
    }
}
