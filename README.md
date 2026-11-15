# Notch for Mac

Native Swift rewrite of the Windows Notch (see the build report). Milestone 1: the window.

## Run

    cd notch-mac
    swift run                      # debug run from Terminal (Ctrl+C to stop)
    ./scripts/make-app.sh          # builds build/Notch.app
    open build/Notch.app

Quit: power button in the open panel, or right-click the pill > Quit Notch.
`NOTCH_VISIBLE=1 swift run` makes it visible to screen sharing (for demos).

## Milestone 1 checklist

- [ ] Hugs the hardware notch on the MacBook screen (invisible when idle)
- [ ] Hover: grows slightly; after 90 ms opens with a spring into the 680 x 340 panel
- [ ] Leave: closes 350 ms later; moving back in quickly cancels the close
- [ ] Clicks outside the pill go to the app underneath
- [ ] Two-finger horizontal swipe / mouse wheel switches tabs, slide direction is correct
- [ ] No Dock icon, does not steal focus from the app you are typing in
- [ ] Shows on every Space and over full-screen apps
- [ ] Hidden in Zoom / Meet / QuickTime screen recording (test it!)
- [ ] Second launch does nothing (single instance)
