import AppKit

struct AppEntry: Identifiable, Hashable {
    let name: String
    let url: URL
    var id: String { url.path }
}

/// Installed-apps index (scanned off the main thread) plus running apps.
@MainActor
final class AppsService: ObservableObject {
    static let shared = AppsService()

    @Published private(set) var installed: [AppEntry] = []
    @Published private(set) var running: [NSRunningApplication] = []
    private var iconCache: [String: NSImage] = [:]

    private init() {
        refreshRunning()
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppsService.shared.refreshRunning() }
            }
        }
        rescan()
    }

    func rescan() {
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                        "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
            var seen = Set<String>(), out: [AppEntry] = []
            for d in dirs {
                for name in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where name.hasSuffix(".app") {
                    let display = String(name.dropLast(4))
                    guard seen.insert(display).inserted else { continue }
                    out.append(AppEntry(name: display, url: URL(fileURLWithPath: d).appendingPathComponent(name)))
                }
            }
            out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let result = out
            await MainActor.run { AppsService.shared.installed = result }
        }
    }

    func refreshRunning() {
        running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }

    func icon(_ url: URL) -> NSImage {
        if let i = iconCache[url.path] { return i }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[url.path] = i
        return i
    }

    func open(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    func togglePin(_ url: URL) {
        var p = Store.shared.config.pinnedApps
        if let i = p.firstIndex(of: url.path) { p.remove(at: i) } else { p.append(url.path) }
        Store.shared.config.pinnedApps = p
    }

    var pinned: [AppEntry] {
        Store.shared.config.pinnedApps.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { AppEntry(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
    }
}
