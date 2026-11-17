import SwiftUI

struct AlertsView: View {
    @ObservedObject private var svc = AlertsService.shared

    var body: some View {
        Card(title: "Alerts", trailing: AnyView(HStack(spacing: 6) {
            Button("Copy curl example") {
                let port = Store.shared.config.apiPort
                let cmd = """
                curl -s -X POST http://127.0.0.1:\(port)/notify -H "X-Notch-Token: $(cat ~/.notch/token)" \
                -H 'Content-Type: application/json' -d '{"title":"Build done","body":"All tests passed"}'
                """
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string)
            }
            Button("Clear") { svc.clear() }.disabled(svc.alerts.isEmpty)
        }.buttonStyle(PillButtonStyle()))) {
            if svc.alerts.isEmpty {
                Hint("Nothing yet. Scripts can POST to 127.0.0.1:\(Store.shared.config.apiPort)/notify,\nand Claude Code hooks land here too.")
            } else {
                ScrollView {
                    // Lazy: 100 alerts were all built at once on the first visit (~140 ms stall).
                    LazyVStack(spacing: 6) {
                        ForEach(svc.alerts) { a in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: a.source.contains("Claude") ? "sparkles" : "bell.fill")
                                    .foregroundStyle(Theme.orange).frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(a.title).font(Theme.title).lineLimit(1)
                                        Spacer()
                                        Text(a.date, style: .relative).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                                    }
                                    if !a.body.isEmpty {
                                        Text(a.body).font(Theme.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(3)
                                            .textSelection(.enabled)
                                    }
                                    Text(a.source).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                                }
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                            .contextMenu { Button("Remove") { svc.remove(a) } }
                        }
                    }
                }
            }
        }
    }
}

/// Small rounded text button.
struct PillButtonStyle: ButtonStyle {
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, tint: tint)
    }
    private struct PillBody: View {
        let configuration: ButtonStyle.Configuration
        let tint: Color?
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.map { $0.opacity(configuration.isPressed ? 0.7 : (hover ? 0.9 : 0.8)) }
                          ?? (configuration.isPressed ? Theme.pressed : hover ? Theme.hover : Theme.control)))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onHover { hover = $0 }
        }
    }
}
