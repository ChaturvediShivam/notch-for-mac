# Notch privacy: what stays on the device, and for how long

This is the shared rule set for **Notch for Mac and Notch for Windows**. Both apps must behave the same.
It is the technical basis for the public privacy policy; have a lawyer review that policy before launch.

## Principles (DPDP 2023, GDPR, UK GDPR, CCPA/CPRA, LGPD)

One strict rule set for every country. These laws share the same core: collect only what's needed,
keep it only as long as needed, let the user see and erase it. We don't detect the user's country:
that would itself be collecting data.

- **Local only.** Everything below lives on the user's computer. We (the seller) receive none of it.
- **No audio is ever stored.** Speech is turned into text on the device; the audio is discarded.
- **AI answers** send short excerpts (the question, the last 8 minutes of transcript, the user's
  pasted context) to the AI provider the user chose (Claude, ChatGPT, Gemini, or Ollama on-device).
  That is the user's own account with that provider; the policy must say so.
- **Consent.** Meeting mode records other people. The app tells users to get consent first.

## Lifetimes

| Data | Lifetime | User can change |
|---|---|---|
| Meeting transcript + answers (not kept) | 24 hours | No |
| Kept meetings | Until deleted (default) | 30 / 90 / 365 days |
| Clipboard history | 7 days (pinned items stay) | 1 / 7 / 30 days |
| Alerts | 30 days | 7 / 30 / 90 days |
| Listen transcripts | 7 days | No |
| Screen-region screenshots (ask Claude) | 1 day | No |
| Troubleshooting log | 7 days, max 1 MB; store edition logs word counts, never speech | No |
| Web cache (artwork, lyrics, weather) | Max 20 MB, oldest evicted | No |
| Notes, meeting context box | Until the user deletes them (their own writing) | — |

Cleanup runs at launch and every hour.

## User rights

- **See / export:** Settings → "Open data folder" (plain Markdown and JSON files).
- **Erase:** Settings → "Delete all my data" (tap twice). Removes transcripts (kept too), clipboard,
  alerts, notes, shelf list, Listen, screenshots, logs, web cache and the meeting context.
  Settings and API keys stay (keys can be removed in Settings → Meeting answers).
- **Folder permissions:** the data folder is readable only by the user's account.

## Mac implementation

`Sources/Notch/Core/Retention.swift` (lifetimes, delete-all), `Paths.home` (0700 folder),
`MeetingService.redact` (log redaction), Settings → "Privacy · data on this Mac".
