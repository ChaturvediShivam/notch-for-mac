import AppKit

if ProcessInfo.processInfo.environment["NOTCH_SELFTEST"] == "1" { MainActor.assumeIsolated { SelfTest.run() } }

// One copy only: a second launch exits quietly.
guard SingleInstance.acquire() else { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar (LSUIElement)
app.run()
