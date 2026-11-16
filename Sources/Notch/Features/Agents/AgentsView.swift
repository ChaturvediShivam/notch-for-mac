import SwiftUI

struct AgentsView: View {
    @ObservedObject private var svc = AgentsService.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Card(title: svc.pending.isEmpty ? "Approvals" : "Waiting for approval (\(svc.pending.count))") {
                if let a = svc.pending.first {
                    approval(a)
                } else if !svc.installed {
                    VStack(spacing: 10) {
                        Hint("Approve Claude Code's Bash and file edits from the notch.\nAdds hooks to ~/.claude/settings.json (backed up first).")
                        Button("Install Claude Code hooks") { svc.installHooks() }.buttonStyle(PillButtonStyle(tint: Theme.accent))
                        if !svc.installMessage.isEmpty { Text(svc.installMessage).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    history
                }
            }
            .frame(width: 400)

            Card(title: "Sessions", trailing: AnyView(Toggle("Ask in Notch", isOn: $svc.askInNotch)
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10)))) {
                VStack(alignment: .leading, spacing: 6) {
                    if svc.sessions.isEmpty {
                        Hint("Claude Code sessions show up here once a hook fires.")
                    } else {
                        ScrollView {
                            ForEach(svc.sessions.values.sorted { $0.last > $1.last }) { s in
                                HStack {
                                    Circle().fill(s.status == "Working" ? Theme.green : s.status == "Finished" ? Color.gray : Theme.orange)
                                        .frame(width: 7, height: 7)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text((s.cwd as NSString).lastPathComponent).font(Theme.caption).lineLimit(1)
                                        Text(s.status).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                    if svc.installed {
                        Button("Remove hooks") { svc.uninstallHooks() }.buttonStyle(PillButtonStyle())
                    }
                }
            }
        }
    }

    private func approval(_ a: Approval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: a.tool == "Bash" ? "terminal.fill" : "pencil").foregroundStyle(Theme.orange)
                Text(a.tool).font(Theme.title)
                Text((a.cwd as NSString).lastPathComponent).font(Theme.caption).foregroundStyle(.white.opacity(0.5))
                Spacer()
            }
            ScrollView {
                Text(a.summary).font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.4)))
            HStack {
                Button("Deny") { a.resolve("deny") }.buttonStyle(PillButtonStyle(tint: Theme.red))
                Button("Ask in terminal") { a.resolve(nil) }.buttonStyle(PillButtonStyle())
                Spacer()
                Button("Allow") { a.resolve("allow") }.buttonStyle(PillButtonStyle(tint: Theme.green))
            }
        }
    }

    private var history: some View {
        Group {
            if svc.history.isEmpty {
                Hint("Hooks installed. Nothing to approve right now.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(svc.history.enumerated()), id: \.offset) { _, h in
                            HStack {
                                Text(h.2).font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(h.2 == "allow" ? Theme.green : h.2 == "deny" ? Theme.red : .gray)
                                    .frame(width: 44, alignment: .leading)
                                Text(h.1).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }
}
