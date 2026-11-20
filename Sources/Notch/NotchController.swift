import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Owns the panel and the hover model: dwell 90 ms to open, hold 350 ms to close,
/// 18 px "ears" either side of the closed pill that still count as hovering.
@MainActor
final class NotchController {
    static weak var shared: NotchController?
    var panelFrame: CGRect { panel.frame }
    private let model: NotchModel
    private let panel = NotchPanel()

    private static let dwell: TimeInterval = 0.09
    private static let hold: TimeInterval = 0.35
    private static let ear: CGFloat = 18
    private static let pad: CGFloat = 40          // room for the open panel's shadow

    private var monitors: [Any] = []
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var pollTimer: Timer?
    private var scrollAccum: CGFloat = 0

    init() {
        let screen = NSScreen.preferredForNotch ?? NSScreen.screens[0]
        model = NotchModel(geometry: .make(for: screen))

        let host = NSHostingView(rootView: NotchView().environmentObject(model))
        host.sizingOptions = []                    // the window never resizes; SwiftUI animates inside it
        panel.contentView = host

        layout()
        panel.orderFrontRegardless()
        Self.shared = self
        installMonitors()
        model.onFocus = { [weak self] on in self?.setFocus(on) }
        // While open, a click on a text field may take the keyboard (becomesKeyOnlyIfNeeded);
        // on close the keyboard goes back to the app in front.
        model.onOpenChange = { [weak self] open in
            guard let self else { return }
            if open { self.panel.allowsKey = true } else { self.setFocus(false) }
            Look.shared.watch(open) { [weak self] in self?.panel.frame ?? .zero }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.screensChanged() } }

        registerHotkeys()

        // NOTCH_OPEN=media (any tab title prefix, or "palette") opens it at launch: handy for screenshots.
        if let t = ProcessInfo.processInfo.environment["NOTCH_OPEN"]?.lowercased() {
            if t == "palette" { model.openPalette() }
            else if let tab = NotchTab.allCases.first(where: { $0.title.lowercased().hasPrefix(t) }) { model.show(tab) }
        }
        // NOTCH_SNAPSHOT=<dir> renders every tab to PNGs there and quits (layout smoke test, no screen permission needed).
        if let dir = ProcessInfo.processInfo.environment["NOTCH_SNAPSHOT"] { snapshotAll(to: URL(fileURLWithPath: dir)) }
        if let b = ProcessInfo.processInfo.environment["NOTCH_BENCH"] { Bench.run(model, only: b == "1" ? nil : b) }
    }

    private func snapshotAll(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        model.show(.home)
        var queue: [String] = NotchTab.allCases.map(\.title) + ["Palette"]
        func next() {
            guard !queue.isEmpty else { NSApp.terminate(nil); return }
            let name = queue.removeFirst()
            if name == "Palette" { model.openPalette(); PaletteService.shared.query = "calc" }
            else if let t = NotchTab.allCases.first(where: { $0.title == name }) { model.show(t) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard let v = self.panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return next() }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent(name.replacingOccurrences(of: " ", with: "_") + ".png"))
                next()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { next() }
    }

    private func registerHotkeys() {
        let m = Hotkeys.ctrlOpt
        let model = model
        Hotkeys.shared.register([
            .init(name: "⌃⌥Space  Palette", key: kVK_Space, mods: m) { model.openPalette() },
            .init(name: "⌃⌥N  Open / close notch", key: kVK_ANSI_N, mods: m) { model.toggleOpen() },
            .init(name: "⌃⌥C  Ask Claude", key: kVK_ANSI_C, mods: m) { model.show(.claude, focus: true) },
            .init(name: "⌃⌥S  Ask Claude about screen", key: kVK_ANSI_S, mods: m) { ClaudeService.shared.askAboutScreen() },
            .init(name: "⌃⌥D  Dictate", key: kVK_ANSI_D, mods: m) { VoiceService.shared.toggleDictation() },
            .init(name: "⌃⌥L  Listen (live captions)", key: kVK_ANSI_L, mods: m) { VoiceService.shared.toggleListen() },
            .init(name: "⌃⌥M  Meeting mode (start / stop)", key: kVK_ANSI_M, mods: m) { MeetingService.shared.toggle() },
            .init(name: "⌃⌥E  Explain what was just said", key: kVK_ANSI_E, mods: m) {
                MeetingService.shared.ask(); model.show(.meeting)
            },
            .init(name: "⌃⌥V  Clipboard", key: kVK_ANSI_V, mods: m) { model.show(.clipboard) },
            .init(name: "⌃⌥P  Play / pause", key: kVK_ANSI_P, mods: m) { MediaService.shared.send(.togglePlayPause) },
        ])
    }

    // MARK: Focus (rule 4)

    private func setFocus(_ on: Bool) {
        if on {
            panel.ignoresMouseEvents = false
            panel.allowsKey = true
            panel.makeKey()
        } else if panel.allowsKey {
            let wasKey = panel.isKeyWindow
            panel.allowsKey = false
            if wasKey {
                panel.resignKey()
                // Hand the keyboard back to whatever app was in front.
                NSWorkspace.shared.frontmostApplication?.activate()
            }
        }
    }

    // MARK: Layout

    private func layout() {
        let g = model.geometry
        let w = g.openSize.width + 24 + Self.pad * 2
        let h = g.openSize.height + Self.pad
        panel.setFrame(NSRect(x: g.screenFrame.midX - w / 2, y: g.screenFrame.maxY - h,
                              width: w, height: h), display: true)
    }

    private func screensChanged() {
        guard let screen = NSScreen.preferredForNotch else { return }
        let g = NotchGeometry.make(for: screen)
        if g != model.geometry { model.geometry = g }
        layout()
        panel.orderFrontRegardless()
    }

    /// The area (screen coordinates) that counts as "on the notch" right now.
    private func hotRect() -> NSRect {
        let g = model.geometry, s = g.screenFrame
        if model.isOpen {
            let w = g.openSize.width + 24
            return NSRect(x: s.midX - w / 2, y: s.maxY - g.openSize.height,
                          width: w, height: g.openSize.height + 2)
        }
        let w = g.closedSize.width + Activity.current().extraWidth + Self.ear * 2
        let h = g.closedSize.height + 6
        return NSRect(x: s.midX - w / 2, y: s.maxY - h, width: w, height: h + 2)
    }

    // MARK: Pointer and keys

    private func installMonitors() {
        let move: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: move, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: move, handler: { [weak self] e in
            self?.pointerMoved(); return e
        }) { monitors.append(m) }

        // Dragging a file onto the notch opens the Shelf.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dragMoved() }
        }) { monitors.append(m) }

        // Click outside while pinned closes it.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.isOpen, !self.hotRect().contains(NSEvent.mouseLocation) else { return }
                self.model.setOpen(false)
            }
        }) { monitors.append(m) }

        // Wheel or two-finger horizontal swipe switches tabs while open.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            guard let self, self.model.isOpen, !self.model.palette else { return e }
            return self.handleScroll(e) ? nil : e
        }) { monitors.append(m) }

        // Esc closes; arrows drive the palette.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self else { return e }
            switch Int(e.keyCode) {
            case kVK_Escape: self.model.setOpen(false); return nil
            case kVK_DownArrow where self.model.palette: PaletteService.shared.move(1); return nil
            case kVK_UpArrow where self.model.palette: PaletteService.shared.move(-1); return nil
            default: return e
            }
        }) { monitors.append(m) }
    }

    private func dragMoved() {
        guard !model.isOpen, hotRect().contains(NSEvent.mouseLocation) else { return }
        let pb = NSPasteboard(name: .drag)
        guard pb.types?.contains(.fileURL) == true else { return }
        panel.ignoresMouseEvents = false
        model.show(.shelf)
    }

    private func pointerMoved() {
        let inside = hotRect().contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside && !panel.allowsKey
        if inside, !model.hovering, !model.isOpen { Look.shared.refresh(panel.frame) }   // know day/night before it opens
        model.setHovering(inside)

        // While the pointer is over our window the global monitor goes quiet,
        // so a light 20 Hz poll watches for the exit; it stops once outside.
        if inside, pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved() }
            }
        } else if !inside {
            pollTimer?.invalidate(); pollTimer = nil
        }

        if inside {
            closeWork?.cancel(); closeWork = nil
            if !model.isOpen, openWork == nil {
                let w = DispatchWorkItem { [weak self] in
                    self?.openWork = nil
                    self?.model.setOpen(true)
                }
                openWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell, execute: w)
            }
        } else {
            openWork?.cancel(); openWork = nil
            if model.isOpen, !model.pinned, !panel.isKeyWindow, closeWork == nil {
                let w = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.closeWork = nil
                    if !self.model.pinned, !self.panel.isKeyWindow { self.model.setOpen(false) }
                }
                closeWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold, execute: w)
            }
        }
    }

    /// Returns true when the event was used for tab switching.
    private func handleScroll(_ e: NSEvent) -> Bool {
        if e.hasPreciseScrollingDeltas {
            // Trackpad: horizontal swipe, about 60 pt per tab. Vertical scrolls go to the content.
            if e.phase == .began { scrollAccum = 0 }
            guard abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return false }
            scrollAccum += e.scrollingDeltaX
            if abs(scrollAccum) >= 60 {
                model.step(scrollAccum < 0 ? 1 : -1)
                scrollAccum = 0
            }
            return true
        }
        // Mouse wheel: only over the tab strip, one notch one tab.
        let s = model.geometry.screenFrame
        guard NSEvent.mouseLocation.y > s.maxY - 80 else { return false }
        let d = e.scrollingDeltaY != 0 ? e.scrollingDeltaY : e.scrollingDeltaX
        if d != 0 { model.step(d < 0 ? 1 : -1) }
        return true
    }
}
