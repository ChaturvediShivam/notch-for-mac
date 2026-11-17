# Notch for Mac

Native Swift rewrite of the Windows "Notch" app (a Dynamic Island at the top of the screen).
The full spec is `docs/report.md` (the Windows build report). Read it before starting a milestone.
Goal: every feature of the Windows version that macOS allows, built natively.

## Stack
- Swift Package (no Xcode project): `swift build`, `swift run`, `./scripts/make-app.sh` for `build/Notch.app`.
- Checks: `NOTCH_SELFTEST=1 swift run Notch`; `NOTCH_SNAPSHOT=<dir>` renders every tab to PNG.
- Lag: quit the app, then `NOTCH_BENCH=1 build/Notch.app/Contents/MacOS/Notch` (also `=tabs`, `=meeting`) prints main-thread stalls per step.
- macOS 13+, Apple Silicon. AppKit `NSPanel` + SwiftUI views inside `NSHostingView`.
- No third-party dependencies unless a milestone really needs one; ask first.

## Layout
- `Sources/Notch/NotchPanel.swift` window (non-activating, all Spaces, hidden from capture)
- `Sources/Notch/NotchController.swift` hover model (dwell 90 ms, hold 350 ms, 18 px ears), scroll-to-switch-tab
- `Sources/Notch/NotchModel.swift` state + `NotchTab` enum (19 tabs)
- `Sources/Notch/Geometry.swift` hardware-notch size, external-display pill
- `Sources/Notch/Views/` SwiftUI: `NotchView`, `NotchShape`, `Theme`
- `Sources/Notch/Core/` shared bits: `Config` (Store, ~/.notch/config.json), `Shell`, `Keychain`, `Net`, `Hotkeys`, `LocalServer` (127.0.0.1 API), `OCR`, `SelfTest`
- `Sources/Notch/Views/LiveActivity.swift` what the closed pill shows (priority order in `Activity.current()`)
- `Sources/NotchMediaRemote/` ObjC dylib loaded by /usr/bin/perl for Now Playing (MediaRemote blocks us directly)
- New features go in `Sources/Notch/Features/<Name>/` (service + view), one folder per tab. Services are `@MainActor` singletons (`X.shared`).
- `Resources/Info.plist` holds the permission usage strings; features needing permissions must run from `build/Notch.app`.
- Data lives in `~/.notch/` (config.json, etc.). Secrets in Keychain.

## Rules (lessons from the Windows version)
1. Nothing slow on the main thread: system calls, shell commands, network, disk go async and publish results back on the main actor.
2. Window size never changes; SwiftUI animates the shape inside it with springs (interruptible).
3. Tab slide direction comes from the real index change (`model.setTab`), never from gesture sign.
4. The notch never takes keyboard focus except while typing; give focus back afterwards (`panel.allowsKey`).
5. Hotkeys: test-register each one; a key owned by another app fails silently.
6. Command-line output: decode as UTF-8.
7. Design: flat, pure black, white at low alpha (card 0.11, control 0.18, hover 0.32), iOS accent colours in `Theme`, every hover/press fill rounded. SF Pro + SF Symbols.
8. Every network feature gets its own privacy switch in Settings.
9. Ask before adding permissions (Location, Screen Recording, Accessibility, Input Monitoring); explain why in the UI.

## Workflow
- Work one milestone at a time from `docs/ROADMAP.md`; tick its checklist when done.
- After changes run `swift build` and fix every error and warning before saying done.
- Things only a human can check (hover feel, screen-share hiding, permissions prompts) go in the milestone's "test by hand" list.
