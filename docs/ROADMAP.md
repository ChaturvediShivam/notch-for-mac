# Roadmap

Automated check: `NOTCH_SELFTEST=1 swift run Notch` (parsers). Layout smoke test without screen permission:
`NOTCH_SNAPSHOT=/tmp/snap swift run Notch` renders every tab to PNG. `NOTCH_OPEN=<tab>` opens a tab at launch.

- [x] M1 Window: pill hugging the notch, spring open/close, hover model, capture exclusion, tab strip
  - Test by hand: closed pill invisible on the camera housing; hover grows it, opens after ~90 ms, closes ~350 ms after leaving; 18 px ears count as hover; quick flicks across don't open; menu bar clicks beside it pass through; tab clicks + trackpad swipe / mouse wheel (over the tab strip) slide the right way; hidden in screenshots, QuickTime and Zoom/Meet share (shown with NOTCH_VISIBLE=1); visible on every Space and over full-screen apps; plugging in/out an external display moves it (pill on non-notch screens); second launch exits; right-click → Quit and the power button quit
- [x] M2 Global hotkeys (Carbon RegisterEventHotKey, Ctrl+Option) + Palette (apps, files via NSMetadataQuery, calculator, web search, URLs, short commands) + Apps tab
  - Hotkeys: ⌃⌥Space palette · ⌃⌥N open/close · ⌃⌥C Claude · ⌃⌥S ask about screen · ⌃⌥D dictate · ⌃⌥L listen · ⌃⌥V clipboard · ⌃⌥P play/pause. Taken ones show red in Settings → Hotkeys.
  - Test by hand: each hotkey from another app; palette takes typing, ↑/↓/Enter/Esc work, focus returns to the previous app after Esc; `2+3*4`, `apple.com`, `timer 10`, an app name, a file name, "lock"; Apps tab pin/unpin (right-click), click a running app to switch to it
- [x] M3 Media: MediaRemote is blocked for third-party apps on macOS 15.4+, so a small dylib (`Sources/NotchMediaRemote`) is loaded into `/usr/bin/perl`, which MediaRemote still trusts, and streams JSON lines. Now Playing, controls, seek, artwork, synced lyrics (lrclib.net), output picker; live activity (art + equaliser) in the pill
  - Test by hand: Music, Spotify, YouTube in a browser; play/pause/next/prev; drag the progress bar; lyrics follow the song and a tap seeks; output menu switches device; pill shows art while playing
- [x] M4 Home tiles + Audio tab: volume/mute/output/input (CoreAudio), brightness (DisplayServices), Wi-Fi (CoreWLAN), Bluetooth (IOBluetooth), dark mode, Night Shift (CoreBrightness), keep awake (IOPMAssertion), Low Power Mode (pmset, asks for admin password); volume HUD in the pill
  - Test by hand: every tile flips the real setting and the state survives a re-open; dark mode asks for Automation once; volume keys show the HUD in the closed pill; brightness slider; switching output/input devices
- [x] M5 Claude tab with a one-click backend switch (tab top + Settings): Claude Code (default; `claude -p --output-format stream-json`, uses your Claude Code login, follow-ups `--resume` the session; attachments passed as file paths) or the API (key in Keychain, streaming, attachments as content blocks) + local API on 127.0.0.1:51515 (token in ~/.notch/token) + Agents (Claude Code PreToolUse approvals via hooks) + AI usage (local ~/.claude logs) + Alerts via /notify
  - Test by hand: Claude Code mode chat (no key), switch to API, add key, chat, switch back (starts a new chat), a follow-up remembers context, "New chat" starts fresh, attach an image/PDF/text file, drag a file in, ⌃⌥S region → answer; Agents → Install hooks, run Claude Code, approve/deny a Bash command from the notch, "Ask in terminal", Stop/Notification hooks land in Alerts; `curl` example from the Alerts tab
- [x] M6 Voice: Dictate (mic → Apple Speech, on-device when available → pasted) then Listen (ScreenCaptureKit system audio → live captions, transcript saved to ~/.notch/transcripts). Uses Apple's Speech framework instead of a whisper.cpp/MLX sidecar (no dependency, no model download).
  - Test by hand: ⌃⌥D asks Mic + Speech once, words appear in the pill, stop pastes (with Accessibility) or copies; ⌃⌥L asks Screen Recording, captions a YouTube video, runs past one minute
- [x] M6b Meeting mode (tab + ⌃⌥M), works only while it's on: other people (system audio, ScreenCaptureKit) and you (mic) transcribed at once as Them / Me, on speakers or earphones (Apple voice processing for echo + a text filter that drops "Me" lines repeating "Them"). Languages: Hindi + English (Hinglish, en-IN recogniser, best for mixed speech), Hindi only, English US/UK. **Auto answers**: when "Them" asks a question (English/Hinglish/Hindi cues, see `MeetingService.isQuestion`), Claude suggests a reply within seconds, no click; notch pops open on the Meeting tab. Samjhao (⌃⌥E), typed questions and Summary use the same fast one-shot runner (`ClaudeRunner`: Claude Code without user settings/hooks/MCP/tools, or the API at low effort). Transcript saved to ~/.notch/transcripts/Meeting <date>.md; step log in ~/.notch/meeting.log; Them/Me level meters.
  - Speech engine: macOS 26's SpeechAnalyzer (`AnalyzerTranscriber`, SpeechTranscriber for English/Hinglish, DictationTranscriber for Hindi, model downloaded on first use). The old SFSpeechRecognizer (`Transcriber`, fallback for macOS 13–15) can't run two on-device streams at once, so Them + Me returned nothing; SpeechAnalyzer runs both (checked with `NOTCH_TEST_PARALLEL=2`). Questions are answered as soon as the question text holds still for 0.7 s, without waiting for the line to finalise.
  - Automated: `NOTCH_SELFTEST=1` covers question detection; `open -n --env NOTCH_TEST_AUDIO=<file> build/Notch.app` transcribes a file (checked en-IN vs hi-IN on Hinglish: en-IN keeps English words, hi-IN drops them); Claude Code one-shot measured at ~1.6 s to first words.
  - Test by hand: first Start asks Speech, Microphone, Screen Recording (turn on, reopen Notch); on speakers your voice shows as Me and the call doesn't duplicate into Me; a question from the other side gets an answer card by itself; Auto toggle off stops that; nothing listens when Meeting mode is off
- [x] M7 Today (Open-Meteo weather by city or opt-in location + EventKit calendar), Markets (Yahoo chart API), Scores (ESPN scoreboard), Stats, Notes, Timer, Shelf (drag in/out, AirDrop, Vision OCR), Clipboard, Tools, Mirror
  - Test by hand: set a city; "Show calendar" prompt; watchlist/leagues edits in Settings; drag a file onto the closed notch opens Shelf; drag out of Shelf into Finder/Mail; OCR an image; timer finishes with sound + alert + pill countdown; clipboard skips 1Password items; Mirror asks for the camera and turns the light off when you leave the tab
- [x] M8 Settings (privacy switch per network feature, permissions, hotkeys), login item (SMAppService), keep-alive (launchd agent, restarts only after a crash), app icon, signing/notarisation in `make-app.sh` (needs `SIGN_ID` + `NOTARY_PROFILE`)
  - Not done: Sparkle updates (third-party dependency, needs approval and a feed URL); notarisation needs a Developer ID certificate
  - Test by hand: Open at login survives a reboot; kill -9 Notch with keep-alive on and it comes back; Quit does not come back
- [x] M9 Meeting mode, round two: answer cards for your own questions too (strong answer + follow-up); live transcript kept off screen; Topic box and "read misheard words in context" prompt; "Unclear" instead of guessing; repeat questions skipped; 2-word questions with "?"; statements ending in "." ignored; wait 0.7 s with "?" else 1.5 s and re-answer a grown question; live text batched to ~3 updates/s (WindowServer 43% → 12%); silent start; timings in the meeting log; sessions deleted after 24 h unless kept; auto start/stop with call apps (`CallWatch`, CoreAudio per-process input flag); `/meeting/toggle` on the local API
  - Test by hand: a real Zoom/Meet call starts and stops Meeting mode by itself; Stop mid-call isn't undone; your own question gets a green card; Keep survives a day

## M10 · Context box and bring-your-own AI
- [x] Multi-line Context box (paste resume / JD / agenda, or load .txt/.md/.pdf), capped at 20k chars in prompts
- [x] Meeting answers from Claude, ChatGPT, Gemini, Ollama or any OpenAI-compatible API (keys in Keychain)
- [x] Subscription CLIs: Codex (`codex exec`, read-only, ephemeral) and Gemini CLI (`gemini -p`)
- [x] Tested: Codex flags/stdin/stderr drain with a stub; Ollama gemma4 answers in 0.7 s; missing key shows a clear setup message
- Test by hand: Settings → Meeting answers menu and key Save/Remove; "From file…" with a PDF resume; a real ChatGPT/Gemini key; a real Codex and Gemini CLI login

## M11 · Looks and editions
- [x] Skins: Classic, Aurora, Sunset, Graphite, Neon; Captain (master only). Accent, colour wash, edge glow, one-shot glint on open, hover glow
- [x] Settings → Look: theme swatches, glow, glass, transparency, hide tabs (store edition keeps Home, Meeting, Media, Settings)
- [x] Editions: store by default; master with MASTER=1 or ~/.notch/master (custom hex colours, hide any tab)
- [x] CPU with the themed notch open: WindowServer ~12%, Notch ~2% (same as before)
- Test by hand: each theme with glass on/off; hiding tabs and scroll-switching; the glint on open

## M12 · Full test and security pass (2026-11-17)
Fixed:
- [x] Local API crash: a negative Content-Length crashed the app before the token check (any local process)
- [x] Palette crash: thousands of "(" or "-" overflowed the calculator's stack (input capped at 200 chars)
- [x] Token compared in constant time; ~/.notch now owner-only (0700): transcripts, clipboard, token
- [x] Store edition logs keep only word counts, so speech never outlives the 24 h transcript
- [x] /notify rejects non-JSON (400) and caps title/body length
- [x] Unreadable config.json is backed up to config.json.broken before defaults replace it
- [x] Claude Code hook path quoted (home folders with spaces)
- [x] Mic/Speech permission texts mention Meeting mode; locked tabs show their icon
Verified:
- [x] Self-test with 3,000 random junk inputs per parser, junk config, editions (store and master)
- [x] API: no/wrong token 401, CORS preflight refused, not reachable from LAN, 9 MB body dropped, 300 hanging connections, still serves
- [x] End-to-end meeting with spoken questions: exact transcript, first words 1.9–2.3 s, correct answers
- [x] 5 start/stop cycles: memory steady at ~81 MB; single instance; hidden from screenshots; idle CPU ~1.5%
- [x] Git history: no keys or private emails
Before selling (needs you):
- [ ] Developer ID signing + notarisation (scripts/make-app.sh supports SIGN_ID and NOTARY_PROFILE)
- [ ] Keep master-only code out of the public repo or ship only store binaries
- [ ] Test by hand: real Zoom/Meet auto start, hotkeys, Codex/Gemini CLI with real logins

## M13 · Data lifetimes and erase (DPDP / GDPR)
- [x] Retention: clipboard 7 d, alerts 30 d, Listen 7 d, screenshots 1 d, log 7 d, kept meetings optional limit; runs at launch + hourly
- [x] Settings → "Privacy · data on this Mac": lifetimes, Open data folder, Delete all my data (tap twice)
- [x] Entitlements for hardened runtime (mic, camera, Apple Events, calendar, location); tested with a hardened build
- [x] Tested: planted old files/log lines/alerts were removed, new ones kept; delete-all left only settings, token, hooks
- [x] Shared rule set for Mac + Windows in docs/PRIVACY.md
