import SwiftUI

struct MarketsView: View {
    @ObservedObject private var svc = MarketsService.shared

    var body: some View {
        Card(title: "Watchlist", trailing: AnyView(HStack {
            if let u = svc.updated { Text(u, style: .time).font(.system(size: 11)).foregroundStyle(Theme.ink.opacity(0.4)) }
            Button { svc.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(GlyphButtonStyle())
        })) {
            if svc.quotes.isEmpty {
                Hint(svc.status.isEmpty ? "Loading…" : svc.status + "\nEdit the watchlist in Settings.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(svc.quotes) { q in tile(q) }
                    }
                }
            }
        }
        .onAppear { svc.start() }
        .onDisappear { svc.stop() }
    }

    private func tile(_ q: Quote) -> some View {
        let up = q.change >= 0
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(q.symbol).font(Theme.title)
                Text(q.name).font(.system(size: 11)).foregroundStyle(Theme.ink.opacity(0.5)).lineLimit(1)
            }
            .frame(width: 90, alignment: .leading)
            Sparkline(points: q.points, base: q.prevClose, tint: up ? Theme.green : Theme.red).frame(height: 28)
            VStack(alignment: .trailing, spacing: 2) {
                Text(q.price, format: .number.precision(.fractionLength(2))).font(.system(size: 13, weight: .semibold).monospacedDigit())
                Text(String(format: "%@%.2f%%", up ? "+" : "", q.pct))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill((up ? Theme.green : Theme.red).opacity(0.85)))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
    }
}

struct Sparkline: View {
    let points: [Double]
    let base: Double
    let tint: Color

    var body: some View {
        GeometryReader { g in
            let lo = min(points.min() ?? 0, base), hi = max(points.max() ?? 1, base)
            let span = max(hi - lo, 0.0001)
            let y = { (v: Double) in g.size.height * (1 - CGFloat((v - lo) / span)) }
            ZStack {
                Path { p in p.move(to: CGPoint(x: 0, y: y(base))); p.addLine(to: CGPoint(x: g.size.width, y: y(base))) }
                    .stroke(Theme.ink.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                Path { p in
                    guard points.count > 1 else { return }
                    let dx = g.size.width / CGFloat(points.count - 1)
                    for (i, v) in points.enumerated() {
                        let pt = CGPoint(x: dx * CGFloat(i), y: y(v))
                        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                    }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }
}
