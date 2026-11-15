import Foundation

/// One-shot, streaming answer from whichever backend is selected (Claude Code or API),
/// separate from the chat. Used by Meeting for live suggestions, so it's tuned for speed:
/// Claude Code runs without your settings/hooks/MCP/tools and without saving a session.
enum ClaudeRunner {
    @MainActor
    static func stream(_ prompt: String) -> AsyncThrowingStream<String, Error> {
        let cfg = Store.shared.config
        if cfg.claudeBackend == "api" {
            guard let key = ClaudeService.shared.apiKey else {
                return AsyncThrowingStream { $0.finish(throwing: err("Add your Anthropic API key in the Claude tab")) }
            }
            return api(prompt, key: key, model: cfg.claudeAPIModel)
        }
        guard let claude = ClaudeService.shared.claudePath else {
            return AsyncThrowingStream { $0.finish(throwing: err("Claude Code not found")) }
        }
        return code(prompt, claude: claude, model: cfg.claudeModel)
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
}
