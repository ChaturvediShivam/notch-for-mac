# Notch for Mac

**Turn the MacBook notch into a Dynamic Island, with a live AI meeting assistant that hears both sides of a call and suggests what to say in about 3 seconds.**

Native Swift · macOS 13+ · Apple Silicon · zero third-party dependencies · ~6,900 lines

![Notch open](docs/screenshots/notch-open.png)

## Highlights

- **Real-time bilingual meeting transcription & notes.** Transcribes the other side (Mac audio) and you (mic) at the same time, in English, Hindi or Hinglish, fully on-device.
- **Answer cards for both sides.** They ask a question → a short, natural reply you can say. You ask a question → what a strong answer contains, plus a follow-up question. No clicks.
- **Your AI, your credits.** Use the subscription you already pay for (Claude Code, Codex, Gemini CLI) or an API key: Claude, ChatGPT, Gemini, Ollama (free, local) or any OpenAI-compatible API. No per-minute credits.
- **Starts and stops with your calls.** Zoom, Google Meet, Teams, FaceTime, WhatsApp, Slack and more are detected from their microphone use.
- **Private by default.** Speech recognition runs on the Mac, the notch is hidden from screen share and screenshots, transcripts delete themselves after 24 hours unless you keep them, and every network feature has its own switch.
- **20 tabs** of everyday tools: Claude chat, media with synced lyrics, system controls, clipboard, file shelf, calendar, weather and more.

| | |
|---|---|
| ![Meeting mode](docs/screenshots/meeting.png) | ![Claude](docs/screenshots/claude.png) |
| ![Media](docs/screenshots/media.png) | ![Home](docs/screenshots/home.png) |

## Meeting mode

| Feature | How it works |
|---|---|
| Two-sided transcript | ScreenCaptureKit captures the call audio ("Them"); the mic with Apple's echo cancellation captures you ("Me"); two SpeechAnalyzer streams run in parallel |
| Languages | Hinglish (best for mixed talk), Hindi, English US/UK; Hindi is shown in Roman letters |
| Question detection | English and Hinglish cues (`?`, what/how/can…, kya/kaise/kab…); waits 0.7 s with a "?" or 1.5 s without, re-answers a question that kept growing, skips repeats |
| Answer cards | Claude gets the question, the meeting topic and the last 8 minutes; garbled questions get "Unclear — ask them to repeat" instead of a guess |
| Context box | Paste anything (a topic, your resume, the job description, an agenda) or load a .txt/.md/.pdf: answers use it as facts about you, never invent experience, and fix misheard words ("structured cat deposit" → structured cash deposit) |
| Bring your own AI | Subscription logins: Claude Code, Codex CLI (ChatGPT plan), Gemini CLI. Or API keys: Claude, ChatGPT, Gemini, Ollama on the Mac (free, offline) or any OpenAI-compatible API: you pay with credits you already have, no app credits |
| Samjhao (⌃⌥E) and Summary | Explain the last few minutes in simple words, or summarise decisions and action items |
| Auto start/stop | Starts 5 s after a call app opens the mic, stops 15 s after the call; a manual Stop is respected |
| Saved sessions | Transcript + answers saved as Markdown on Stop; deleted after 24 h unless you press Keep |
| Clean screen | The live transcript stays off screen (it's still used as context and saved), so the notch only shows answers |

**Measured on a MacBook Air:** speech to text ~1–1.5 s · first words of an answer ~2.7–3.2 s after the question ends · Notch ~26% CPU during a meeting with the notch open.

> Meeting mode records other people. Ask everyone in the call for consent first.

## All tabs

| Tab | What it does |
|---|---|
| Meeting | Everything above |
| Claude | Chat with Claude via the Claude Code CLI (your login) or the Anthropic API, one-click switch; attach files; ask about a screen region |
| Agents | Approve or deny Claude Code tool calls from the notch (via hooks) |
| AI usage | Claude Code token use by day, by model and in the current 5-hour window |
| Alerts | Notifications from scripts and Claude Code through the local API |
| Home / Audio | Volume, brightness, Wi-Fi, Bluetooth, dark mode, Night Shift, keep awake; output switches to earphones when plugged in |
| Media | Now Playing, controls, seek, artwork, synced lyrics |
| Palette | Apps, files, calculator, links, web search, timers, system commands |
| Today / Markets / Scores | Weather and calendar, stock watchlist, live scores |
| Shelf / Clipboard / Notes / Timer | File shelf with AirDrop and OCR, clipboard history, notes, timers in the pill |
| Tools | Dictate (stops on silence) and live captions of the Mac's audio |
| Stats / Mirror / Apps | System stats, camera mirror, pinned and running apps |
| Settings | Privacy switches, permissions, hotkeys, Liquid Glass and transparency, open at login, restart after a crash |

## Shortcuts

| Keys | Action |
|---|---|
| ⌃⌥ Space | Palette |
| ⌃⌥ N | Open / close the notch |
| ⌃⌥ M | Meeting mode start / stop |
| ⌃⌥ E | Samjhao: explain what was just said |
| ⌃⌥ C / ⌃⌥ S | Ask Claude / ask about a screen region |
| ⌃⌥ D / ⌃⌥ L | Dictate / live captions |
| ⌃⌥ V / ⌃⌥ P | Clipboard / play-pause |

## Architecture

| Layer | What it does | Key detail |
|---|---|---|
| Window (`NSPanel`) | Floating, non-activating panel over the notch on every Space | Excluded from capture; takes keyboard focus only while typing |
| Controller | Hover model, gestures, global hotkeys | 90 ms hover dwell, 350 ms hold; swipe or scroll switches tabs |
| SwiftUI views | Closed pill with live activities; open panel with 20 tabs | Spring animations inside a fixed-size window |
| Services | One `@MainActor` singleton per feature | System, network and disk work runs async off the main thread |
| Local API | HTTP on 127.0.0.1:51515, token in `~/.notch/token` | `/notify`, `/meeting/toggle`, Claude Code hooks |
| Media bridge | Objective-C dylib loaded into `/usr/bin/perl` | Reads Now Playing, which macOS 15.4+ blocks for third-party apps |
| Data | `~/.notch/` config, transcripts, logs; secrets in Keychain | Nothing leaves the Mac unless its network switch is on |

```sh
# Send a notification or toggle Meeting mode from any script
curl -X POST http://127.0.0.1:51515/notify -H "X-Notch-Token: $(cat ~/.notch/token)" -d '{"title":"Build done"}'
curl -X POST http://127.0.0.1:51515/meeting/toggle -H "X-Notch-Token: $(cat ~/.notch/token)"
```

## Hard problems solved

| Problem | Cause | Fix |
|---|---|---|
| Now Playing stopped working | macOS 15.4+ blocks MediaRemote for third-party apps | Objective-C dylib loaded into a trusted system binary, streaming JSON lines |
| Two speech streams returned nothing | The old on-device recogniser runs one task at a time | Moved to macOS 26 SpeechAnalyzer; two parallel streams |
| Mic gave no text | The echo-cancelling mic delivers 5–7 channels | Convert channel 0 to mono in the audio tap |
| Mac got warm in meetings | Every partial word redrew the open notch | Batched live text to ~3 updates a second: WindowServer 43% → 12%, Notch 40% → 26% |
| Wrong answers | Misheard words and no subject context | Topic box, "read misheard words in context", "Unclear" instead of guessing |
| Answers to half-questions | Triggering before the speaker finished | Longer wait without "?", re-answer when the question grows, ignore statements |
| Detecting calls without a permission | No public "call started" event | CoreAudio's per-process "is running input" flag, polled every 3 s |
| Permissions reset on every build | Ad-hoc signing changes the code identity | Stable self-signed identity (`scripts/make-signing-cert.sh`) |
| Sound stayed on speakers with wired earphones | macOS kept the old default output | CoreAudio listener switches output on plug-in |

## Build and run

Requires macOS 13+ on Apple Silicon and the Xcode command-line tools. Meeting mode's speech engine and Liquid Glass need **macOS 26**. Meeting answers need [Claude Code](https://claude.com/claude-code) signed in, or an Anthropic API key.

```sh
git clone https://github.com/ChaturvediShivam/notch-for-mac.git
cd notch-for-mac
./scripts/make-signing-cert.sh   # once: stable signing identity so permissions survive rebuilds
./scripts/make-app.sh            # builds build/Notch.app
open build/Notch.app
```

On first use macOS asks for Microphone, Speech Recognition and Screen & System Audio Recording (for the call audio). Features that need permissions must run from `build/Notch.app`, not `swift run`.

**Checks:** `NOTCH_SELFTEST=1 swift run Notch` runs the self-test · `NOTCH_SNAPSHOT=<dir> swift run Notch` renders every tab to PNG · `~/.notch/meeting.log` records each meeting step with timings.

## Tech stack

Swift 6 (strict concurrency) · SwiftUI in AppKit · ScreenCaptureKit · AVAudioEngine · SpeechAnalyzer · CoreAudio · Network.framework · EventKit · Vision · CoreWLAN · IOBluetooth · IOKit · SMAppService · Keychain · Claude Code CLI and the Anthropic Messages API · Objective-C bridge · Swift Package Manager (no Xcode project)
