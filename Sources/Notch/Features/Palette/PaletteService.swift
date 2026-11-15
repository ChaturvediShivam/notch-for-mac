import AppKit

struct PaletteItem: Identifiable {
    enum Kind { case app, file, calc, web, url, command }
    let id = UUID()
    let kind: Kind
    let title: String
    var subtitle = ""
    var symbol = "magnifyingglass"
    var icon: NSImage? = nil
    let run: @MainActor () -> Void
}

/// Ctrl+Option+Space: apps, files (Spotlight), calculator, URLs, web search, short commands.
@MainActor
final class PaletteService: ObservableObject {
    static let shared = PaletteService()

    @Published var query = "" { didSet { if query != oldValue { search() } } }
    @Published private(set) var results: [PaletteItem] = []
    @Published var selection = 0

    private var fileItems: [PaletteItem] = []
    private var mdQuery: NSMetadataQuery?
    private var debounce: DispatchWorkItem?

    func reset() { query = ""; results = commands(""); selection = 0 }

    func move(_ d: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + d + results.count) % results.count
    }

    func activate(_ i: Int? = nil) {
        let i = i ?? selection
        guard results.indices.contains(i) else { return }
        let item = results[i]
        NotchModel.shared.closePalette(andNotch: item.kind != .command || item.title.hasPrefix("Open ") == false)
        item.run()
    }

    private func search() {
        selection = 0
        let q = query.trimmingCharacters(in: .whitespaces)
        fileItems = []
        rebuild(q)
        debounce?.cancel()
        mdQuery?.stop()
        guard q.count >= 2 else { return }
        let w = DispatchWorkItem { [weak self] in self?.startFileSearch(q) }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    private func rebuild(_ q: String) {
        var out: [PaletteItem] = []
        if let v = Calculator.eval(q) {
            let s = Calculator.format(v)
            out.append(PaletteItem(kind: .calc, title: "= " + s, subtitle: "Copy result", symbol: "equal.circle.fill") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
            })
        }
        if let url = Self.url(from: q) {
            out.append(PaletteItem(kind: .url, title: url.absoluteString, subtitle: "Open link", symbol: "link") {
                NSWorkspace.shared.open(url)
            })
        }
        if !q.isEmpty {
            let apps = AppsService.shared.installed
                .filter { $0.name.localizedCaseInsensitiveContains(q) }
                .sorted { a, b in
                    let pa = a.name.lowercased().hasPrefix(q.lowercased()), pb = b.name.lowercased().hasPrefix(q.lowercased())
                    return pa != pb ? pa : a.name.count < b.name.count
                }
                .prefix(6)
            for a in apps {
                out.append(PaletteItem(kind: .app, title: a.name, subtitle: "Application",
                                       icon: AppsService.shared.icon(a.url)) { AppsService.shared.open(a.url) })
            }
        }
        out += commands(q)
        out += fileItems
        if !q.isEmpty {
            out.append(PaletteItem(kind: .web, title: "Search the web for “\(q)”", subtitle: "Default browser",
                                   symbol: "globe") {
                var c = URLComponents(string: "https://www.google.com/search")!
                c.queryItems = [URLQueryItem(name: "q", value: q)]
                if let u = c.url { NSWorkspace.shared.open(u) }
            })
        }
        results = out
        if selection >= out.count { selection = 0 }
    }

    private func commands(_ q: String) -> [PaletteItem] {
        let model = NotchModel.shared!
        var all: [PaletteItem] = [
            PaletteItem(kind: .command, title: "Lock Screen", symbol: "lock.fill") { SystemControls.lockScreen() },
            PaletteItem(kind: .command, title: "Sleep", symbol: "moon.zzz.fill") { SystemControls.sleep() },
            PaletteItem(kind: .command, title: "Sleep Display", symbol: "display") { SystemControls.sleepDisplay() },
            PaletteItem(kind: .command, title: "Empty Trash", symbol: "trash.fill") { SystemControls.emptyTrash() },
            PaletteItem(kind: .command, title: "Toggle Dark Mode", symbol: "circle.lefthalf.filled") {
                Task { await SystemControls.setDarkMode(!SystemControls.darkMode) }
            },
            PaletteItem(kind: .command, title: "Toggle Keep Awake", symbol: "cup.and.saucer.fill") {
                HomeService.shared.toggle(.keepAwake)
            },
            PaletteItem(kind: .command, title: "Screenshot to Clipboard", symbol: "camera.viewfinder") {
                ToolsService.shared.screenshotToClipboard()
            },
            PaletteItem(kind: .command, title: "Copy Text from Screen (OCR)", symbol: "text.viewfinder") {
                ToolsService.shared.ocrScreen()
            },
            PaletteItem(kind: .command, title: "Pick Colour", symbol: "eyedropper") { ToolsService.shared.pickColor() },
            PaletteItem(kind: .command, title: "Ask Claude about Screen", symbol: "sparkles") {
                ClaudeService.shared.askAboutScreen()
            },
            PaletteItem(kind: .command, title: "Start Timer 5 min", symbol: "timer") {
                TimerService.shared.start(seconds: 300)
            },
            PaletteItem(kind: .command, title: "Quit Notch", symbol: "power") { NSApp.terminate(nil) },
        ]
        for t in NotchTab.allCases {
            all.append(PaletteItem(kind: .command, title: "Open \(t.title)", symbol: t.symbol) { model.show(t) })
        }
        // "timer 10" / "t 25m" starts a timer.
        if let secs = Self.timerSeconds(q) {
            all.insert(PaletteItem(kind: .command, title: "Start Timer \(TimerService.format(secs))", symbol: "timer") {
                TimerService.shared.start(seconds: secs)
            }, at: 0)
            return [all[0]]
        }
        if q.isEmpty { return Array(all.prefix(6)) }
        return all.filter { $0.title.localizedCaseInsensitiveContains(q) }.prefix(5).map { $0 }
    }

    static func timerSeconds(_ q: String) -> Int? {
        let p = q.lowercased().split(separator: " ")
        guard p.count == 2, p[0] == "timer" || p[0] == "t" else { return nil }
        var s = String(p[1]), mult = 60
        if s.hasSuffix("s") { mult = 1; s.removeLast() } else if s.hasSuffix("m") { s.removeLast() }
        else if s.hasSuffix("h") { mult = 3600; s.removeLast() }
        guard let n = Double(s), n > 0 else { return nil }
        return Int(n * Double(mult))
    }

    static func url(from q: String) -> URL? {
        guard !q.contains(" "), q.contains(".") else { return nil }
        if q.hasPrefix("http://") || q.hasPrefix("https://") { return URL(string: q) }
        let host = q.split(separator: "/").first.map(String.init) ?? q
        guard host.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(:\d+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
        else { return nil }
        return URL(string: "https://" + q)
    }

    // MARK: Files (Spotlight)

    private func startFileSearch(_ q: String) {
        let mq = NSMetadataQuery()
        mq.predicate = NSPredicate(format: "kMDItemDisplayName LIKE[cd] %@", "*\(q)*")
        mq.searchScopes = [NSMetadataQueryUserHomeScope]
        mq.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        nonisolated(unsafe) let query = mq
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: mq, queue: .main) { _ in
            MainActor.assumeIsolated { PaletteService.shared.filesArrived(query, q) }
        }
        mdQuery = mq
        mq.start()
    }

    private func filesArrived(_ mq: NSMetadataQuery, _ q: String) {
        mq.stop()
        guard q == query.trimmingCharacters(in: .whitespaces) else { return }
        var items: [PaletteItem] = []
        for i in 0..<min(mq.resultCount, 40) {
            guard let r = mq.result(at: i) as? NSMetadataItem,
                  let path = r.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !path.hasSuffix(".app"), !path.contains("/Library/") else { continue }
            let url = URL(fileURLWithPath: path)
            items.append(PaletteItem(kind: .file, title: url.lastPathComponent,
                                     subtitle: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                                     icon: NSWorkspace.shared.icon(forFile: path)) {
                if NSEvent.modifierFlags.contains(.command) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                else { NSWorkspace.shared.open(url) }
            })
            if items.count == 6 { break }
        }
        fileItems = items
        rebuild(q)
    }
}
