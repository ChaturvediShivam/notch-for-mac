import SwiftUI

struct PaletteView: View {
    @ObservedObject private var p = PaletteService.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.ink.opacity(0.6))
                TextField("Search apps, files, maths, the web…", text: $p.query)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { p.activate() }
                Text("esc").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink.opacity(0.4))
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.control))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(p.results.enumerated()), id: \.element.id) { i, item in
                            row(item, selected: i == p.selection)
                                .id(i)
                                .onTapGesture { p.activate(i) }
                        }
                    }
                }
                .onChange(of: p.selection) { s in withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(s) } }
            }
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon = item.icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: item.symbol).font(.system(size: 13, weight: .medium)) }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(Theme.body).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 11)).foregroundStyle(Theme.ink.opacity(0.45)).lineLimit(1)
                }
            }
            Spacer()
            if selected { Image(systemName: "return").font(.system(size: 11)).foregroundStyle(Theme.ink.opacity(0.5)) }
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.control : .clear))
        .contentShape(Rectangle())
    }
}
