import SwiftUI

struct MeetingView: View {
    @ObservedObject private var mt = MeetingService.shared
    @ObservedObject private var store = Store.shared
    /// Typed locally, saved 0.6 s after typing stops: writing config per keystroke redrew the whole notch.
    @State private var draft = Store.shared.config.meetingTopic
    @State private var saveWork: DispatchWorkItem?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            transcriptCard.frame(width: 250)
            assistCard
        }
    }

    // MARK: Left: live transcript

    /// No live transcript on screen (it's still captured for Claude and saved when you stop).
    private var transcriptCard: some View {
        Card(title: "Meeting", trailing: AnyView(controls)) {
            VStack(spacing: 6) {
                if mt.active {
                    Text("Listening · \(mt.lines.count) lines captured").font(Theme.caption).foregroundStyle(.white.opacity(0.7))
                    meters
                    Text("Transcript saves when you stop; it deletes after 24 h unless you keep it.")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).multilineTextAlignment(.center)
                } else {
                    Text("Start before the call. Questions from either side get an answer card by themselves.")
                        .font(Theme.caption).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
                }
                contextBox
                Toggle("Start and stop with calls (Zoom, Meet, Teams…)", isOn: $store.config.meetingAuto)
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
                if !mt.status.isEmpty { Text(mt.status).font(.system(size: 10)).foregroundStyle(Theme.orange).multilineTextAlignment(.center) }
                if mt.needsScreenPermission {
                    Button("Open Screen Recording settings") { mt.openScreenRecordingSettings() }.buttonStyle(PillButtonStyle(tint: Theme.accent))
                }
                if !mt.active && !mt.sessions.isEmpty { sessionList }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Paste anything: a topic line, your resume, the job description, agenda, notes. Answers use it as facts.
    private var contextBox: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Context").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                Spacer()
                if !draft.isEmpty {
                    Text("\(draft.count) chars").font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
                    Button("Clear") { draft = ""; commit() }.buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
                }
                Button("From file…") { mt.loadContextFile() }.buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(Theme.accent)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(.system(size: 10)).scrollContentBackground(.hidden)
                if draft.isEmpty {
                    Text("Topic, or paste your resume, job description, agenda…").font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3)).padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .padding(4).frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.control))
            .help("Answers use this as facts about you and the subject, and to fix misheard words")
        }
        .onChange(of: draft) { _ in
            saveWork?.cancel()
            let w = DispatchWorkItem { commit() }
            saveWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
        }
        .onChange(of: store.config.meetingTopic) { v in if v != draft, saveWork == nil { draft = v } }  // "From file…"
        .onDisappear { commit() }
    }

    private func commit() {
        saveWork?.cancel(); saveWork = nil
        if store.config.meetingTopic != draft { store.config.meetingTopic = draft }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if !mt.active {
                Menu {
                    ForEach(MeetingService.languages, id: \.id) { l in
                        Button { store.config.meetingLocale = l.id } label: {
                            if l.id == store.config.meetingLocale { Label(l.name, systemImage: "checkmark") } else { Text(l.name) }
                        }
                    }
                } label: {
                    Text(["en-IN": "Hinglish", "hi-IN": "Hindi", "en-US": "English US", "en-GB": "English UK"][store.config.meetingLocale] ?? store.config.meetingLocale)
                        .font(.system(size: 10))
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if let s = mt.startedAt, mt.active {
                Text(s, style: .timer).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.red)
            }
            Button(mt.active ? "Stop" : "Start") { mt.toggle() }
                .buttonStyle(PillButtonStyle(tint: mt.active ? Theme.red : Theme.green))
                .fixedSize()
        }
    }

    /// Past meetings: keep the useful ones, the rest delete themselves 24 h after saving.
    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Saved meetings · unkept ones delete after 24 h")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.4)).padding(.top, 6)
            ScrollView {
                VStack(spacing: 2) { ForEach(mt.sessions) { sessionRow($0) } }
            }
            .frame(maxHeight: 110)
        }
    }

    private func sessionRow(_ s: MeetSession) -> some View {
        HStack(spacing: 6) {
            Button { NSWorkspace.shared.open(s.url) } label: {
                Text(s.name.replacingOccurrences(of: "Meeting ", with: "")).font(Theme.caption).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain).help("Open")
            Text(s.kept ? "Kept" : left(s)).font(.system(size: 9).monospacedDigit())
                .foregroundStyle(s.kept ? Theme.green : .white.opacity(0.45))
            Button { mt.setKept(s, !s.kept) } label: {
                Image(systemName: s.kept ? "bookmark.fill" : "bookmark").font(.system(size: 10)).frame(width: 22, height: 20)
            }
            .buttonStyle(GlyphButtonStyle(radius: 6)).help(s.kept ? "Stop keeping (deletes in 24 h)" : "Keep forever")
            Button { mt.delete(s) } label: {
                Image(systemName: "trash").font(.system(size: 10)).frame(width: 22, height: 20)
            }
            .buttonStyle(GlyphButtonStyle(radius: 6)).help("Delete now")
        }
    }

    private func left(_ s: MeetSession) -> String {
        let h = max(0, Int((MeetingService.lifetime - Date().timeIntervalSince(s.date)) / 3600))
        return h < 1 ? "< 1 h left" : "\(h) h left"
    }

    /// Two tiny meters: is each side actually reaching us?
    private var meters: some View {
        HStack(spacing: 8) {
            meter("Them", mt.themLevel, Theme.orange)
            meter("Me", mt.meLevel, Theme.accent)
        }
    }

    private func meter(_ name: String, _ v: Double, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(name).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.control)
                Capsule().fill(tint).frame(width: 36 * v)
            }
            .frame(width: 36, height: 4)
        }
    }

    // MARK: Right: live answers

    /// Which AI writes the answers: your own subscription or key. Keys and models live in Settings.
    private var aiMenu: some View {
        let id = store.config.meetingAI
        return Menu {
            ForEach(ClaudeRunner.providers, id: \.id) { p in
                Button { store.config.meetingAI = p.id } label: {
                    if p.id == id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
            Divider()
            Button("Keys and models… (Settings)") { NotchModel.shared.setTab(.settings) }
        } label: {
            Text("AI: " + (["claude": "Claude", "codex": "Codex", "gemini-cli": "Gemini CLI", "openai": "ChatGPT",
                            "gemini": "Gemini", "ollama": "Ollama", "custom": "Custom"][id] ?? id)).font(.system(size: 10))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Use your own AI: Claude Code, Codex (ChatGPT plan), Gemini, Ollama or an API key")
    }

    private var assistCard: some View {
        Card(title: "Answers", trailing: AnyView(HStack(spacing: 8) {
            aiMenu
            Toggle("Auto", isOn: $mt.autoAnswer).toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
                .help("When someone asks a question, suggest a reply automatically (only while Meeting mode is on)")
        })) {
            VStack(spacing: 6) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if mt.suggestions.isEmpty {
                            Text(mt.autoAnswer
                                 ? "Their question → what you can say. Your question → what a good answer looks like, plus a follow-up. Lost? Samjhao (⌃⌥E)."
                                 : "Auto answers are off. Press Samjhao (⌃⌥E) or type a question.")
                                .font(Theme.caption).foregroundStyle(.white.opacity(0.45))
                        }
                        ForEach(mt.suggestions) { s in suggestion(s) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                TextField("Ask about the meeting…", text: $mt.question)
                    .textFieldStyle(.plain).font(Theme.caption)
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.control))
                    .onSubmit { mt.ask() }
                HStack(spacing: 6) {
                    Button("Samjhao") { mt.ask() }.buttonStyle(PillButtonStyle(tint: Theme.accent))
                    Button("Summary") { mt.summarize() }.buttonStyle(PillButtonStyle())
                    Spacer()
                    if mt.busy { ProgressView().controlSize(.mini) }
                }
                .disabled(mt.lines.isEmpty)
            }
        }
    }

    private func suggestion(_ s: Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                let mine = s.title.hasPrefix(MeetingService.minePrefix)
                Image(systemName: mine ? "person.fill.questionmark" : s.auto ? "questionmark.bubble.fill" : "sparkles")
                    .font(.system(size: 9)).foregroundStyle(mine ? Theme.green : s.auto ? Theme.orange : Theme.accent)
                Text(s.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
            }
            if let f = s.failed {
                Text(f).font(.system(size: 10)).foregroundStyle(Theme.red)
            } else if s.text.isEmpty {
                ProgressView().controlSize(.mini)
            } else {
                Text(ClaudeView.markdown(s.text)).font(Theme.caption).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(s.auto ? Theme.orange.opacity(0.12) : Theme.control.opacity(0.5)))
    }
}
