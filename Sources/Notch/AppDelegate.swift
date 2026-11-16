import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if let f = ProcessInfo.processInfo.environment["NOTCH_TEST_AUDIO"] { Transcriber.testFile(f); return }
            controller = NotchController()
            // Services that listen in the background (routes register before the server starts).
            _ = AlertsService.shared
            _ = AgentsService.shared
            LocalServer.shared.route("POST", "/meeting/toggle") { _ in
                MeetingService.shared.toggle(); return (200, ["ok": true])
            }
            LocalServer.shared.start()
            _ = MediaService.shared
            _ = AudioService.shared
            _ = ClipboardService.shared
            _ = HomeService.shared
            _ = AppsService.shared
            // Unkept meeting transcripts go after 24 h: check now and every hour.
            MeetingService.shared.refreshSessions()
            CallWatch.shared.start()
            // Artwork/weather/lyrics cache: capped; macOS evicts the oldest past 20 MB.
            URLCache.shared = URLCache(memoryCapacity: 4_000_000, diskCapacity: 20_000_000)
            Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
                MainActor.assumeIsolated { MeetingService.shared.refreshSessions() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            MediaService.shared.stop()
            SystemControls.setKeepAwake(false)
        }
    }
}
