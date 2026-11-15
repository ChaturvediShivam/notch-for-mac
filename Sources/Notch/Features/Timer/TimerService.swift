import AppKit

@MainActor
final class TimerService: ObservableObject {
    static let shared = TimerService()

    @Published private(set) var end: Date?              // countdown running
    @Published private(set) var pausedRemaining: Int?   // countdown paused
    @Published private(set) var total = 0
    @Published private(set) var stopwatchStart: Date?
    @Published private(set) var stopwatchAccum: TimeInterval = 0
    @Published private(set) var laps: [TimeInterval] = []
    private var fireWork: DispatchWorkItem?

    var running: Bool { end != nil }
    var remaining: Int {
        if let end { return max(0, Int(end.timeIntervalSinceNow.rounded(.up))) }
        return pausedRemaining ?? 0
    }

    func start(seconds: Int) {
        total = seconds
        pausedRemaining = nil
        schedule(seconds)
    }

    private func schedule(_ seconds: Int) {
        end = Date().addingTimeInterval(TimeInterval(seconds))
        fireWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.finished() }
        fireWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: w)
    }

    func pause() {
        guard running else { return }
        pausedRemaining = remaining; end = nil; fireWork?.cancel()
    }

    func resume() {
        guard let r = pausedRemaining else { return }
        pausedRemaining = nil; schedule(r)
    }

    func cancel() { end = nil; pausedRemaining = nil; fireWork?.cancel() }

    func add(_ s: Int) {
        if let e = end { schedule(Int(e.timeIntervalSinceNow) + s); total += s }
        else if let p = pausedRemaining { pausedRemaining = p + s; total += s }
    }

    private func finished() {
        end = nil
        NSSound(named: "Glass")?.play()
        AlertsService.shared.add(title: "Timer done", body: Self.format(total), source: "Timer")
        NotchModel.shared.show(.timer)
    }

    // Stopwatch
    var stopwatchRunning: Bool { stopwatchStart != nil }
    func stopwatchElapsed(_ now: Date = Date()) -> TimeInterval { stopwatchAccum + (stopwatchStart.map { now.timeIntervalSince($0) } ?? 0) }
    func toggleStopwatch() {
        if let s = stopwatchStart { stopwatchAccum += Date().timeIntervalSince(s); stopwatchStart = nil }
        else { stopwatchStart = Date() }
    }
    func lap() { laps.insert(stopwatchElapsed(), at: 0) }
    func resetStopwatch() { stopwatchStart = nil; stopwatchAccum = 0; laps = [] }

    static func format(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
