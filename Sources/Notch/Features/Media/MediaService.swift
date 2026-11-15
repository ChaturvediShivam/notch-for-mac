import AppKit

struct NowPlaying: Equatable {
    var title = "", artist = "", album = ""
    var duration: Double = 0
    var elapsed: Double = 0
    var timestamp = Date()
    var rate: Double = 0
    var playing = false
    var pid: Int32 = 0

    /// Elapsed time right now, extrapolated from the last report.
    func position(at now: Date = Date()) -> Double {
        guard playing else { return elapsed }
        let p = elapsed + now.timeIntervalSince(timestamp) * max(rate, 1)
        return duration > 0 ? min(p, duration) : p
    }
}

struct LyricLine: Equatable { let time: Double; let text: String }

/// Now Playing via MediaRemote. On macOS 15.4+ MediaRemote only answers Apple-signed
/// clients, so a tiny dylib is loaded into /usr/bin/perl and streams JSON lines to us.
@MainActor
final class MediaService: ObservableObject {
    static let shared = MediaService()

    enum Command: Int { case play = 0, pause = 1, togglePlayPause = 2, next = 4, previous = 5 }

    @Published private(set) var now: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var lyrics: [LyricLine] = []
    @Published private(set) var lyricsState = ""      // "", "Loading…", "No lyrics found", "Lyrics off"
    @Published private(set) var error: String?

    private var proc: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var lyricsKey = ""
    private var restarts = 0

    private init() { start() }

    var appName: String? { now.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.localizedName } }
    var appIcon: NSImage? { now.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.icon } }
    var hasTrack: Bool { !(now?.title.isEmpty ?? true) }

    private static var dylib: URL? {
        let dir = Bundle.main.executableURL!.deletingLastPathComponent()
        for p in ["libNotchMediaRemote.dylib", "../Frameworks/libNotchMediaRemote.dylib"] {
            let u = dir.appendingPathComponent(p).standardized
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    private func start() {
        guard let lib = Self.dylib else { error = "libNotchMediaRemote.dylib missing"; return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", """
            require DynaLoader; my $l = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
            my $s = DynaLoader::dl_find_symbol($l, "notch_mr_stream") or die "symbol";
            DynaLoader::dl_install_xsub("main::stream", $s); stream();
            """, lib.path]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardInput = inp; p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { MediaService.shared.received(d) } }
        }
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let s = MediaService.shared
                    s.proc = nil
                    s.restarts += 1
                    guard s.restarts < 5 else { s.error = "Now Playing helper keeps stopping"; return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { s.start() } }
                }
            }
        }
        do { try p.run(); proc = p; stdin = inp.fileHandleForWriting } catch { self.error = "\(error)" }
    }

    func stop() { proc?.terminationHandler = nil; proc?.terminate() }

    func send(_ c: Command) { write("cmd \(c.rawValue)") }
    func seek(_ seconds: Double) { write("seek \(seconds)") }

    private func write(_ s: String) { try? stdin?.write(contentsOf: Data((s + "\n").utf8)) }

    private func received(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { apply(obj) }
        }
    }

    private func apply(_ o: [String: Any]) {
        restarts = 0
        if let e = o["error"] as? String { error = e; return }
        var n = NowPlaying()
        n.title = o["title"] as? String ?? ""
        n.artist = o["artist"] as? String ?? ""
        n.album = o["album"] as? String ?? ""
        n.duration = (o["duration"] as? NSNumber)?.doubleValue ?? 0
        n.elapsed = (o["elapsedtime"] as? NSNumber)?.doubleValue ?? 0
        n.rate = (o["playbackrate"] as? NSNumber)?.doubleValue ?? 0
        n.playing = (o["playing"] as? Bool) ?? false
        n.pid = Int32((o["pid"] as? NSNumber)?.intValue ?? 0)
        if let ts = (o["timestamp"] as? NSNumber)?.doubleValue { n.timestamp = Date(timeIntervalSince1970: ts) }
        if let b64 = o["artwork"] as? String, let data = Data(base64Encoded: b64) { artwork = NSImage(data: data) }
        if o["noArtwork"] != nil { artwork = nil }
        if n != now { now = n.title.isEmpty && n.pid == 0 ? nil : n }
        loadLyricsIfNeeded()
    }

    // MARK: Lyrics (lrclib.net)

    private func loadLyricsIfNeeded() {
        guard let n = now, !n.title.isEmpty else { lyrics = []; lyricsKey = ""; return }
        let key = n.artist + "|" + n.title
        guard key != lyricsKey else { return }
        lyricsKey = key
        lyrics = []
        guard Store.shared.config.netLyrics else { lyricsState = "Lyrics are off in Settings"; return }
        guard !n.artist.isEmpty else { lyricsState = "No lyrics for this"; return }    // browser tabs, videos
        lyricsState = "Loading lyrics…"
        Task {
            var c = URLComponents(string: "https://lrclib.net/api/get")!
            c.queryItems = [URLQueryItem(name: "artist_name", value: n.artist),
                            URLQueryItem(name: "track_name", value: n.title),
                            URLQueryItem(name: "album_name", value: n.album)]
            if n.duration > 0 { c.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(n.duration.rounded())))) }
            let j: Any? = try? await Net.json(c.url!)
            let lines = Self.parseLRC(j["syncedLyrics"].str ?? "")
            guard key == self.lyricsKey else { return }
            self.lyrics = lines
            self.lyricsState = lines.isEmpty ? "No synced lyrics" : ""
        }
    }

    static func parseLRC(_ s: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for raw in s.split(separator: "\n") {
            var line = Substring(raw), stamps: [Double] = []
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let tag = line[line.index(after: line.startIndex)..<close]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let sec = Double(parts[1]) { stamps.append(m * 60 + sec) }
                line = line[line.index(after: close)...]
            }
            let text = line.trimmingCharacters(in: .whitespaces)
            out += stamps.map { LyricLine(time: $0, text: text) }
        }
        return out.sorted { $0.time < $1.time }
    }

    func lyricIndex(at t: Double) -> Int? { lyrics.lastIndex { $0.time <= t + 0.2 } }
}
