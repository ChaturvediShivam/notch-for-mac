import SwiftUI

struct StatsView: View {
    @ObservedObject private var s = StatsService.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 8) {
                meter("CPU", s.cpu, String(format: "%.0f%%", s.cpu * 100), Theme.accent)
                meter("Memory", s.memTotal > 0 ? s.memUsed / s.memTotal : 0,
                      "\(StatsService.bytes(s.memUsed)) of \(StatsService.bytes(s.memTotal))", Theme.green)
                meter("Disk", s.diskTotal > 0 ? 1 - s.diskFree / s.diskTotal : 0,
                      "\(StatsService.bytes(s.diskFree)) free", Theme.orange)
                HStack {
                    if let b = s.battery {
                        Label("\(b.level)%\(b.charging ? " ⚡︎" : "")", systemImage: b.level > 20 ? "battery.75" : "battery.25")
                    }
                    Spacer()
                    Label("↓ \(StatsService.bytes(s.netIn))/s  ↑ \(StatsService.bytes(s.netOut))/s", systemImage: "network")
                }
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.ink.opacity(0.75))
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
            }
            .frame(width: 330)

            Card(title: "Top processes · up \(Self.uptime(s.uptime))") {
                VStack(spacing: 8) {
                    spark.frame(height: 40)
                    ForEach(Array(s.top.enumerated()), id: \.offset) { _, p in
                        HStack {
                            Text(p.0).font(Theme.caption).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.1f%%", p.1)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.ink.opacity(0.6))
                        }
                    }
                }
            }
        }
        .onAppear { s.start() }
        .onDisappear { s.stop() }
    }

    private func meter(_ name: String, _ v: Double, _ detail: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(name).font(Theme.title)
                Spacer()
                Text(detail).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.ink.opacity(0.6))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.control)
                    Capsule().fill(tint).frame(width: max(6, g.size.width * min(max(v, 0), 1)))
                }
            }
            .frame(height: 6)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .animation(.easeOut(duration: 0.4), value: v)
    }

    private var spark: some View {
        GeometryReader { g in
            Path { p in
                let pts = s.cpuHistory
                guard pts.count > 1 else { return }
                let dx = g.size.width / CGFloat(39)
                let x0 = g.size.width - dx * CGFloat(pts.count - 1)
                for (i, v) in pts.enumerated() {
                    let pt = CGPoint(x: x0 + dx * CGFloat(i), y: g.size.height * (1 - CGFloat(v)))
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
            }
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }

    static func uptime(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        return h >= 24 ? "\(h / 24)d \(h % 24)h" : "\(h)h \(Int(t) / 60 % 60)m"
    }
}
