# Drop Prompter

A personal macOS menu-bar tool: a translucent notes panel that slides down from the top of the screen
(like iTerm2's hotkey window). Paste talking points before a meeting, toggle it with a hotkey, and
optionally show a Google translation side by side.

## Features

- **⌃⌥Space** toggles the panel from any app, including full-screen apps and every Space. **Esc** hides it.
- Translucent blurred background with an opacity slider; the text itself stays fully opaque.
- Text is saved automatically and restored on next launch.
- Font size −/+, panel width/height in ⚙︎.
- **Translate** shows a live translation next to your text (Google Cloud Translation API, key in Keychain).
- **🌐** opens the text in translate.google.com, which needs no key.
- "Hide from screen sharing" is on by default (`NSWindow.sharingType = .none`). This is best effort: some
  capture paths on macOS 15+ ignore it, so check it with Teams/Zoom before relying on it.
- The panel takes keyboard focus without activating the app, so your meeting app stays frontmost.

## Build and run (macOS 13+, Xcode or Command Line Tools)

```bash
./scripts/bundle.sh
open build/DropPrompter.app
```

For development: `swift run` (or `open Package.swift` in Xcode).

To start it at login: System Settings → General → Login Items → **+** → `build/DropPrompter.app`.

## Google translation setup

1. In Google Cloud Console, enable the **Cloud Translation API** for a project with billing enabled
   (the first 500,000 characters per month are free).
2. Create an API key under APIs & Services → Credentials, and restrict it to the Cloud Translation API.
3. Paste it into ⚙︎ → Google Cloud Translation → **Save key**.

## Changing the hotkey

Edit `AppDelegate.swift`: `HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))`.
Key codes are the `kVK_*` constants in `Carbon.HIToolbox`; modifiers are `cmdKey`, `optionKey`,
`controlKey`, `shiftKey`.
