import SwiftUI

enum NotchTab: Int, CaseIterable, Identifiable {
    case home, meeting, media, clipboard, timer, ai, alerts, audio, shelf, notes,
         today, markets, scores, stats, tools, mirror, agents, claude, apps, settings

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .meeting: "Meeting"
        case .media: "Media"
        case .clipboard: "Clipboard"
        case .timer: "Timer"
        case .ai: "AI usage"
        case .alerts: "Alerts"
        case .audio: "Audio"
        case .shelf: "Shelf"
        case .notes: "Notes"
        case .today: "Today"
        case .markets: "Markets"
        case .scores: "Scores"
        case .stats: "Stats"
        case .tools: "Tools"
        case .mirror: "Mirror"
        case .agents: "Agents"
        case .claude: "Claude"
        case .apps: "Apps"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .meeting: "person.2.wave.2.fill"
        case .media: "music.note"
        case .clipboard: "doc.on.clipboard"
        case .timer: "timer"
        case .ai: "chart.bar.fill"
        case .alerts: "bell.fill"
        case .audio: "speaker.wave.2.fill"
        case .shelf: "tray.fill"
        case .notes: "note.text"
        case .today: "sun.max.fill"
        case .markets: "chart.line.uptrend.xyaxis"
        case .scores: "sportscourt.fill"
        case .stats: "cpu"
        case .tools: "wrench.and.screwdriver.fill"
        case .mirror: "camera.fill"
        case .agents: "terminal.fill"
        case .claude: "sparkles"
        case .apps: "square.grid.2x2.fill"
        case .settings: "gearshape.fill"
        }
    }
}

/// Brief overlay in the closed pill (volume, brightness).
struct HUD: Equatable {
    var symbol: String
    var level: Double
}

@MainActor
final class NotchModel: ObservableObject {
    static var shared: NotchModel!

    @Published var geometry: NotchGeometry
    @Published var isOpen = false
    @Published var hovering = false
    @Published var tab: NotchTab = .home
    /// +1 = new tab slides in from the right, -1 from the left. Always from the real index change.
    @Published var tabDirection = 1
    /// Opened by hotkey or typing: hover-exit doesn't close it; click outside or Esc does.
    @Published var pinned = false
    @Published var palette = false
    @Published var hud: HUD?
    private var hudWork: DispatchWorkItem?

    /// Set by the controller: grab keyboard focus now / panel opened or closed.
    var onFocus: ((Bool) -> Void)?
    var onOpenChange: ((Bool) -> Void)?

    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.80)
    static let hoverSpring = Animation.spring(response: 0.28, dampingFraction: 0.70)

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        Self.shared = self
    }

    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        if !open {
            pinned = false
            palette = false
        }
        onOpenChange?(open)
        withAnimation(Self.spring) { isOpen = open }
    }

    func setHovering(_ h: Bool) {
        guard h != hovering else { return }
        withAnimation(Self.hoverSpring) { hovering = h }
    }

    func setTab(_ new: NotchTab) {
        if palette { palette = false }
        let d = new.rawValue - tab.rawValue
        guard d != 0 else { return }
        tabDirection = d > 0 ? 1 : -1
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { tab = new }
    }

    func step(_ delta: Int) {
        let all = NotchTab.allCases
        let i = min(max(tab.rawValue + delta, 0), all.count - 1)
        setTab(all[i])
    }

    /// Open on a tab and keep it open (hotkeys, palette "Open …", alerts).
    func show(_ t: NotchTab, focus: Bool = false) {
        setTab(t)
        pinned = true
        setOpen(true)
        if focus { onFocus?(true) }
    }

    func toggleOpen() {
        if isOpen { setOpen(false) } else { pinned = true; setOpen(true) }
    }

    func openPalette() {
        if palette { setOpen(false); return }
        PaletteService.shared.reset()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { palette = true }
        pinned = true
        setOpen(true)
        onFocus?(true)
    }

    func closePalette(andNotch: Bool) {
        palette = false
        if andNotch { setOpen(false) }
    }

    func showHUD(_ symbol: String, _ level: Double) {
        hud = HUD(symbol: symbol, level: level)
        hudWork?.cancel()
        let w = DispatchWorkItem { [weak self] in withAnimation(Self.hoverSpring) { self?.hud = nil } }
        hudWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }
}
