import SwiftUI

struct HomeView: View {
    @ObservedObject private var home = HomeService.shared
    @ObservedObject private var audio = AudioService.shared
    @ObservedObject private var media = MediaService.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 10) {
                clock
                if media.hasTrack { miniPlayer }
            }
            .frame(width: 210)

            VStack(spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(HomeService.Tile.allCases) { tile($0) }
                }
                SliderRow(symbol: "sun.max.fill", value: Binding(get: { Double(home.brightness ?? 0) },
                                                                set: { home.setBrightness(Float($0)) }))
                    .disabled(home.brightness == nil)
                    .opacity(home.brightness == nil ? 0.4 : 1)
                SliderRow(symbol: audio.volumeSymbol, value: Binding(get: { Double(audio.muted ? 0 : audio.volume) },
                                                                    set: { audio.setVolume(Float($0)) })) {
                    audio.setMuted(!audio.muted)
                }
            }
        }
        .onAppear { home.refresh() }
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 2) {
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 40, weight: .semibold).monospacedDigit())
                Text(ctx.date, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(Theme.body).foregroundStyle(Theme.ink.opacity(0.6))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
    }

    private var miniPlayer: some View {
        HStack(spacing: 8) {
            Artwork(image: media.artwork, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(media.now?.title ?? "").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(media.now?.artist ?? "").font(.system(size: 11)).foregroundStyle(Theme.ink.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { media.send(.togglePlayPause) } label: {
                Image(systemName: media.now?.playing == true ? "pause.fill" : "play.fill").frame(width: 28, height: 28)
            }
            .buttonStyle(GlyphButtonStyle(radius: 8))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .onTapGesture { NotchModel.shared.setTab(.media) }
    }

    private func tile(_ t: HomeService.Tile) -> some View {
        let on = home.isOn(t), avail = home.available(t)
        return Button { home.toggle(t) } label: {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: t.symbol).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(on ? Theme.ink : Theme.ink.opacity(0.7))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(on ? tint(t) : Theme.control))
                Text(t.name).font(Theme.caption)
                Text(home.busy.contains(t) ? "…" : (home.detail[t] ?? (on ? "On" : "Off")))
                    .font(.system(size: 11)).foregroundStyle(Theme.ink.opacity(0.5)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        }
        .buttonStyle(GlyphButtonStyle(radius: 14))
        .disabled(!avail)
        .opacity(avail ? 1 : 0.4)
    }

    private func tint(_ t: HomeService.Tile) -> Color {
        switch t {
        case .wifi, .bluetooth: Theme.accent
        case .darkMode: Theme.purple
        case .nightShift: Theme.orange
        case .keepAwake: Theme.green
        case .lowPower: Theme.yellow
        }
    }
}

/// Flat slider in a capsule: icon on the left, fill shows the level.
struct SliderRow: View {
    let symbol: String
    @Binding var value: Double
    var onIcon: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Button { onIcon?() } label: {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).frame(width: 26, height: 26)
            }
            .buttonStyle(GlyphButtonStyle(radius: 13))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.control)
                    Capsule().fill(Theme.ink).frame(width: max(8, g.size.width * value))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    value = max(0, min(1, v.location.x / g.size.width))
                })
            }
            .frame(height: 8)
        }
        .padding(.horizontal, 6).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }
}
