import SwiftUI

struct AppsView: View {
    @ObservedObject private var apps = AppsService.shared
    @ObservedObject private var store = Store.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Card(title: "Pinned") {
                if apps.pinned.isEmpty {
                    Hint("Right-click a running app to pin it, or search with ⌃⌥Space.")
                } else {
                    grid(apps.pinned.map { ($0.name, $0.url, nil) })
                }
            }
            Card(title: "Running") {
                grid(apps.running.compactMap { a in a.bundleURL.map { (a.localizedName ?? "", $0, a) } })
            }
        }
    }

    private func grid(_ items: [(String, URL, NSRunningApplication?)]) -> some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(58), spacing: 4), count: 5), spacing: 6) {
                ForEach(items, id: \.1) { name, url, running in
                    Button {
                        if let running { running.activate() } else { apps.open(url) }
                    } label: {
                        VStack(spacing: 3) {
                            Image(nsImage: apps.icon(url)).resizable().frame(width: 34, height: 34)
                            Text(name).font(.system(size: 10)).lineLimit(1).foregroundStyle(Theme.ink.opacity(0.8))
                        }
                        .frame(width: 58, height: 56)
                    }
                    .buttonStyle(GlyphButtonStyle(radius: 10))
                    .contextMenu {
                        Button(store.config.pinnedApps.contains(url.path) ? "Unpin" : "Pin") { apps.togglePin(url) }
                        if let running { Button("Quit") { running.terminate() } }
                    }
                }
            }
        }
    }
}

/// Card with a small heading, used across tabs.
struct Card<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder let content: Content

    init(title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.trailing = trailing; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink.opacity(0.55))
                Spacer()
                trailing
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }
}

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Theme.caption).foregroundStyle(Theme.ink.opacity(0.45))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .multilineTextAlignment(.center)
    }
}
