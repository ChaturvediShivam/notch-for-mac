import SwiftUI

struct UsageView: View {
    @ObservedObject private var svc = UsageService.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 10) {
                stat("Today", UsageService.short(svc.today), "\(svc.messagesToday) responses")
                stat("This 5-hour window", UsageService.short(svc.windowTokens),
                     svc.windowStart.map { "resets " + ($0.addingTimeInterval(5 * 3600)).formatted(date: .omitted, time: .shortened) } ?? "no active window")
            }
            .frame(width: 180)

            Card(title: "Last 7 days · Claude Code tokens", trailing: AnyView(
                Button { svc.refresh() } label: { Image(systemName: svc.loading ? "hourglass" : "arrow.clockwise") }
                    .buttonStyle(GlyphButtonStyle()))) {
                VStack(spacing: 10) {
                    chart.frame(height: 90)
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(svc.models) { m in
                                HStack {
                                    Text(m.model).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                    Spacer()
                                    Text("in \(UsageService.short(m.input + m.cacheRead + m.cacheWrite)) · out \(UsageService.short(m.output))")
                                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { svc.refresh() }
    }

    private func stat(_ title: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            Text(value).font(.system(size: 28, weight: .semibold).monospacedDigit())
            Text(sub).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }

    private var chart: some View {
        let maxV = max(svc.days.map(\.tokens).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(svc.days) { d in
                VStack(spacing: 3) {
                    Text(d.tokens > 0 ? UsageService.short(d.tokens) : "").font(.system(size: 8)).foregroundStyle(.white.opacity(0.5))
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Calendar.current.isDateInToday(d.date) ? Theme.orange : Theme.control)
                        .frame(height: max(3, CGFloat(d.tokens) / CGFloat(maxV) * 60))
                    Text(d.date, format: .dateTime.weekday(.narrow)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
