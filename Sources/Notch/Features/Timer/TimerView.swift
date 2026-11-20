import SwiftUI

struct TimerView: View {
    @ObservedObject private var t = TimerService.shared

    var body: some View {
        HStack(spacing: 10) {
            Card(title: "Timer") {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    VStack(spacing: 12) {
                        ZStack {
                            Circle().stroke(Theme.control, lineWidth: 6)
                            Circle().trim(from: 0, to: t.total > 0 ? CGFloat(t.remaining) / CGFloat(t.total) : 0)
                                .stroke(Theme.orange, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 0.5), value: t.remaining)
                            Text(TimerService.format(t.remaining)).font(.system(size: 24, weight: .semibold).monospacedDigit())
                        }
                        .frame(width: 110, height: 110)
                        if t.running || t.pausedRemaining != nil {
                            HStack {
                                Button("+1 min") { t.add(60) }.buttonStyle(PillButtonStyle())
                                Button(t.running ? "Pause" : "Resume") { t.running ? t.pause() : t.resume() }
                                    .buttonStyle(PillButtonStyle(tint: Theme.orange))
                                Button("Cancel") { t.cancel() }.buttonStyle(PillButtonStyle())
                            }
                        } else {
                            HStack(spacing: 6) {
                                ForEach([1, 5, 10, 15, 25, 45], id: \.self) { m in
                                    Button("\(m)m") { t.start(seconds: m * 60) }.buttonStyle(PillButtonStyle())
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Card(title: "Stopwatch") {
                TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                    VStack(spacing: 10) {
                        Text(Self.sw(t.stopwatchElapsed(ctx.date))).font(.system(size: 30, weight: .semibold).monospacedDigit())
                        HStack {
                            Button(t.stopwatchRunning ? "Lap" : "Reset") { t.stopwatchRunning ? t.lap() : t.resetStopwatch() }
                                .buttonStyle(PillButtonStyle())
                            Button(t.stopwatchRunning ? "Stop" : "Start") { t.toggleStopwatch() }
                                .buttonStyle(PillButtonStyle(tint: t.stopwatchRunning ? Theme.red : Theme.green))
                        }
                        ScrollView {
                            ForEach(Array(t.laps.enumerated()), id: \.offset) { i, l in
                                HStack { Text("Lap \(t.laps.count - i)"); Spacer(); Text(Self.sw(l)) }
                                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.ink.opacity(0.7))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    static func sw(_ t: TimeInterval) -> String {
        let cs = Int(t * 100)
        return String(format: "%02d:%02d.%02d", cs / 6000, cs / 100 % 60, cs % 100)
    }
}
