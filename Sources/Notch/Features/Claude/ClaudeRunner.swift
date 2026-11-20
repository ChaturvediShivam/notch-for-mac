import Foundation
import os

/// One-shot, streaming answer for Meeting, separate from the chat, tuned for speed.
/// Uses your own AI: Claude (Claude Code login or Anthropic key, as set in the Claude tab),
/// a subscription CLI you're logged into (Codex = ChatGPT plan, Gemini CLI = Google login),
/// or any OpenAI-compatible API: ChatGPT, Gemini, Ollama on this Mac, OpenRouter/Groq/LM Studio.
/// Claude Code runs without your settings/hooks/MCP/tools and without saving a session.
enum ClaudeRunner {
    struct Provider { let id, name, base, hint: String; let needsKey: Bool; var cli = "" }
    static let providers = [
        Provider(id: "claude", name: "Claude (as in the Claude tab)", base: "", hint: "sonnet (default)", needsKey: false),
        Provider(id: "codex", name: "Codex CLI (ChatGPT plan login)", base: "", hint: "default (optional)", needsKey: false, cli: "codex"),
        Provider(id: "gemini-cli", name: "Gemini CLI (Google login)", base: "", hint: "default (optional)", needsKey: false, cli: "gemini"),
        Provider(id: "openai", name: "ChatGPT (OpenAI API key)", base: "https://api.openai.com/v1", hint: "e.g. gpt-5-mini", needsKey: true),
        Provider(id: "gemini", name: "Gemini (Google AI Studio key)", base: "https://generativelanguage.googleapis.com/v1beta/openai", hint: "e.g. gemini-2.5-flash", needsKey: true),
        Provider(id: "ollama", name: "Ollama (free, runs on this Mac)", base: "http://localhost:11434/v1", hint: "e.g. gemma4", needsKey: false),
        Provider(id: "custom", name: "Other OpenAI-compatible (OpenRouter, Groq…)", base: "", hint: "model id", needsKey: true),
    ]
    /// Keychain account for a provider's key.
    static func keyName(_ id: String) -> String { "ai-" + id }

    @MainActor
    static func stream(_ prompt: String) -> AsyncThrowingStream<String, Error> {
        let cfg = Store.shared.config
        if let p = providers.first(where: { $0.id == cfg.meetingAI }), p.id != "claude" {
            let model = (cfg.aiModels[p.id] ?? "").trimmingCharacters(in: .whitespaces)
            if !p.cli.isEmpty { return cli(prompt, name: p.cli, model: model) }
            let base = p.id == "custom" ? cfg.aiBaseURL : p.base
            let key = Keychain.get(keyName(p.id))
            if model.isEmpty || base.isEmpty || (p.needsKey && key == nil) {
                return AsyncThrowingStream { $0.finish(throwing: err("Set up \(p.name) in Settings → Meeting answers")) }
            }
            return openAI(prompt, base: base, key: key, model: model)
        }
        // Meeting has its own Claude model (Settings → Meeting answers → Model), Sonnet by default:
        // fast enough to read during a call, and the Claude tab keeps whatever it uses (e.g. Opus).
        let typed = (cfg.aiModels["claude"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let meet = typed.isEmpty ? "sonnet" : typed
        if cfg.claudeBackend == "api" {
            guard let key = ClaudeService.shared.apiKey else {
                return AsyncThrowingStream { $0.finish(throwing: err("Add your Anthropic API key in the Claude tab")) }
            }
            return api(prompt, key: key, model: ["sonnet": "claude-sonnet-5-5", "haiku": "claude-haiku-5-5", "opus": "claude-opus-5-5"][meet] ?? meet)
        }
        guard let claude = ClaudeService.shared.claudePath else {
            return AsyncThrowingStream { $0.finish(throwing: err("Claude Code not found")) }
        }
        return code(prompt, claude: claude, model: meet)
    }

    private static func err(_ s: String) -> NSError { NSError(domain: "Claude", code: 0, userInfo: [NSLocalizedDescriptionKey: s]) }

    private static func code(_ prompt: String, claude: String, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: claude)
            var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                        "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence",
                        "--disallowedTools", "Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,Task,NotebookEdit,MultiEdit"]
            if !model.isEmpty { args += ["--model", model] }
            p.arguments = args
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "\((claude as NSString).deletingLastPathComponent):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            env["NOTCH_INTERNAL"] = "1"
            p.environment = env
            let out = Pipe(), inp = Pipe()
            p.standardOutput = out; p.standardInput = inp; p.standardError = Pipe()
            var buffer = Data()
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { h.readabilityHandler = nil; return }
                buffer.append(d)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    let j: Any? = o
                    if o["type"] as? String == "stream_event", j["event"]["type"].str == "content_block_delta",
                       let t = j["event"]["delta"]["text"].str { cont.yield(t) }
                    if o["type"] as? String == "result", o["is_error"] as? Bool == true {
                        cont.finish(throwing: err(o["result"] as? String ?? "Claude Code error"))
                    }
                }
            }
            p.terminationHandler = { proc in
                proc.terminationStatus == 0 ? cont.finish() : cont.finish(throwing: err("Claude Code exited (\(proc.terminationStatus)). Is it logged in?"))
            }
            cont.onTermination = { _ in if p.isRunning { p.terminate() } }
            do {
                try p.run()
                inp.fileHandleForWriting.write(Data(prompt.utf8))
                try? inp.fileHandleForWriting.close()
            } catch { cont.finish(throwing: error) }
        }
    }

    private static func api(_ prompt: String, key: String, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 120)
                req.httpMethod = "POST"
                req.setValue(key, forHTTPHeaderField: "x-api-key")
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: [
                    "model": model, "max_tokens": 2000, "stream": true, "fallbacks": "default",
                    "output_config": ["effort": "low"],          // live suggestions: fast beats deep
                    "messages": [["role": "user", "content": prompt]],
                ] as [String: Any])
                do {
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw err("HTTP \(h.statusCode)") }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:"),
                              let o = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) else { continue }
                        let j: Any? = o
                        if j["type"].str == "content_block_delta", j["delta"]["type"].str == "text_delta", let t = j["delta"]["text"].str {
                            cont.yield(t)
                        }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// OpenAI-style /chat/completions with SSE: OpenAI, Gemini's compatible endpoint, Ollama, OpenRouter, Groq…
    private static func openAI(_ prompt: String, base: String, key: String?, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/chat/completions") else {
                    cont.finish(throwing: err("Bad base URL")); return
                }
                var req = URLRequest(url: url, timeoutInterval: 120)
                req.httpMethod = "POST"
                if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: [
                    "model": model, "stream": true,
                    "messages": [["role": "user", "content": prompt]],
                ] as [String: Any])
                do {
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                        var data = Data()
                        for try await b in bytes { data.append(b) }
                        let j: Any? = try? JSONSerialization.jsonObject(with: data)
                        throw err("HTTP \(h.statusCode): " + (j["error"]["message"].str ?? String(decoding: data.prefix(200), as: UTF8.self)))
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:"),
                              let o = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any],
                              let c = o["choices"] as? [[String: Any]],
                              let t = (c.first?["delta"] as? [String: Any])?["content"] as? String, !t.isEmpty else { continue }
                        cont.yield(t)
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// GUI apps don't get your shell PATH (npm/nvm/Homebrew), so check the usual spots, then ask your shell.
    static func locate(_ name: String) async -> String? {
        let h = NSHomeDirectory()
        for d in ["/opt/homebrew/bin", "/usr/local/bin", "\(h)/.local/bin", "\(h)/.npm-global/bin", "\(h)/.bun/bin"]
        where FileManager.default.isExecutableFile(atPath: "\(d)/\(name)") { return "\(d)/\(name)" }
        let out = await Shell.run("/bin/zsh", ["-ilc", "command -v \(name)"]).out
        let p = out.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// Subscription CLIs print only the final answer on stdout, so it arrives in one piece (no token streaming).
    private static func cli(_ prompt: String, name: String, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let p = Process()
            let task = Task {
                guard let exe = await locate(name) else {
                    cont.finish(throwing: err("\(name) not found. Install it and log in once in Terminal.")); return
                }
                p.executableURL = URL(fileURLWithPath: exe)
                var args: [String]
                if name == "codex" {
                    // Read-only, no session file, low effort: a quick one-shot answer, no tools touching files.
                    args = ["exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only",
                            "-c", "model_reasoning_effort=low"]
                    if !model.isEmpty { args += ["-m", model] }
                    args.append("-")                         // prompt from stdin
                } else {
                    args = ["-p", prompt]                    // gemini: prompt as argument, plain text out
                    if !model.isEmpty { args += ["-m", model] }
                }
                p.arguments = args
                p.currentDirectoryURL = FileManager.default.temporaryDirectory
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "\((exe as NSString).deletingLastPathComponent):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                p.environment = env
                let out = Pipe(), errp = Pipe(), inp = Pipe()
                p.standardOutput = out; p.standardError = errp; p.standardInput = inp
                out.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil } else { cont.yield(String(decoding: d, as: UTF8.self)) }
                }
                let errTail = OSAllocatedUnfairLock(initialState: Data())   // keep draining stderr (progress) so the pipe never fills and blocks codex
                errp.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil } else { errTail.withLock { $0 = ($0 + d).suffix(2000) } }
                }
                p.terminationHandler = { proc in
                    out.fileHandleForReading.readabilityHandler = nil
                    if let rest = try? out.fileHandleForReading.readToEnd(), !rest.isEmpty { cont.yield(String(decoding: rest, as: UTF8.self)) }
                    if proc.terminationStatus == 0 { cont.finish(); return }
                    errp.fileHandleForReading.readabilityHandler = nil
                    let e = String(decoding: errTail.withLock { $0 }, as: UTF8.self)
                    let last = e.split(separator: "\n").last.map(String.init) ?? ""
                    cont.finish(throwing: err("\(name) exited (\(proc.terminationStatus)). Logged in? \(last.prefix(160))"))
                }
                do {
                    try p.run()
                    if name == "codex" { inp.fileHandleForWriting.write(Data(prompt.utf8)) }
                    try? inp.fileHandleForWriting.close()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel(); if p.isRunning { p.terminate() } }
        }
    }
}
