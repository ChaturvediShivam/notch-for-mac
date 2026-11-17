import Foundation

/// Data minimisation (DPDP, GDPR, CCPA…): everything Notch keeps on this Mac has a lifetime, and one
/// button erases it all. One strict rule set for every country: the laws share the same principles
/// (keep only as long as needed, user control, erase on request), and detecting the user's country
/// would itself mean collecting data. Nothing here is ever sent to us.
@MainActor
enum Retention {
    static let day: TimeInterval = 86_400
    /// Fixed lifetimes for things people don't curate.
    static let listenDays = 7.0, screenshotDays = 1.0, logDays = 1.0   // log: the master build keeps heard text, so 24 h like transcripts

    /// At launch and every hour.
    static func run() {
        let c = Store.shared.config, now = Date()
        ClipboardService.shared.prune(before: now - Double(c.clipDays) * day)
        AlertsService.shared.prune(before: now - Double(c.alertDays) * day)
        MeetingService.shared.refreshSessions()      // unkept 24 h; kept after keptDays (0 = keep)
        MeetingService.trimLog(before: now - logDays * day)
        let shots = Paths.home.appendingPathComponent("screenshots"), listen = Paths.home.appendingPathComponent("listen")
        let shotCut = now - screenshotDays * day, listenCut = now - listenDays * day
        DispatchQueue.global(qos: .utility).async {
            deleteFiles(in: shots, before: shotCut)
            deleteFiles(in: listen, before: listenCut)
        }
    }

    /// "Delete all my data": transcripts (kept too), clipboard, alerts, notes, shelf list, Listen,
    /// screenshots, logs, web cache and the pasted meeting context. Settings and API keys stay.
    static func deleteAll() {
        ClipboardService.shared.wipe()
        AlertsService.shared.clear()
        NotesService.shared.wipe()
        ShelfService.shared.clear()
        MeetingService.shared.wipeAll()
        Store.shared.config.meetingTopic = ""; Store.shared.config.meetingCV = ""; Store.shared.config.meetingJD = ""
        URLCache.shared.removeAllCachedResponses()
        let fm = FileManager.default
        for d in ["screenshots", "listen"] { try? fm.removeItem(at: Paths.home.appendingPathComponent(d)) }
    }

    nonisolated static func deleteFiles(in dir: URL, before cutoff: Date) {
        let fm = FileManager.default
        for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where ((try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture) < cutoff {
            try? fm.removeItem(at: u)
        }
    }
}
