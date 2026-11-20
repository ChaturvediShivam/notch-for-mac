import SwiftUI

struct ScoresView: View {
    @ObservedObject private var svc = ScoresService.shared

    var body: some View {
        Card(title: "Scores", trailing: AnyView(
            Button { svc.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(GlyphButtonStyle()))) {
            if svc.matches.isEmpty {
                Hint(svc.status.isEmpty ? "Loading…" : svc.status + "\nPick leagues in Settings.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(svc.matches) { m in tile(m) }
                    }
                }
            }
        }
        .onAppear { svc.start() }
        .onDisappear { svc.stop() }
    }

    private func tile(_ m: Match) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(m.league).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink.opacity(0.5))
                Spacer()
                if m.state == "in" { Circle().fill(Theme.red).frame(width: 6, height: 6) }
                Text(m.state == "pre" ? m.date.formatted(date: .omitted, time: .shortened) : m.detail)
                    .font(.system(size: 10)).foregroundStyle(m.state == "in" ? Theme.red : Theme.ink.opacity(0.5)).lineLimit(1)
            }
            team(m.away, m.awayScore, m.awayLogo, win: m.state == "post" && (Int(m.awayScore) ?? 0) > (Int(m.homeScore) ?? 0))
            team(m.home, m.homeScore, m.homeLogo, win: m.state == "post" && (Int(m.homeScore) ?? 0) > (Int(m.awayScore) ?? 0))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
    }

    private func team(_ name: String, _ score: String, _ logo: URL?, win: Bool) -> some View {
        HStack(spacing: 6) {
            AsyncImage(url: logo) { $0.resizable().aspectRatio(contentMode: .fit) } placeholder: { Color.clear }
                .frame(width: 16, height: 16)
            Text(name).font(.system(size: 13, weight: win ? .bold : .medium))
            Spacer()
            Text(score).font(.system(size: 13, weight: .semibold).monospacedDigit())
        }
    }
}
