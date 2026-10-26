# Drop Prompter

A personal macOS menu-bar tool: a translucent notes panel that slides down from the top of the screen
(like iTerm2's hotkey window). Paste talking points before a meeting, toggle it with a hotkey, and
optionally show an on-device translation side by side. Terminal cards run your shell right inside the panel.

## Features

- A welcome screen explains the app and its shortcuts the first time the panel opens. Open it again with **?**
  in the toolbar or **Welcome & Shortcuts** in the menu bar icon.
- **⌃Space** (configurable) toggles the panel from any app, including full-screen apps and every Space.
  **Esc** hides it.
- Translucent blurred background with an opacity slider; the text itself stays fully opaque.
- **Cards**: keep several notes side by side as tabs. **+** (⌘T) adds a notes card, **⌘1…⌘9** switches, **×** closes
  (it asks first if the card has text). A card's tab shows its first line, or the name you give it: double-click
  the tab, or right-click › Rename (an empty name goes back to the automatic title). Everything is saved
  automatically.
- **Terminal cards** (⇧⌘T, or the terminal button next to **+**) run your login shell inside the panel, starting in
  your home folder. Each card has its own shell, which keeps running while the panel is hidden or another card is
  shown.
  - The tab shows the title the running program sets, so tools like Claude Code or Copilot CLI can show their
    status and progress there. A name you give the card takes precedence.
  - A dot on the tab means new output arrived while the card wasn't on screen.
  - Closing a terminal card asks first and names the program that would be stopped (for example `claude`).
    Quitting the app does the same while anything is still running.
  - Shells don't survive quitting the app or a restart; the cards do, and start a fresh shell.
  - Esc goes to the terminal (for vim and others) instead of hiding the panel; use the shortcut to hide it.
- **Resize** by dragging the grip in the middle of the bottom edge (height) or the bottom-right corner (width and
  height).
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

To start it at login, turn on ⚙︎ › **Launch at login**. At login it starts hidden in the menu bar; press ⌃Space to
bring the panel down. Cards and settings are saved automatically, so everything is back after a restart.

## Translation languages

The first time you translate a language pair, macOS asks to download it. Downloaded languages are managed in
System Settings › General › Language & Region › Translation Languages. Apple's Translation supports fewer
languages than Google Translate; the toolbar lists a subset that it supports.

## Changing the shortcut

Pick another show/hide shortcut in ⚙︎ › Shortcut (⌃Space, ⌃⇧Space, ⌃⌥Space, ⌃\` or ⌥\`). The app checks whether
the combination is free:

- **Used by another app**: it can't be registered; pick another one.
- **Also a macOS shortcut**: macOS takes it first and the app never sees it. ⌃Space is "Select the previous input
  source" by default. Turn it off in System Settings › Keyboard › Keyboard Shortcuts › Input Sources, or pick
  another shortcut. A banner in the panel tells you when this applies.

## License

Open source under the [MIT License](LICENSE). Copyright (c) 2026 dineshvg.

You are free to use, copy, modify, merge, publish, distribute, sublicense and sell this software, in private
or commercial projects, as long as the copyright notice and license text are kept.

## Disclaimer

This is a personal tool, provided **as is, without warranty of any kind**. The author accepts no liability for
any damage, data loss or other issues arising from its use. In particular, "Hide from screen sharing" is best
effort and is not guaranteed to keep the panel out of every recording or screen share. Use at your own risk.
