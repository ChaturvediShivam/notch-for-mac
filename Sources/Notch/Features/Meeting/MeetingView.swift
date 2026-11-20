import SwiftUI

struct MeetingView: View {
    @ObservedObject private var mt = MeetingService.shared
    @ObservedObject private var store = Store.shared
    /// Which context box is showing: 0 CV, 1 Job, 2 My words.
    @State private var field = 0
    /// Typed locally, saved 0.6 s after typing stops: writing config per keystroke redrew the whole notch.
    @State private var draft = Store.shared.config.meetingCV
    @State private var saveWork: DispatchWorkItem?
    @State private var confirmDelete: URL?

    private var fields: [(key: WritableKeyPath<Config, String>, label: String, hint: String)] {
        MeetingService.contextFields(interviewing: store.config.meetingRole == "interview")
    }

    /// Cards that float over the answers: saved meetings, the gear sheet, the context editor.
    private enum Sheet { case saved, settings, context }
    @State private var sheet: Sheet?

    /// One row of controls, the answers get everything else, one ask bar at the bottom.
    var body: some View {
        VStack(spacing: 8) {
            topBar
            VStack(spacing: 8) {
                answers.overlay(alignment: .bottom) { notice }
                askBar
            }
            .overlay(alignment: .topTrailing) { if let sheet { sheetCard(sheet) } }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 6) {
            startButtons
            HStack(spacing: 8) {
                if let s = mt.startedAt, mt.active {
                    Text(s, style: .timer).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.red)
                }
                meters
            }
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(Theme.control.opacity(0.6)))
            Spacer(minLength: 4)
            if mt.practicing || mt.interviewing {
                modeMenu.padding(.horizontal, 10).frame(height: 24).background(Capsule().fill(Theme.control))
            } else {
                pill("Auto", $mt.autoAnswer, "When someone asks a question, suggest a reply automatically")
                pill("Keywords", $store.config.keywordCards, "Answer cards start with 3–4 keywords to glance at, so you talk in your own words")
            }
            if !mt.sessions.isEmpty { icon("folder", .saved, "Saved meetings: unkept ones delete after 24 h") }
            icon("gearshape", .settings, "Mode, delivery coach, language, AI, context")
        }
    }

    private var startButtons: some View {
        HStack(spacing: 6) {
            if !mt.active, let r = mt.resumable {
                // Stopped a little while ago (dropped call?): rejoin it, or start a new one.
                Button("Rejoin") { mt.startManually(fresh: false) }
                    .buttonStyle(PillButtonStyle(tint: Theme.green)).fixedSize()
                    .help("Carry on the meeting from \(r.formatted(date: .omitted, time: .shortened)): same transcript and answers")
                Button("New") { mt.startManually(fresh: true) }
                    .buttonStyle(PillButtonStyle()).fixedSize()
                    .help("Start an empty meeting (the last one is already saved)")
            } else {
                Button(mt.active ? "Stop" : "Start") { mt.toggle() }
                    .buttonStyle(PillButtonStyle(tint: mt.active ? Theme.red : Theme.accent)).fixedSize()
            }
        }
    }

    private func pill(_ name: String, _ on: Binding<Bool>, _ help: String) -> some View {
        Button(name) { on.wrappedValue.toggle() }
            .buttonStyle(PillButtonStyle(tint: on.wrappedValue ? Theme.accent : nil)).fixedSize().help(help)
    }

    private func icon(_ symbol: String, _ s: Sheet, _ help: String) -> some View {
        Button { toggleSheet(s) } label: {
            Image(systemName: sheet == s ? symbol + ".fill" : symbol).font(.system(size: 13)).frame(width: 26, height: 24)
        }
        .buttonStyle(GlyphButtonStyle(radius: 12)).help(help)
    }

    private func toggleSheet(_ s: Sheet) {
        commit()
        withAnimation(.easeOut(duration: 0.15)) { sheet = sheet == s ? nil : s }
    }

    private static let modes = [("answer", "Answer", "Live help: their questions → what you can say"),
                                ("practice", "Practice", "Mock interview: after each of your answers, a score and a better way to say it"),
                                ("interview", "Interviewer", "You're the interviewer: their answers → a verdict and what to ask next")]

    private var modeMenu: some View {
        Menu {
            ForEach(Self.modes, id: \.0) { m in
                Button { commit(); store.config.meetingRole = m.0 } label: {
                    if m.0 == store.config.meetingRole { Label(m.1, systemImage: "checkmark") } else { Text(m.1) }
                }
            }
        } label: {
            Text(Self.modes.first { $0.0 == store.config.meetingRole }?.1 ?? "Answer").font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(Self.modes.first { $0.0 == store.config.meetingRole }?.2 ?? "")
    }

    // MARK: Answers

    private var answers: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if mt.active, let r = mt.resumed { resumeBanner(r) }
                if mt.suggestions.isEmpty {
                    Text(!mt.autoAnswer ? "Auto cards are off. Press Samjhao (⌃⌥E) or type a question."
                         : mt.practicing
                         ? "Practice: answer out loud as if it's real. When you stop for 3 seconds you get a score, what to fix and a better way to say it."
                         : mt.interviewing
                         ? "You ask → what a strong answer contains. They answer → a quick verdict and 2–3 follow-up questions."
                         : "Start the meeting. Their questions are answered here; your own questions get no card. Add your CV and the job in ⚙ → Context.")
                        .font(Theme.caption).foregroundStyle(Theme.ink.opacity(0.45))
                        .frame(maxWidth: .infinity, alignment: .center).padding(.top, 14)
                }
                ForEach(mt.suggestions) { s in suggestion(s) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Warnings ("no sound from the mic") float over the bottom of the answers; tap to dismiss.
    @ViewBuilder private var notice: some View {
        if mt.needsScreenPermission {
            Button("Allow Screen Recording to hear them") { mt.openScreenRecordingSettings() }
                .buttonStyle(PillButtonStyle(tint: Theme.accent)).padding(.bottom, 4)
        } else if !mt.status.isEmpty {
            Button { mt.status = "" } label: {
                Text(mt.status).font(.system(size: 11)).foregroundStyle(Theme.orange).lineLimit(2)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(sheetFill))
            }
            .buttonStyle(.plain).padding(.bottom, 4).help("Dismiss")
        }
    }

    private var askBar: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Context (CV, job, my words)…") { toggleSheet(.context) }
                Button("Summary") { mt.summarize() }.disabled(mt.lines.isEmpty)
                Button("Clear the screen") { mt.clear() }.disabled(mt.active || (mt.lines.isEmpty && mt.suggestions.isEmpty))
            } label: { Image(systemName: "plus").font(.system(size: 13, weight: .semibold)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.leading, 4)
            TextField("Ask about the meeting…", text: $mt.question)
                .textFieldStyle(.plain).font(.system(size: 14))
                .onSubmit { mt.ask() }
            if mt.busy { ProgressView().controlSize(.mini) }
            Button("Samjhao") { mt.ask() }.buttonStyle(PillButtonStyle(tint: Theme.accent)).fixedSize()
                .disabled(mt.lines.isEmpty).help("Explain what was just said, or answer what you typed (⌃⌥E)")
        }
        .padding(.horizontal, 6).frame(height: 32)
        .background(Capsule().fill(Theme.control.opacity(0.7)))
    }

    // MARK: Floating cards

    private var sheetFill: Color { Look.shared.light ? Color(white: 0.97) : Color(white: 0.13) }

    @ViewBuilder private func sheetCard(_ s: Sheet) -> some View {
        Group {
            switch s {
            case .saved:
                VStack(alignment: .leading, spacing: 6) {
                    sheetTitle("Saved meetings")
                    sessionList
                }
                .frame(width: 340)
            case .settings:
                VStack(alignment: .leading, spacing: 6) {
                    sheetTitle("Meeting")
                    ScrollView { settingsRows }   // 7 rows are taller than the answers area at 680×340
                }
                .frame(width: 340)
            case .context:
                VStack(alignment: .leading, spacing: 6) {
                    sheetTitle("Context: answers use it as facts")
                    contextBox
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(sheetFill)
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.control, lineWidth: 0.5))
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
    }

    private func sheetTitle(_ t: String) -> some View {
        HStack {
            Text(t.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink.opacity(0.5))
            Spacer()
            Button { withAnimation(.easeOut(duration: 0.15)) { commit(); sheet = nil } } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20)
            }
            .buttonStyle(GlyphButtonStyle(radius: 10))
        }
    }

    /// The grouped-list look from Settings: label left, control right, a hairline between rows.
    private var settingsRows: some View {
        VStack(spacing: 0) {
            row("Mode") { modeMenu }
            if store.config.meetingRole != "interview" {
                Divider()
                row("Delivery coach") {
                    Toggle("", isOn: $store.config.deliveryCoach).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        .disabled(mt.active)
                        .help("After each answer: pauses, waiting for a card, words per minute, uh/um, and where your eyes were. Camera analysed on this Mac, nothing recorded. Turn on before Start.")
                }
            }
            Divider()
            row("Language") { languageMenu.disabled(mt.active) }
            Divider()
            row("AI") { aiMenu }
            Divider()
            row("Model") { modelMenu }
            Divider()
            if store.config.meetingRole != "interview" {
                row("CV") { cvMenu }
                Divider()
            }
            row("Start with calls") {
                Toggle("", isOn: $store.config.meetingAuto).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help("Start and stop with Zoom, Meet, Teams… calls")
            }
            Divider()
            row("Context") {
                Button { toggleSheet(.context) } label: {
                    let filled = fields.filter { !store.config[keyPath: $0.key].isEmpty }.map(\.label)
                    Text(filled.isEmpty ? "Add…" : "✓ " + filled.joined(separator: " · ")).font(.system(size: 11)).lineLimit(1)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
    }

    /// Which model writes the answers. Claude: measured on real interview questions (18 Nov),
    /// Sonnet was quickest (first words ~2 s) and accurate; Opus is fuller but slower; Haiku slipped on facts.
    private var modelMenu: some View {
        let id = store.config.meetingAI
        let cur = (store.config.aiModels[id] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return Menu {
            if id == "claude" {
                ForEach([("", "Sonnet: fast, accurate (best)"), ("opus", "Opus: fullest, slower"), ("haiku", "Haiku: short, can slip on facts")], id: \.0) { m in
                    Button { store.config.aiModels["claude"] = m.0 } label: {
                        if m.0 == (cur == "sonnet" ? "" : cur) { Label(m.1, systemImage: "checkmark") } else { Text(m.1) }
                    }
                }
            } else {
                Button("Change in Settings…") { NotchModel.shared.setTab(.settings) }
            }
        } label: {
            Text(id == "claude" ? (cur.isEmpty || cur == "sonnet" ? "Sonnet" : cur.capitalized) : (cur.isEmpty ? "default" : cur))
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    /// Which of my CVs the answers follow: picked from the call (company in the tracker, role words), or by hand.
    private var cvMenu: some View {
        let cvs = TrackerService.shared.cvs, cur = mt.callCV, choice = store.config.cvChoice
        return Menu {
            if !cvs.isEmpty {
                Button { store.config.cvChoice = 0 } label: {
                    let t = "Auto: from the call" + (choice == 0 ? (cur.map { " (now CV\($0.n), \($0.why))" } ?? "") : "")
                    if choice == 0 { Label(t, systemImage: "checkmark") } else { Text(t) }
                }
                ForEach(Array(cvs.enumerated()), id: \.offset) { i, cv in
                    Button { store.config.cvChoice = i + 1 } label: {
                        if choice == i + 1 { Label(cv.name, systemImage: "checkmark") } else { Text(cv.name) }
                    }
                }
                Divider()
            }
            Button("Choose CV files…") { TrackerService.shared.chooseCVs() }
        } label: {
            Text(cur.map { "CV\($0.n)" + (choice == 0 ? " · auto" : "") } ?? "Use the CV box").font(.system(size: 11))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Your CV versions (CV1 research, CV2 research + AI, CV3 AI builder…). Auto picks by the company in your tracker, then by the role words in the Job box, calendar and what they say.")
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            control()
        }
        .padding(.horizontal, 10).frame(height: 27)
    }

    private var languageMenu: some View {
        Menu {
            ForEach(MeetingService.languages, id: \.id) { l in
                Button { store.config.meetingLocale = l.id } label: {
                    if l.id == store.config.meetingLocale { Label(l.name, systemImage: "checkmark") } else { Text(l.name) }
                }
            }
        } label: {
            Text(["en-IN": "Hinglish", "hi-IN": "Hindi", "en-US": "English US", "en-GB": "English UK"][store.config.meetingLocale] ?? store.config.meetingLocale)
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    /// Rejoined within 30 min: this meeting carries on the last one. One tap starts empty instead.
    private func resumeBanner(_ from: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.forward.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.green)
            Text("Continuing from \(from.formatted(date: .omitted, time: .shortened))").font(.system(size: 11))
            Spacer()
            Button("New meeting") { mt.startFresh() }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent).help("Forget the earlier part (it's already saved) and start empty")
        }
        .padding(.horizontal, 8).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.green.opacity(0.15)))
    }

    /// Three boxes: CV, job/agenda, and your own words. Answers use them as facts.
    private var contextBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                ForEach(fields.indices, id: \.self) { i in
                    let filled = !store.config[keyPath: fields[i].key].isEmpty
                    Button { select(i) } label: {
                        HStack(spacing: 3) {
                            Circle().fill(filled ? Theme.green : Theme.ink.opacity(0.2)).frame(width: 5, height: 5)
                            Text(fields[i].label).font(.system(size: 11, weight: field == i ? .semibold : .regular)).lineLimit(1)
                        }
                        .padding(.horizontal, 7).frame(height: 20)
                        .foregroundStyle(field == i ? Theme.ink : Theme.ink.opacity(0.5))
                        .background(Capsule().fill(field == i ? Theme.control : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft).font(.system(size: 13)).scrollContentBackground(.hidden)
                if draft.isEmpty {
                    Text(fields[field].hint).font(.system(size: 13)).foregroundStyle(Theme.ink.opacity(0.3))
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
                if !draft.isEmpty { Text("\(draft.count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.ink.opacity(0.35)) }
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
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

    /// Past meetings: keep the useful ones, the rest delete themselves 24 h after saving.
    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 2) { ForEach(mt.sessions) { sessionRow($0) } }
        }
        .frame(maxHeight: 170)
    }

    private func sessionRow(_ s: MeetSession) -> some View {
        HStack(spacing: 6) {
            Button { NSWorkspace.shared.open(s.url) } label: {
                Text(s.name.replacingOccurrences(of: "Meeting ", with: "")).font(Theme.caption).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain).help("Open")
            Text(s.kept ? "Kept" : left(s)).font(.system(size: 10).monospacedDigit())
                .foregroundStyle(s.kept ? Theme.green : Theme.ink.opacity(0.45))
            Button { mt.setKept(s, !s.kept) } label: {
                Image(systemName: s.kept ? "bookmark.fill" : "bookmark").font(.system(size: 11)).frame(width: 22, height: 20)
            }
            .buttonStyle(GlyphButtonStyle(radius: 6)).help(s.kept ? "Stop keeping (deletes in 24 h)" : "Keep forever")
            // Kept meetings are only removed by you, on purpose: first tap arms, second deletes.
            let armed = confirmDelete == s.url
            Button {
                if !s.kept || armed { mt.delete(s); confirmDelete = nil; return }
                confirmDelete = s.url
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if confirmDelete == s.url { confirmDelete = nil } }
            } label: {
                Image(systemName: armed ? "trash.fill" : "trash").font(.system(size: 11))
                    .foregroundStyle(armed ? Theme.red : Theme.ink).frame(width: 22, height: 20)
            }
            .buttonStyle(GlyphButtonStyle(radius: 6))
            .help(s.kept ? (armed ? "Tap again to delete this kept meeting for good" : "Delete this kept meeting (asks again)") : "Delete now")
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
            Text(name).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
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
                            "gemini": "Gemini", "ollama": "Ollama", "custom": "Custom"][id] ?? id)).font(.system(size: 11))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Use your own AI: Claude Code, Codex (ChatGPT plan), Gemini, Ollama or an API key")
    }

    /// "Points: a · b · c" on top in big accent type (glance, then talk); the full answer below, quieter.
    @ViewBuilder private func answerText(_ t: String) -> some View {
        let parts = t.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        if let first = parts.first, first.hasPrefix("Points:") {
            VStack(alignment: .leading, spacing: 5) {
                Text(first.dropFirst("Points:".count).trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                if parts.count > 1 {
                    Text(ClaudeView.markdown(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)))
                        .font(.system(size: 15)).foregroundStyle(Theme.ink.opacity(0.75)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text(ClaudeView.markdown(t)).font(.system(size: 15)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func suggestion(_ s: Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                let mine = s.title.hasPrefix(MeetingService.minePrefix)
                Image(systemName: mine ? "person.fill.questionmark" : s.auto ? "questionmark.bubble.fill" : "sparkles")
                    .font(.system(size: 10)).foregroundStyle(mine ? Theme.green : s.auto ? Theme.orange : Theme.accent)
                Text(s.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink.opacity(0.6)).lineLimit(2)
            }
            if let f = s.failed {
                Text(f).font(.system(size: 11)).foregroundStyle(Theme.red)
            } else if s.text.isEmpty {
                // Say this while the answer is being written.
                HStack(spacing: 6) {
                    if !s.filler.isEmpty {
                        Text("“\(s.filler)”").font(.system(size: 15, weight: .medium)).italic().foregroundStyle(Theme.ink)
                    }
                    ProgressView().controlSize(.mini)
                }
            } else {
                answerText(s.text)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(s.auto ? Theme.orange.opacity(0.12) : Theme.control.opacity(0.5)))
    }
}
