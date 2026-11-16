import SwiftUI

struct NotchView: View {
    @EnvironmentObject private var model: NotchModel
    // Observed so the closed pill re-evaluates its live activity.
    @ObservedObject private var media = MediaService.shared
    @ObservedObject private var timer = TimerService.shared
    @ObservedObject private var alerts = AlertsService.shared
    @ObservedObject private var agents = AgentsService.shared
    @ObservedObject private var voice = VoiceService.shared
    @ObservedObject private var meeting = MeetingService.shared
    @ObservedObject private var store = Store.shared

    var body: some View {
        let g = model.geometry
        let open = model.isOpen
        let activity = open ? nil : Activity.current()
        let size = currentSize(g, activity)
        let topR: CGFloat = open ? 12 : 6
        let botR: CGFloat = open ? 24 : (g.hasHardwareNotch ? 10 : size.height / 2)
        let shape = NotchShape(topRadius: topR, bottomRadius: botR)

        ZStack(alignment: .top) {
            NotchBackground(shape: shape, open: open, glass: store.config.glass, opacity: store.config.opacity,
                            skin: Skin.current, glow: store.config.edgeGlow)
            if let activity {
                LiveActivityView(activity: activity, notchWidth: g.closedSize.width, height: g.closedSize.height)
                    .padding(.horizontal, topR)
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            }
            if open {
                OpenPanel(bandHeight: g.closedSize.height,
                          notchWidth: g.hasHardwareNotch ? g.closedSize.width : 0)
                    .padding(.horizontal, topR)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                            .animation(.easeOut(duration: 0.20).delay(0.08)),
                        removal: .opacity.animation(.easeIn(duration: 0.08))))
            }
        }
        .frame(width: size.width + topR * 2, height: size.height)
        .clipShape(shape)
        .contentShape(shape)
        .shadow(color: .black.opacity(open ? 0.5 : 0), radius: 16, y: 8)
        // Hover: a soft glow in the theme colour, like the notch is breathing out.
        .shadow(color: (Skin.current.glow.first ?? .white).opacity(store.config.edgeGlow && model.hovering && !open ? 0.55 : 0), radius: 8)
        .onTapGesture { if !model.isOpen { model.setOpen(true) } }
        .contextMenu {
            Button("Quit Notch") { NSApp.terminate(nil) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func currentSize(_ g: NotchGeometry, _ a: Activity?) -> CGSize {
        if model.isOpen { return g.openSize }
        let w = g.closedSize.width + a.extraWidth
        if model.hovering {
            return CGSize(width: w + 18, height: g.closedSize.height + 4)
        }
        return CGSize(width: w, height: g.closedSize.height)
    }
}

/// The open 680 x 340 panel: header band beside the camera, tab strip, tab content.
struct OpenPanel: View {
    @EnvironmentObject private var model: NotchModel
    let bandHeight: CGFloat
    let notchWidth: CGFloat

    var body: some View {
        VStack(spacing: 10) {
            header
            if model.palette {
                PaletteView().transition(.opacity)
            } else {
                TabStrip()
                content
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 8) {
            let mark = Skin.current.mark
            if !mark.isEmpty {
                Image(systemName: mark).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            Text(model.palette ? "Search" : model.tab.title).font(Theme.title)
            Spacer(minLength: notchWidth + 16)      // keep clear of the camera housing
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(GlyphButtonStyle(radius: 11))
            .help("Quit Notch")
        }
        .frame(height: max(bandHeight, 28))
    }

    private var content: some View {
        let d = model.tabDirection
        return ZStack {
            TabContent(tab: model.tab)
                .id(model.tab)
                .transition(.asymmetric(
                    insertion: .move(edge: d > 0 ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: d > 0 ? .leading : .trailing).combined(with: .opacity)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

struct TabStrip: View {
    @EnvironmentObject private var model: NotchModel
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Skin.visibleTabs) { t in
                Button { model.setTab(t) } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 29, height: 26)
                        .foregroundStyle(model.tab == t ? Color.white : Color.white.opacity(0.55))
                        .background {
                            if model.tab == t {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Skin.current.id == "classic" ? Theme.control : Theme.accent.opacity(0.3))
                                    .matchedGeometryEffect(id: "selection", in: ns)
                            }
                        }
                }
                .buttonStyle(GlyphButtonStyle())
                .help(t.title)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.card))
    }
}

struct TabContent: View {
    let tab: NotchTab

    var body: some View {
        switch tab {
        case .home: HomeView()
        case .meeting: MeetingView()
        case .media: MediaView()
        case .clipboard: ClipboardView()
        case .timer: TimerView()
        case .ai: UsageView()
        case .alerts: AlertsView()
        case .audio: AudioView()
        case .shelf: ShelfView()
        case .notes: NotesView()
        case .today: TodayView()
        case .markets: MarketsView()
        case .scores: ScoresView()
        case .stats: StatsView()
        case .tools: ToolsView()
        case .mirror: MirrorView()
        case .agents: AgentsView()
        case .claude: ClaudeView()
        case .apps: AppsView()
        case .settings: SettingsView()
        }
    }
}

/// Closed pill: solid black (matches the camera notch). Open: Liquid Glass on macOS 26
/// (the transparency slider sets how dark the tint is), else black at that opacity,
/// then the skin's colour wash, edge glow, and one blade-glint sweep each time it opens.
private struct NotchBackground: View {
    let shape: NotchShape, open: Bool, glass: Bool, opacity: Double
    let skin: Skin, glow: Bool
    @State private var glint: CGFloat = -0.4

    var body: some View {
        ZStack {
            if open, glass, #available(macOS 26, *) {
                Color.clear.glassEffect(.regular.tint((skin.tint.first ?? .black).opacity(opacity * 0.6)), in: shape)
            } else {
                shape.fill(Color.black.opacity(open ? opacity : 1))
            }
            if open, !skin.tint.isEmpty {
                // Stays visible even when the panel is very see-through.
                shape.fill(LinearGradient(colors: skin.tint.map { $0.opacity(max(0.45, 0.7 * opacity)) }, startPoint: .top, endPoint: .bottom))
            }
            if open, glow {
                // ponytail: static gradient + one-shot sweep; a looping animation would redraw every frame (heat).
                // Inner neon: a wide blurred stroke (drawn once, not animated) plus a crisp 1 px line.
                shape.stroke(AngularGradient(colors: skin.glow, center: .center), lineWidth: 10)
                    .blur(radius: 8).opacity(0.55)
                shape.stroke(AngularGradient(colors: skin.glow, center: .center), lineWidth: 2)
                    .opacity(0.9)
                shape.stroke(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white.opacity(0.9), location: 0.5),
                                                    .init(color: .clear, location: 1)],
                                            startPoint: UnitPoint(x: glint - 0.25, y: 0), endPoint: UnitPoint(x: glint + 0.25, y: 1)),
                             lineWidth: 1.5)
            }
        }
        .onChange(of: open) { o in
            guard o else { glint = -0.4; return }
            withAnimation(.easeInOut(duration: 0.9).delay(0.1)) { glint = 1.4 }
        }
    }
}
