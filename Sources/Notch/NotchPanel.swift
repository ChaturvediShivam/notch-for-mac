import AppKit

/// Borderless, non-activating, always-on-top panel on every Space, hidden from screen capture.
final class NotchPanel: NSPanel {
    /// Focus rule: the notch only takes the keyboard while the user types (later milestones).
    var allowsKey = false

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true              // click-through until the pointer is on the pill

        // Hidden from Zoom / Meet / Teams / QuickTime. NOTCH_VISIBLE=1 shows it (for demos).
        let visible = ProcessInfo.processInfo.environment["NOTCH_VISIBLE"] == "1"
        sharingType = visible ? .readOnly : .none
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// ⌘X/C/V/A/Z normally come from the Edit menu; an accessory app has no menu bar,
    /// so text fields in the notch never got paste. Send them to the focused field directly.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command || mods == [.command, .shift] else { return super.performKeyEquivalent(with: e) }
        let action: Selector? = switch (e.charactersIgnoringModifiers?.lowercased(), mods.contains(.shift)) {
        case ("x", false): #selector(NSText.cut(_:))
        case ("c", false): #selector(NSText.copy(_:))
        case ("v", false): #selector(NSText.paste(_:))
        case ("a", false): #selector(NSText.selectAll(_:))
        case ("z", false): Selector(("undo:"))
        case ("z", true): Selector(("redo:"))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: e)
    }

    // Let the window sit over the menu bar instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
