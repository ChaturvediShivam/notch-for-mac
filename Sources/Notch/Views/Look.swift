import AppKit
import ScreenCaptureKit
import SwiftUI
import os

private let lookLog = Logger(subsystem: "notch", category: "look")

/// Day or night for the open notch. Auto: when the panel is see-through, read how bright the screen is
/// right behind it and pick the opposite text colour; when it's solid, follow macOS Light/Dark.
@MainActor
final class Look: ObservableObject {
    static let shared = Look()
    /// NOTCH_LOOK=day starts in day mode (snapshots of both looks).
    @Published private(set) var light = ProcessInfo.processInfo.environment["NOTCH_LOOK"] == "day"
    private var timer: Timer?
    private var busy = false

    /// See-through enough that what's behind decides the text colour.
    private var seeThrough: Bool {
        let c = Store.shared.config
        if #available(macOS 26, *), c.glass { return true }
        return c.opacity < 0.85
    }

    /// Hover (so it's known before the panel opens) and every 3 s while open.
    func watch(_ on: Bool, frame: @escaping () -> CGRect) {
        timer?.invalidate(); timer = nil
        guard on else { return }
        refresh(frame())
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { Look.shared.refresh(frame()) }
        }
    }

    func refresh(_ rect: CGRect) {
        if ProcessInfo.processInfo.environment["NOTCH_LOOK"] != nil { return }   // pinned for snapshots
        switch Store.shared.config.appearance {
        case "day": set(true)
        case "night": set(false)
        default:
            let system = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            // Reading the screen needs Screen Recording (Meeting already asks); never prompt for it here.
            guard seeThrough, CGPreflightScreenCaptureAccess(), !busy else {
                if !seeThrough || !CGPreflightScreenCaptureAccess() {
                    set(system); lookLog.notice("no screen reading (seeThrough \(self.seeThrough), access \(CGPreflightScreenCaptureAccess())) → system")
                }
                return
            }
            busy = true
            Task {
                let lum = await Self.brightness(behind: rect)
                busy = false
                // Hysteresis so a mid-grey wallpaper doesn't flip it back and forth.
                // A white page with some text averages ~0.5–0.6, so switch to day from 0.5; back to night under 0.38.
                if let lum { set(light ? lum > 0.38 : lum > 0.5) } else { set(system) }
                lookLog.notice("brightness behind \(lum ?? -1, format: .fixed(precision: 2)) → \(self.light ? "day" : "night", privacy: .public)")
            }
        }
    }

    private func set(_ v: Bool) {
        guard v != light else { return }
        // Liquid Glass draws from the window's appearance: in macOS Dark mode it stayed dark grey by day,
        // under the new black text. Our app's appearance follows day/night so the glass turns light too.
        NSApp.appearance = NSAppearance(named: v ? .aqua : .darkAqua)
        withAnimation(.easeInOut(duration: 0.25)) { light = v }
    }

    /// Average brightness 0…1 of the screen under `rect` (AppKit coordinates). Our own panel is hidden
    /// from capture, so this is what's really behind it. A 32×16 image: cheap.
    nonisolated static func brightness(behind rect: CGRect) async -> Double? {
        guard #available(macOS 14, *),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let (f, id) = await MainActor.run(body: { () -> (CGRect, CGDirectDisplayID)? in
                  guard let s = NSScreen.screens.first(where: { $0.frame.intersects(rect) }),
                        let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
                  return (s.frame, id)
              }),
              let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = CGRect(x: rect.minX - f.minX, y: f.maxY - rect.maxY, width: rect.width, height: rect.height)
        cfg.width = 32; cfg.height = 16
        // Leave our own windows out explicitly (they're hidden from capture anyway, unless NOTCH_VISIBLE=1).
        let me = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return nil }
        return average(img)
    }

    nonisolated static func average(_ img: CGImage) -> Double? {
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))   // scaled to 1 px = the average colour
        return (0.2126 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.0722 * Double(px[2])) / 255
    }
}
