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

    // Let the window sit over the menu bar instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
