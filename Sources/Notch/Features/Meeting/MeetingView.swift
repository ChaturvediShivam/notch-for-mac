import SwiftUI

struct MeetingView: View {
    @ObservedObject private var mt = MeetingService.shared
    @ObservedObject private var store = Store.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            transcriptCard
            assistCard.frame(width: 260)
        }
    }

    // MARK: Left: live transcript

    private var transcriptCard: some View {
        Card(title: mt.active ? "Live transcript" : "Meeting", trailing: AnyView(controls)) {
            if mt.lines.isEmpty {
                VStack(spacing: 6) {
                    Text(mt.active ? "Listening… speak or let the meeting play." :
                         "Start before the call: the other people (Mac's audio) and you (mic) are transcribed live as Them / Me.")
                        .font(Theme.caption).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
                    if !mt.status.isEmpty { Text(mt.status).font(.system(size: 10)).foregroundStyle(Theme.orange).multilineTextAlignment(.center) }
                    if mt.needsScreenPermission {
                        Button("Open Screen Recording settings") { mt.openScreenRecordingSettings() }.buttonStyle(PillButtonStyle(tint: Theme.blue))
                    }
                    if mt.active { meters }
                    Text("Works on speakers or earphones · listens only while Meeting mode is on · ⌃⌥M")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(mt.lines) { l in line(l).id(l.id) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: mt.lines.last?.text) { _ in
                        if let id = mt.lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
        }
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
            if let url = mt.savedTo, !mt.active {
                Button("Open file") { NSWorkspace.shared.open(url) }.buttonStyle(PillButtonStyle())
            }
            if mt.active && !mt.lines.isEmpty { meters }
            if let s = mt.startedAt, mt.active {
                Text(s, style: .timer).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.red)
            }
            Button(mt.active ? "Stop" : "Start") { mt.toggle() }
                .buttonStyle(PillButtonStyle(tint: mt.active ? Theme.red : Theme.green))
                .fixedSize()
        }
    }

    /// Two tiny meters: is each side actually reaching us?
    private var meters: some View {
        HStack(spacing: 8) {
            meter("Them", mt.themLevel, Theme.orange)
            meter("Me", mt.meLevel, Theme.blue)
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
            .animation(.linear(duration: 0.2), value: v)
        }
    }

    private func line(_ l: MeetLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(l.speaker).font(.system(size: 10, weight: .bold))
                .foregroundStyle(l.speaker == "Me" ? Theme.blue : Theme.orange)
                .frame(width: 34, alignment: .leading)
            Text(l.text).font(Theme.caption).foregroundStyle(.white.opacity(l.final ? 0.9 : 0.6))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Right: live answers

    private var assistCard: some View {
        Card(title: "Answers", trailing: AnyView(
            Toggle("Auto", isOn: $mt.autoAnswer).toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
                .help("When someone asks a question, suggest a reply automatically (only while Meeting mode is on)"))) {
            VStack(spacing: 6) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if mt.suggestions.isEmpty {
                            Text(mt.autoAnswer
                                 ? "When someone asks you something, a suggested reply appears here by itself. Lost? Press Samjhao (⌃⌥E)."
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
                    Button("Samjhao") { mt.ask() }.buttonStyle(PillButtonStyle(tint: Theme.blue))
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
                Image(systemName: s.auto ? "questionmark.bubble.fill" : "sparkles")
                    .font(.system(size: 9)).foregroundStyle(s.auto ? Theme.orange : Theme.blue)
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
