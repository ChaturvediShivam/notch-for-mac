import AppKit
import ServiceManagement

/// Login item (SMAppService) and crash keep-alive (a per-user launchd agent).
@MainActor
enum AppLifecycle {
    static var loginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setLoginItem(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static let label = "com.shivam.notch.keepalive"
    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var keepAliveEnabled: Bool { FileManager.default.fileExists(atPath: agentURL.path) }

    /// Relaunches Notch if it crashes. A normal Quit exits 0, which launchd leaves alone.
    static func setKeepAlive(_ on: Bool) async -> String? {
        let uid = getuid()
        if on {
            guard let exe = Bundle.main.executablePath else { return "No executable path" }
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "ProcessType": "Interactive",
                "ThrottleInterval": 10,
            ]
            do {
                try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentURL)
            } catch { return error.localizedDescription }
            await Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", agentURL.path])
        } else {
            await Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
            try? FileManager.default.removeItem(at: agentURL)
        }
        return nil
    }
}
