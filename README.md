# Drop Prompter

A personal macOS menu-bar tool: a translucent notes panel that slides down from the top of the screen
(like iTerm2's hotkey window). Paste talking points before a meeting, toggle it with a hotkey, and
optionally show an on-device translation side by side.

## Features

- **⌃Space** toggles the panel from any app, including full-screen apps and every Space. **Esc** hides it.
- Translucent blurred background with an opacity slider; the text itself stays fully opaque.
- **Cards**: keep several notes side by side as tabs. **+** (⌘T) adds a card, **⌘1…⌘9** switches, **×** closes
  (it asks first if the card has text). Each card's tab shows its first line. Everything is saved automatically.
- **Resize** by dragging the grip at the bottom edge (height) or the bottom-right corner (width and height).
  The panel stays centered under the menu bar and remembers its size.
- Font size −/+, panel width/height in ⚙︎.
- **Translate** shows a live translation next to your text, line by line, using Apple's on-device
  Translation framework: free, no account, and the text never leaves your Mac. Pick the source language
  (or auto-detect) and the target language in the toolbar.
- **🌐** opens the text in translate.google.com instead (this one does send the text to Google).
- "Hide from screen sharing" is on by default (`NSWindow.sharingType = .none`). This is best effort: some
  capture paths on macOS 15+ ignore it, so check it with Teams/Zoom before relying on it.
- The panel takes keyboard focus without activating the app, so your meeting app stays frontmost.

## Build and run (macOS 15+, Xcode 16+ or matching Command Line Tools)

```bash
./scripts/install.sh   # builds, moves the app to /Applications and starts it
```

After that, start it like any other app (Spotlight, Launchpad, Finder). Opening it while it's already running
brings the panel down. To only build without installing: `./scripts/bundle.sh` (output in `build/`).

For development: `swift run` (or `open Package.swift` in Xcode).

To start it at login: System Settings → General → Login Items → **+** → `/Applications/DropPrompter.app`.

## Translation languages

The first time you translate a language pair, macOS asks to download it. Downloaded languages are managed in
System Settings › General › Language & Region › Translation Languages. Apple's Translation supports fewer
languages than Google Translate; the toolbar lists a subset that it supports.

## Changing the hotkey

⌃Space is also the macOS default for "Select the previous input source". If you use more than one keyboard
layout, turn that off in System Settings › Keyboard › Keyboard Shortcuts › Input Sources, or pick another key.

Edit `AppDelegate.swift`: `HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey))`.
Key codes are the `kVK_*` constants in `Carbon.HIToolbox`; modifiers are `cmdKey`, `optionKey`,
`controlKey`, `shiftKey`.

## License

Open source under the [MIT License](LICENSE). Copyright (c) 2026 dineshvg.

You are free to use, copy, modify, merge, publish, distribute, sublicense and sell this software, in private
or commercial projects, as long as the copyright notice and license text are kept.

## Disclaimer

This is a personal tool, provided **as is, without warranty of any kind**. The author accepts no liability for
any damage, data loss or other issues arising from its use. In particular, "Hide from screen sharing" is best
effort and is not guaranteed to keep the panel out of every recording or screen share. Use at your own risk.
