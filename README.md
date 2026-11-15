# Notch for Mac

A native macOS app that turns the MacBook camera notch into a Dynamic Island, with real-time bilingual meeting transcription & notes powered by Claude.

![Notch open](docs/screenshots/notch-open.png)

## Features

- **Meeting mode: real-time bilingual meeting transcription & notes.** Transcribes both sides of a call at once ("Them" from system audio, "Me" from the mic) in Hindi and English, spots questions and shows a suggested answer, explains what was just said, and saves a summary.
- **Claude:** chat with a one-click switch between the Claude Code CLI and the Anthropic API; attach files; ask about any region of the screen.
- **Agents:** approve or deny Claude Code tool calls from the notch.
- **Voice:** dictate into any app (stops on silence); live captions of the Mac's audio.
- **Media:** Now Playing with artwork, controls, seek and synced lyrics.
- **Home and Audio:** volume, brightness, Wi-Fi, Bluetooth, dark mode, Night Shift, keep awake; switches sound to earphones when you plug them in.
- **Palette:** Spotlight-style search for apps, files, maths, links and commands.
- **Today, Markets, Scores:** weather and calendar, a stock watchlist, live sports scores.
- **Shelf, Clipboard, Notes, Timer, Stats, Mirror:** file shelf with AirDrop and text from images, clipboard history, quick notes, timers in the pill, system stats, camera mirror.
- **Settings:** a privacy switch for every network feature, Liquid Glass and transparency, open at login, restart after a crash.
- Hidden from screenshots and screen sharing.

| | |
|---|---|
| ![Meeting mode](docs/screenshots/meeting.png) | ![Claude](docs/screenshots/claude.png) |
| ![Media](docs/screenshots/media.png) | ![Home](docs/screenshots/home.png) |

## Shortcuts

| Keys | Action |
|---|---|
| ⌃⌥ Space | Palette |
| ⌃⌥ N | Open / close the notch |
| ⌃⌥ M | Meeting mode start / stop |
| ⌃⌥ E | Explain what was just said |
| ⌃⌥ C | Ask Claude |
| ⌃⌥ S | Ask Claude about a screen region |
| ⌃⌥ D | Dictate |
| ⌃⌥ L | Live captions |
| ⌃⌥ V | Clipboard history |
| ⌃⌥ P | Play / pause |

## Architecture

| Layer | What it does | Key detail |
|---|---|---|
| Window (`NSPanel`) | Floating, non-activating panel over the notch on every Space | Excluded from capture; takes keyboard focus only while typing |
| Controller | Hover model, gestures, global hotkeys | 90 ms hover dwell, 350 ms hold; swipe or scroll switches tabs |
| SwiftUI views | Closed pill with live activities; open panel with 20 tabs | Spring animations inside a fixed-size window |
| Services | One `@MainActor` singleton per feature | System, network and disk work runs async off the main thread |
| Local API | HTTP server on 127.0.0.1 | Token-protected; receives Claude Code hooks and script notifications |
| Media bridge | Objective-C dynamic library loaded into a system process | Reads Now Playing, which macOS 15.4+ blocks for third-party apps |
| Data | `~/.notch/` config and transcripts; secrets in Keychain | Nothing leaves the Mac unless its network switch is on |

## Hard problems solved

| Problem | Cause | Fix |
|---|---|---|
| Now Playing stopped working | macOS 15.4+ blocks MediaRemote for third-party apps | Objective-C dylib loaded into a trusted system binary, streaming JSON lines |
| Two speech streams returned nothing | The old on-device recogniser runs one task at a time | Moved to macOS 26 SpeechAnalyzer; verified two parallel streams |
| Mic gave no text in Meeting mode | The echo-cancelling mic delivers 5 channels | Convert channel 0 to mono in the audio tap |
| Own voice echoed as "Them" on speakers | Speakers feed back into the mic | Apple voice processing plus a filter for repeated lines |
| Answers arrived too late | Waiting for final transcripts and a full CLI start | Trigger when the question holds still for 0.7 s; stripped one-shot Claude Code call (~1.6 s to first words) |
| Permissions reset on every build | Ad-hoc signing changes the code identity | Stable self-signed signing identity (`scripts/make-signing-cert.sh`) |
| Sound stayed on speakers with wired earphones | macOS kept the old default output | CoreAudio listener switches output on plug-in |
| Hindi shown in Devanagari | The Hindi model outputs native script | ICU transliteration to Roman letters |

## Tech stack

- Swift 6 (strict concurrency), Objective-C; Swift Package Manager, no Xcode project, no third-party dependencies
- SwiftUI in AppKit; Liquid Glass on macOS 26
- ScreenCaptureKit, AVAudioEngine, SpeechAnalyzer, CoreAudio
- Claude Code CLI (streaming JSON, hooks) and the Anthropic Messages API (SSE)
- Network.framework, EventKit, CoreLocation, Vision, CoreWLAN, IOBluetooth, IOKit, SMAppService, Keychain

## Build

Requires macOS 13+ on Apple Silicon and the Xcode command-line tools. Meeting mode's speech engine and Liquid Glass need macOS 26.

```sh
./scripts/make-signing-cert.sh   # once: stable signing identity so permissions survive rebuilds
./scripts/make-app.sh            # builds build/Notch.app
open build/Notch.app
```

Features that need permissions (microphone, speech, screen recording, calendar) must run from `build/Notch.app`.

Checks: `NOTCH_SELFTEST=1 swift run Notch` runs the self-test; `NOTCH_SNAPSHOT=<dir> swift run Notch` renders every tab to PNG.

Meeting mode records other people. Ask everyone in the call for consent first.
