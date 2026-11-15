import AppKit

struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var hasHardwareNotch: Bool
    var closedSize: CGSize
    var openSize: CGSize

    static let panelSize = CGSize(width: 680, height: 340)

    static func make(for screen: NSScreen) -> NotchGeometry {
        if let n = screen.notchSize {
            // Hug the camera housing exactly: black on black, invisible until it grows.
            return NotchGeometry(screenFrame: screen.frame, hasHardwareNotch: true,
                                 closedSize: n, openSize: panelSize)
        }
        // External display: draw our own pill, as tall as the menu bar.
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        let h = min(max(bar, 24), 32)
        return NotchGeometry(screenFrame: screen.frame, hasHardwareNotch: false,
                             closedSize: CGSize(width: 200, height: h), openSize: panelSize)
    }
}

extension NSScreen {
    /// Size of the hardware notch, nil on screens without one.
    var notchSize: CGSize? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        return CGSize(width: frame.width - left.width - right.width, height: safeAreaInsets.top)
    }

    /// Built-in notched screen first, else the main screen.
    static var preferredForNotch: NSScreen? {
        screens.first { $0.notchSize != nil } ?? main ?? screens.first
    }
}
