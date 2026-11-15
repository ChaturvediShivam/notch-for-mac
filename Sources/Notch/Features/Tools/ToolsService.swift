import AppKit

@MainActor
final class ToolsService: ObservableObject {
    static let shared = ToolsService()

    @Published var status = ""
    @Published var lastColor: NSColor?
    @Published var hiddenFiles = UserDefaults(suiteName: "com.apple.finder")?.bool(forKey: "AppleShowAllFiles") ?? false

    func screenshotToClipboard() {
        NotchModel.shared.setOpen(false)
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            await Shell.run("/usr/sbin/screencapture", ["-i", "-c", "-x"])
            status = "Screenshot copied"
        }
    }

    func ocrScreen() {
        NotchModel.shared.setOpen(false)
        Task {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("notch-ocr-\(UUID().uuidString).png")
            try? await Task.sleep(nanoseconds: 250_000_000)
            await Shell.run("/usr/sbin/screencapture", ["-i", "-x", url.path])
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let t = await OCR.text(in: url)
            try? FileManager.default.removeItem(at: url)
            guard !t.isEmpty else { status = "No text found"; return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
            status = "Copied \(t.count) characters"
            AlertsService.shared.add(title: "Text copied", body: String(t.prefix(200)), source: "OCR")
        }
    }

    func pickColor() {
        NotchModel.shared.setOpen(false)
        NSColorSampler().show { c in
            guard let c = c?.usingColorSpace(.sRGB) else { return }
            MainActor.assumeIsolated {
                let hex = String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hex, forType: .string)
                ToolsService.shared.lastColor = c
                ToolsService.shared.status = "\(hex) copied"
            }
        }
    }

    func toggleHiddenFiles() {
        hiddenFiles.toggle()
        let on = hiddenFiles
        Task {
            await Shell.run("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", on ? "true" : "false"])
            await Shell.run("/usr/bin/killall", ["Finder"])
        }
    }
}
