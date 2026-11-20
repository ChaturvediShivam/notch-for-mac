import SwiftUI

struct MediaView: View {
    @ObservedObject private var media = MediaService.shared
    @ObservedObject private var audio = AudioService.shared

    var body: some View {
        if let n = media.now, !n.title.isEmpty {
            HStack(spacing: 12) {
                player(n).frame(width: 330)
                LyricsView()
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "music.note").font(.system(size: 28)).foregroundStyle(Theme.ink.opacity(0.6))
                Text("Nothing playing").font(Theme.title)
                Text(media.error ?? "Play something in Music, Spotify, a browser…")
                    .font(Theme.caption).foregroundStyle(Theme.ink.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
        }
    }

    private func player(_ n: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Artwork(image: media.artwork, size: 84)
                VStack(alignment: .leading, spacing: 3) {
                    Text(n.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text(n.artist).font(Theme.body).foregroundStyle(Theme.ink.opacity(0.65)).lineLimit(1)
                    HStack(spacing: 4) {
                        if let icon = media.appIcon { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
                        Text(media.appName ?? "").font(.system(size: 11)).foregroundStyle(Theme.ink.opacity(0.45))
                    }
                }
                Spacer(minLength: 0)
            }
            ProgressBar(n: n)
            HStack(spacing: 18) {
                outputMenu
                Spacer()
                control("backward.fill") { media.send(.previous) }
                control(n.playing ? "pause.fill" : "play.fill", size: 22) { media.send(.togglePlayPause) }
                control("forward.fill") { media.send(.next) }
                Spacer()
                Color.clear.frame(width: 26, height: 1)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
    }

    private var outputMenu: some View {
        Menu {
            ForEach(audio.outputs) { d in
                Button { audio.setDefault(d) } label: {
                    if d.id == audio.defaultOutput { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                }
            }
        } label: {
            Image(systemName: "airplayaudio").font(.system(size: 13))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26)
        .help("Output device")
    }

    private func control(_ symbol: String, size: CGFloat = 16, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).frame(width: 40, height: 34)
        }
        .buttonStyle(GlyphButtonStyle(radius: 10))
    }
}

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else { ZStack { Theme.control; Image(systemName: "music.note").foregroundStyle(Theme.ink.opacity(0.6)) } }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
    }
}

private struct ProgressBar: View {
    let n: NowPlaying
    @State private var drag: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let pos = drag ?? n.position(at: ctx.date)
            let frac = n.duration > 0 ? pos / n.duration : 0
            VStack(spacing: 3) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.control)
                        Capsule().fill(Theme.ink.opacity(0.85)).frame(width: max(4, g.size.width * frac))
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in drag = max(0, min(1, v.location.x / g.size.width)) * n.duration }
                        .onEnded { _ in if let d = drag { MediaService.shared.seek(d) }; drag = nil })
                }
                .frame(height: 5)
                HStack {
                    Text(Self.time(pos)); Spacer(); Text("-" + Self.time(max(0, n.duration - pos)))
                }
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.ink.opacity(0.5))
            }
        }
    }

    static func time(_ t: Double) -> String {
        let s = Int(t.isFinite ? t : 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct LyricsView: View {
    @ObservedObject private var media = MediaService.shared

    var body: some View {
        Group {
            if media.lyrics.isEmpty {
                Hint(media.lyricsState.isEmpty ? "No lyrics" : media.lyricsState)
            } else {
                TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                    let cur = media.lyricIndex(at: media.now?.position(at: ctx.date) ?? 0)
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(media.lyrics.enumerated()), id: \.offset) { i, l in
                                    Text(l.text.isEmpty ? "♪" : l.text)
                                        .font(.system(size: i == cur ? 15 : 13, weight: i == cur ? .bold : .medium))
                                        .foregroundStyle(Theme.ink.opacity(i == cur ? 1 : 0.35))
                                        .id(i)
                                        .onTapGesture { MediaService.shared.seek(l.time) }
                                }
                            }
                            .padding(.vertical, 60)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: cur) { c in
                            if let c { withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(c, anchor: .center) } }
                        }
                        .onAppear { if let cur { proxy.scrollTo(cur, anchor: .center) } }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
    }
}
