import SwiftUI

struct ClipboardView: View {
    @ObservedObject private var svc = ClipboardService.shared
    @State private var filter = ""

    var body: some View {
        Card(title: "Clipboard history", trailing: AnyView(HStack(spacing: 6) {
            Toggle("Pause", isOn: $svc.paused).toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
            Button("Clear") { svc.clear() }.buttonStyle(PillButtonStyle())
        })) {
            VStack(spacing: 6) {
                TextField("Filter", text: $filter).textFieldStyle(.plain).font(Theme.caption)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.control))
                let shown = svc.items.filter { filter.isEmpty || $0.text.localizedCaseInsensitiveContains(filter) }
                    .sorted { $0.pinned && !$1.pinned }
                if shown.isEmpty {
                    Hint("Copy some text and it shows up here. Click to copy, double-click to paste.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(shown) { i in row(i) }
                        }
                    }
                }
            }
        }
    }

    private func row(_ i: ClipItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: i.pinned ? "pin.fill" : "doc.on.doc").font(.system(size: 10))
                .foregroundStyle(i.pinned ? Theme.orange : .white.opacity(0.4)).frame(width: 14)
            Text(i.text.replacingOccurrences(of: "\n", with: " ⏎ ")).font(Theme.caption).lineLimit(1)
            Spacer()
            Text(i.date, style: .relative).font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(HoverFill(radius: 7))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { svc.paste(i) }
        .onTapGesture { svc.copy(i) }
        .contextMenu {
            Button("Copy") { svc.copy(i) }
            Button("Paste") { svc.paste(i) }
            Button(i.pinned ? "Unpin" : "Pin") { svc.togglePin(i) }
            Button("Delete") { svc.remove(i) }
        }
    }
}

/// Rounded fill that lights up on hover (rule 7).
struct HoverFill: View {
    var radius: CGFloat = 8
    @State private var hover = false
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(hover ? Theme.card : .clear)
            .onHover { hover = $0 }
    }
}
