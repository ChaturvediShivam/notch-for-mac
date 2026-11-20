import SwiftUI
import UniformTypeIdentifiers

struct ClaudeView: View {
    @ObservedObject private var svc = ClaudeService.shared
    @ObservedObject private var store = Store.shared
    @FocusState private var focused: Bool
    @State private var key = ""

    var body: some View {
        VStack(spacing: 8) {
            BackendSwitch()
            if !store.config.netClaude {
                Hint("Claude is off. Turn it on in Settings → Privacy.")
            } else if svc.useAPI {
                if svc.hasKey || ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil { chat } else { keyEntry }
            } else if svc.claudePath == nil {
                Hint("Claude Code isn't installed (or not found).\nInstall it from claude.com/claude-code, run `claude` once to log in, then reopen this tab.")
                    .onAppear { svc.locateClaude() }
            } else {
                chat
            }
        }
    }

    private var keyEntry: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.fill").font(.system(size: 20)).foregroundStyle(Theme.orange)
            Text("Add your Anthropic API key").font(Theme.title)
            Text("Stored in your macOS Keychain. Get one at console.anthropic.com.")
                .font(Theme.caption).foregroundStyle(Theme.ink.opacity(0.5))
            HStack {
                SecureField("sk-ant-…", text: $key).textFieldStyle(.plain)
                    .padding(.horizontal, 10).frame(width: 280, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.control))
                    .onSubmit { svc.saveKey(key); key = "" }
                Button("Save") { svc.saveKey(key); key = "" }.buttonStyle(PillButtonStyle(tint: Theme.accent))
                    .disabled(key.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
    }

    private var chat: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if svc.messages.isEmpty {
                            Text("Ask \(svc.useAPI ? "Claude" : "Claude Code") anything. Drop files here, or press ⌃⌥S to ask about part of your screen.")
                                .font(Theme.caption).foregroundStyle(Theme.ink.opacity(0.45))
                                .frame(maxWidth: .infinity).padding(.top, 50)
                        }
                        ForEach(svc.messages) { m in bubble(m).id(m.id) }
                        if let e = svc.error {
                            Text(e).font(Theme.caption).foregroundStyle(Theme.red).textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: svc.messages.last?.text) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .frame(maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { ClaudeService.shared.addFiles([url]) } }
                    }
                }
                return true
            }

            if !svc.attachments.isEmpty { attachmentStrip }
            inputBar
        }
    }

    private func bubble(_ m: ChatMessage) -> some View {
        HStack {
            if m.role == "user" { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 4) {
                if !m.attachments.isEmpty {
                    Text(m.attachments.map { "📎 " + $0 }.joined(separator: "  "))
                        .font(.system(size: 11)).foregroundStyle(Theme.ink.opacity(0.6))
                }
                if !m.tools.isEmpty {
                    Text(m.tools.suffix(4).map { "⚙︎ " + $0 }.joined(separator: "   "))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink.opacity(0.5)).lineLimit(2)
                }
                if m.text.isEmpty && m.role == "assistant" {
                    ProgressView().controlSize(.small)
                } else {
                    Text(Self.markdown(m.text)).font(Theme.body).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let n = m.note { Text(n).font(.system(size: 11)).foregroundStyle(Theme.orange) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(m.role == "user" ? Theme.accent.opacity(0.85) : Theme.card))
            if m.role == "assistant" { Spacer(minLength: 40) }
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(svc.attachments) { a in
                    HStack(spacing: 4) {
                        if let t = a.thumbnail { Image(nsImage: t).resizable().aspectRatio(contentMode: .fill).frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 4)) }
                        else { Image(systemName: "doc.fill") }
                        Text(a.name).font(.system(size: 11)).lineLimit(1)
                        Button { svc.attachments.removeAll { $0.id == a.id } } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(GlyphButtonStyle(radius: 6))
                    }
                    .padding(.horizontal, 6).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.control))
                }
            }
        }
        .frame(height: 26)
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            Button { svc.pickFiles() } label: { Image(systemName: "paperclip").frame(width: 28, height: 28) }
                .buttonStyle(GlyphButtonStyle(radius: 8)).help("Attach files")
            Button { svc.askAboutScreen() } label: { Image(systemName: "camera.viewfinder").frame(width: 28, height: 28) }
                .buttonStyle(GlyphButtonStyle(radius: 8)).help("Ask about part of the screen (⌃⌥S)")
            TextField(svc.useAPI ? "Message Claude" : "Message Claude Code", text: $svc.draft, axis: .vertical)
                .textFieldStyle(.plain).font(Theme.body).lineLimit(1...3)
                .focused($focused)
                .onSubmit { svc.send() }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.control))
                .simultaneousGesture(TapGesture().onEnded { NotchModel.shared.onFocus?(true); focused = true })
            if svc.streaming {
                Button { svc.stop() } label: { Image(systemName: "stop.fill").frame(width: 28, height: 28) }
                    .buttonStyle(GlyphButtonStyle(radius: 8))
            } else {
                Button { svc.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)).frame(width: 28, height: 28) }
                    .buttonStyle(GlyphButtonStyle(radius: 8))
            }
            Menu {
                Button("New chat") { svc.newChat() }
                if svc.useAPI && svc.hasKey { Button("Remove API key") { svc.saveKey("") } }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
        }
        .onAppear { if NotchModel.shared.pinned { DispatchQueue.main.async { focused = true } } }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// One-click switch between Claude Code and the API (also in Settings).
struct BackendSwitch: View {
    @ObservedObject private var store = Store.shared

    var body: some View {
        HStack(spacing: 2) {
            option("code", "Claude Code", "terminal.fill")
            option("api", "API", "key.fill")
        }
        .padding(2)
        .background(Capsule().fill(Theme.card))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func option(_ value: String, _ title: String, _ symbol: String) -> some View {
        let on = store.config.claudeBackend == value
        return Button { ClaudeService.shared.setBackend(value) } label: {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).frame(height: 22)
                .foregroundStyle(on ? Theme.ink : Theme.ink.opacity(0.55))
                .background(Capsule().fill(on ? Theme.control : .clear))
        }
        .buttonStyle(GlyphButtonStyle(radius: 11))
        .help(value == "code" ? "Use Claude Code (your Claude login, no API key)" : "Use the Anthropic API with your key")
    }
}
