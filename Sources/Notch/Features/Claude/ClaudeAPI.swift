import AppKit
import UniformTypeIdentifiers

/// API backend: Messages API over raw HTTP + SSE (Swift has no official Anthropic SDK).
extension ClaudeService {
    func sendAPI(_ text: String) {
        guard let key = apiKey else { error = "Add your Anthropic API key first"; return }
        var blocks: [[String: Any]] = []
        for a in attachments {
            guard let b = Self.block(for: a.url) else { error = "Can't attach \(a.name) (not text, image or PDF, or too large)"; return }
            blocks.append(b)
        }
        blocks.append(["type": "text", "text": text.isEmpty ? "Please look at the attached file(s)." : text])
        messages.append(ChatMessage(role: "user", text: text, attachments: attachments.map(\.name), blocks: blocks))
        messages.append(ChatMessage(role: "assistant", text: ""))
        draft = ""; attachments = []; error = nil
        setStreaming(true)
        apiTask = Task { await stream(key: key) }
    }

    /// Image (png/jpeg/gif/webp; others converted to PNG), PDF, or UTF-8 text file as a content block.
    static func block(for url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), data.count < 30_000_000 else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        if let t = type, t.conforms(to: .image) {
            let ext = url.pathExtension.lowercased()
            let native = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
            if let mt = native[ext] {
                return ["type": "image", "source": ["type": "base64", "media_type": mt, "data": data.base64EncodedString()]]
            }
            guard let png = NSImage(data: data)?.pngData else { return nil }
            return ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]]
        }
        if type?.conforms(to: .pdf) == true {
            return ["type": "document", "title": url.lastPathComponent,
                    "source": ["type": "base64", "media_type": "application/pdf", "data": data.base64EncodedString()]]
        }
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        return ["type": "text", "text": "File: \(url.lastPathComponent)\n```\n\(s)\n```"]
    }

    private func stream(key: String) async {
        defer { setStreaming(false) }
        let history = messages.dropLast().map { ["role": $0.role, "content": $0.blocks] as [String: Any] }
        let body: [String: Any] = [
            "model": Store.shared.config.claudeAPIModel,
            "max_tokens": 64000,
            "stream": true,
            "fallbacks": "default",
            "system": "You are Claude, answering inside a small Dynamic-Island-style panel on the user's Mac. Be concise; use short paragraphs and simple Markdown.",
            "messages": history,
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 600)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var blocks: [[String: Any]] = []
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                var data = Data()
                for try await b in bytes { data.append(b) }
                let j: Any? = try? JSONSerialization.jsonObject(with: data)
                throw NSError(domain: "Claude", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey:
                    "HTTP \(http.statusCode): " + (j["error"]["message"].str ?? String(decoding: data, as: UTF8.self))])
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data:"), let ev = try? JSONSerialization.jsonObject(
                    with: Data(line.dropFirst(5).utf8)) as? [String: Any] else { continue }
                switch ev["type"] as? String {
                case "content_block_start":
                    if let b = ev["content_block"] as? [String: Any] { blocks.append(b) }
                case "content_block_delta":
                    guard let i = ev["index"] as? Int, blocks.indices.contains(i), let d = ev["delta"] as? [String: Any] else { break }
                    switch d["type"] as? String {
                    case "text_delta": blocks[i]["text"] = (blocks[i]["text"] as? String ?? "") + (d["text"] as? String ?? "")
                    case "thinking_delta": blocks[i]["thinking"] = (blocks[i]["thinking"] as? String ?? "") + (d["thinking"] as? String ?? "")
                    case "signature_delta": blocks[i]["signature"] = (blocks[i]["signature"] as? String ?? "") + (d["signature"] as? String ?? "")
                    default: break
                    }
                    updateLast(blocks)
                case "message_delta":
                    let reason = (ev["delta"] as? [String: Any])?["stop_reason"] as? String
                    if reason == "refusal" { note("Claude declined this request.") }
                    if reason == "max_tokens" { note("Reply was cut off (length limit).") }
                case "error":
                    let m = ((ev["error"] as? [String: Any])?["message"] as? String) ?? "Stream error"
                    throw NSError(domain: "Claude", code: 0, userInfo: [NSLocalizedDescriptionKey: m])
                default: break
                }
            }
            updateLast(blocks)
        } catch {
            let cancelled = error is CancellationError || (error as NSError).code == NSURLErrorCancelled
            if !cancelled { self.error = error.localizedDescription }
            // A cut-off reply may hold unsigned thinking blocks the API would reject; keep only text.
            updateLast(blocks.filter { $0["type"] as? String == "text" && !($0["text"] as? String ?? "").isEmpty })
        }
        // An empty reply would make the history invalid: drop the exchange and give the text back.
        if let last = messages.last, last.role == "assistant", last.blocks.isEmpty {
            messages.removeLast()
            if let u = messages.popLast(), draft.isEmpty { draft = u.text }
        }
    }

    private func updateLast(_ blocks: [[String: Any]]) {
        guard let i = messages.indices.last, messages[i].role == "assistant" else { return }
        messages[i].blocks = blocks
        messages[i].text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
    }

    private func note(_ s: String) {
        guard let i = messages.indices.last else { return }
        messages[i].note = s
    }
}

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
