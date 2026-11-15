import SwiftUI

/// What the closed pill shows beside the camera, highest priority first.
enum Activity {
    case approval(Int)
    case hud(HUD)
    case voice(String, listening: Bool)
    case meeting(String)
    case alert(NotchAlert)
    case timer
    case media(playing: Bool)

    @MainActor
    static func current() -> Activity? {
        let m = NotchModel.shared!
        if !AgentsService.shared.pending.isEmpty { return .approval(AgentsService.shared.pending.count) }
        if let h = m.hud { return .hud(h) }
        let mt = MeetingService.shared
        if mt.active { return .meeting(mt.lines.last.map { "\($0.speaker): \($0.text)" } ?? "") }
        let v = VoiceService.shared
        if v.mode != .idle { return .voice(v.tail, listening: v.mode == .listening) }
        if let a = AlertsService.shared.flash { return .alert(a) }
        if TimerService.shared.running { return .timer }
        if let n = MediaService.shared.now, n.playing, !n.title.isEmpty { return .media(playing: true) }
        return nil
    }

    /// Width added to the closed pill (both sides together).
    var side: CGFloat {
        switch self {
        case .hud: 90
        case .voice, .alert, .meeting: 120
        case .approval: 70
        case .timer, .media: 44
        }
    }

    @MainActor static var extra: CGFloat { (current()?.side ?? 0) * 2 }
}

extension Optional where Wrapped == Activity {
    var extraWidth: CGFloat { (self?.side ?? 0) * 2 }
}

struct LiveActivityView: View {
    let activity: Activity
    let notchWidth: CGFloat
    let height: CGFloat
    @ObservedObject private var media = MediaService.shared
    @ObservedObject private var timer = TimerService.shared

    var body: some View {
        HStack(spacing: 0) {
            leading.frame(width: activity.side, alignment: .leading).padding(.leading, 10)
            Spacer(minLength: notchWidth)
            trailing.frame(width: activity.side, alignment: .trailing).padding(.trailing, 10)
        }
        .frame(height: height)
        .foregroundStyle(.white)
    }

    @ViewBuilder private var leading: some View {
        switch activity {
        case .approval: Image(systemName: "terminal.fill").foregroundStyle(Theme.orange)
        case .hud(let h): Image(systemName: h.symbol).font(.system(size: 12, weight: .semibold))
        case .voice(_, let listening):
            Image(systemName: listening ? "captions.bubble.fill" : "mic.fill").foregroundStyle(Theme.red)
        case .alert(let a): Text(a.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        case .meeting:
            HStack(spacing: 5) {
                Circle().fill(Theme.red).frame(width: 7, height: 7)
                Text("Meeting").font(.system(size: 11, weight: .semibold))
            }
        case .timer: Image(systemName: "timer").foregroundStyle(Theme.orange)
        case .media: Artwork(image: media.artwork, size: max(16, height - 10))
        }
    }

    @ViewBuilder private var trailing: some View {
        switch activity {
        case .approval(let n): Text("\(n) waiting").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.orange)
        case .hud(let h):
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.control)
                    Capsule().fill(.white).frame(width: g.size.width * h.level)
                }
            }
            .frame(width: 70, height: 5)
        case .meeting(let t): Text(t.isEmpty ? "Listening…" : String(t.suffix(60))).font(.system(size: 10)).lineLimit(1).truncationMode(.head)
        case .voice(let t, _): Text(t.isEmpty ? "Listening…" : t).font(.system(size: 10)).lineLimit(1).truncationMode(.head)
        case .alert(let a): Text(a.body).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
        case .timer:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(TimerService.format(timer.remaining)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.orange)
            }
        case .media: Equalizer()
        }
    }
}

/// Three bouncing bars while music plays.
struct Equalizer: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(Theme.green)
                        .frame(width: 2.5, height: 4 + 8 * abs(sin(t * (2.6 + Double(i) * 0.9) + Double(i))))
                }
            }
            .frame(height: 14)
        }
    }
}
