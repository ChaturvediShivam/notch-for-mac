import SwiftUI

struct MeetingView: View {
    @ObservedObject private var mt = MeetingService.shared
    @ObservedObject private var store = Store.shared
    /// Which context box is showing: 0 CV, 1 Job, 2 My words.
    @State private var field = 0
    /// Typed locally, saved 0.6 s after typing stops: writing config per keystroke redrew the whole notch.
    @State private var draft = Store.shared.config.meetingCV
    @State private var saveWork: DispatchWorkItem?
    @State private var showSaved = false

    private var fields: [(key: WritableKeyPath<Config, String>, label: String, hint: String)] {
        MeetingService.contextFields(interviewing: store.config.meetingRole == "interview")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            transcriptCard.frame(width: 262)
            assistCard
        }
    }

    // MARK: Left: role, context, status

    private var transcriptCard: some View {
        Card(title: "Meeting", trailing: AnyView(controls)) {
            VStack(alignment: .leading, spacing: 6) {
                rolePicker
                if mt.active {
                    HStack(spacing: 8) {
                        Text("Listening · \(mt.lines.count) lines").font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                        Spacer(); meters
                    }
                }
                if mt.active, let r = mt.resumed { resumeBanner(r) }
                if !mt.status.isEmpty { Text(mt.status).font(.system(size: 10)).foregroundStyle(Theme.orange).lineLimit(2) }
                if mt.needsScreenPermission {
                    Button("Open Screen Recording settings") { mt.openScreenRecordingSettings() }.buttonStyle(PillButtonStyle(tint: Theme.accent))
                }
                if showSaved { sessionList } else { contextBox }
                HStack(spacing: 6) {
                    Toggle("Auto with calls", isOn: $store.config.meetingAuto)
                        .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
                        .help("Start and stop with Zoom, Meet, Teams… calls")
                    Spacer()
                    if !mt.sessions.isEmpty {
                        Button(showSaved ? "Context" : "Saved (\(mt.sessions.count))") { commit(); showSaved.toggle() }
                            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.accent)
                            .help("Saved meetings: unkept ones delete after 24 h")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// Rejoined within 30 min: this meeting carries on the last one. One tap starts empty instead.
    private func resumeBanner(_ from: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.forward.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.green)
            Text("Continuing from \(from.formatted(date: .omitted, time: .shortened))").font(.system(size: 10))
            Spacer()
            Button("New meeting") { mt.startFresh() }.buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accent).help("Forget the earlier part (it's already saved) and start empty")
        }
        .padding(.horizontal, 8).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.green.opacity(0.15)))
    }

    /// Who is asking decides what the cards do.
    private var rolePicker: some View {
        HStack(spacing: 4) {
            roleChip("answer", "I'm answering", "person.wave.2", "Their questions → what to say. For interviews you give, client calls, meetings.")
            roleChip("interview", "I'm interviewing", "person.fill.questionmark", "Their answers → how good it was, and what to ask next.")
        }
    }

    private func roleChip(_ id: String, _ name: String, _ icon: String, _ help: String) -> some View {
        let on = store.config.meetingRole == id
        return Button {
            guard !on else { return }
            commit(); store.config.meetingRole = id
        } label: {
            Label(name, systemImage: icon).font(.system(size: 10, weight: on ? .semibold : .regular))
                .frame(maxWidth: .infinity).frame(height: 22)
                .foregroundStyle(on ? .white : .white.opacity(0.55))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? Theme.accent.opacity(0.35) : Theme.control.opacity(0.6)))
        }
        .buttonStyle(.plain).help(help)
    }

    /// Three boxes: CV, job/agenda, and your own words. Answers use them as facts.
    private var contextBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                ForEach(fields.indices, id: \.self) { i in
                    let filled = !store.config[keyPath: fields[i].key].isEmpty
                    Button { select(i) } label: {
                        HStack(spacing: 3) {
                            Circle().fill(filled ? Theme.green : .white.opacity(0.2)).frame(width: 5, height: 5)
                            Text(fields[i].label).font(.system(size: 10, weight: field == i ? .semibold : .regular)).lineLimit(1)
                        }
                        .padding(.horizontal, 7).frame(height: 20)
                        .foregroundStyle(field == i ? .white : .white.opacity(0.5))
                        .background(Capsule().fill(field == i ? Theme.control : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft).font(.system(size: 10)).scrollContentBackground(.hidden)
                if draft.isEmpty {
                    Text(fields[field].hint).font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                        .padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                }
            }
            .padding(4).frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.control))
            HStack(spacing: 10) {
                Button("Paste") {
                    guard let t = NSPasteboard.general.string(forType: .string), !t.isEmpty else { return }
                    draft = draft.isEmpty ? t : draft + "\n\n" + t; commit()
                }
                .help("Add what you copied")
                Button("From file…") { commit(); mt.loadContextFile(into: fields[field].key) }
                    .help("Text, Markdown or PDF (e.g. a resume)")
                if !draft.isEmpty { Button("Clear") { draft = ""; commit() } }
                Spacer()
                if !draft.isEmpty { Text("\(draft.count)").font(.system(size: 9).monospacedDigit()).foregroundStyle(.white.opacity(0.35)) }
            }
            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.accent)
        }
        .onChange(of: draft) { _ in
            saveWork?.cancel()
            let w = DispatchWorkItem { commit() }
            saveWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
        }
        // "From file…" or Delete-all changed the store: show it.
        .onChange(of: store.config[keyPath: fields[field].key]) { v in if v != draft, saveWork == nil { draft = v } }
        .onDisappear { commit() }
    }

    private func select(_ i: Int) {
        commit()
        field = i
        draft = store.config[keyPath: fields[i].key]
    }

    private func commit() {
        saveWork?.cancel(); saveWork = nil
        let k = fields[field].key
        if store.config[keyPath: k] != draft { store.config[keyPath: k] = draft }
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
        ScrollView {
            VStack(spacing: 2) { ForEach(mt.sessions) { sessionRow($0) } }
        }
        .frame(maxHeight: .infinity)
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
        Card(title: mt.interviewing ? "What to ask" : "Answers", trailing: AnyView(HStack(spacing: 8) {
            aiMenu
            Toggle("Auto", isOn: $mt.autoAnswer).toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
                .help("When someone asks a question, suggest a reply automatically (only while Meeting mode is on)")
        })) {
            VStack(spacing: 6) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if mt.suggestions.isEmpty {
                            Text(!mt.autoAnswer ? "Auto cards are off. Press Samjhao (⌃⌥E) or type a question."
                                 : mt.interviewing
                                 ? "You ask → what a strong answer contains. They answer → a quick verdict and 2–3 follow-up questions. Fill the CV and Job boxes for sharper questions."
                                 : "Their question → what you can say. Your question → what a good answer looks like. Fill CV, Job and My words for answers about you.")
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
