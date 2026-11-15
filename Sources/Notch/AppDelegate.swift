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
            LocalServer.shared.start()
            _ = MediaService.shared
            _ = AudioService.shared
            _ = ClipboardService.shared
            _ = HomeService.shared
            _ = AppsService.shared
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            MediaService.shared.stop()
            SystemControls.setKeepAwake(false)
        }
    }
}
