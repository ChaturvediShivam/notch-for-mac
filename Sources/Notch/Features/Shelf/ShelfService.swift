import AppKit

/// Files parked on the notch: drop in, drag out, AirDrop, OCR images. References only (no copies).
@MainActor
final class ShelfService: ObservableObject {
    static let shared = ShelfService()

    @Published private(set) var items: [URL] =
        (DataFile.load("shelf.json", as: [String].self) ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    @Published var status = ""

    func add(_ urls: [URL]) {
        for u in urls where !items.contains(u) { items.append(u) }
        save()
    }

    func remove(_ u: URL) { items.removeAll { $0 == u }; save() }
    func clear() { items = []; save() }
    private func save() { DataFile.save("shelf.json", items.map(\.path)) }

    func airDrop(_ urls: [URL]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }

    func ocr(_ u: URL) {
        status = "Reading text…"
        Task {
            let t = await OCR.text(in: u)
            if t.isEmpty { status = "No text found" } else {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
                status = "Copied \(t.count) characters"
            }
        }
    }

    static func isImage(_ u: URL) -> Bool {
        ["png", "jpg", "jpeg", "heic", "tiff", "gif", "bmp", "webp"].contains(u.pathExtension.lowercased())
    }
}
