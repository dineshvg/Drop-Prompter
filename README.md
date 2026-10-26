# Drop Prompter

**Your talking points, one keystroke away: in every meeting, on top of every app.**

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-SwiftUI%20%2B%20AppKit-orange?logo=swift)
![License: MIT](https://img.shields.io/badge/License-MIT-blue)

Drop Prompter is a small, native macOS app that slides a translucent notes panel down from the top of your
screen, like iTerm2's hotkey window, but for what you want to *say*. Press **⌃Space** in any app and your notes
appear. Press it again and they're gone. Your meeting app stays in front the whole time.

Keep a card per meeting, read a live translation next to your notes, and run Claude Code, Copilot CLI or any
other command in a terminal card without switching windows.

<!-- Screenshots: docs/screenshots/*.png, added once captured. -->

## Why Drop Prompter

- **Always within reach.** One global shortcut, from any app, over full-screen apps and on every Space.
  There's no window to find, and it's gone again just as fast.
- **Doesn't get in the way.** The panel takes your typing without stealing focus from Teams, Zoom or your IDE.
  The background is see-through, so you can still see what's behind it.
- **Speak in another language with confidence.** Write your points in one language and read them in another,
  side by side. Translation runs on-device with Apple's Translation framework: free, no account, and your text
  never leaves your Mac.
- **More than notes.** Terminal cards run your shell right in the panel. Each card's tab shows the live status
  that tools like Claude Code and Copilot CLI write to the terminal title.
- **Native, small and private.** Swift, SwiftUI and AppKit, no Electron. No account, no analytics, no
  telemetry. Everything stays on your Mac.

## Features

### Notes that drop down
- **⌃Space** (configurable) shows and hides the panel from any app; **Esc** hides it too.
- **Cards** keep separate notes as tabs, for example one per meeting, talk or topic. **⌘T** adds one,
  **⌘1…⌘9** switches. Double-click a tab to rename it; otherwise it shows the card's first line.
- Everything is saved as you type and comes back after a restart.
- A larger or smaller font, adjustable background opacity, and a panel you can **resize** by dragging its bottom
  edge or corner. It stays centered under the menu bar.

### Live translation
- Turn on **Translate** to see a translation next to your notes, updated as you type and kept line by line so
  your structure stays intact.
- Choose the source language (or auto-detect) and the target language: German, English, French, Spanish,
  Italian, Dutch, Polish, Turkish, Portuguese, Hindi, Japanese and Chinese.
- Runs fully on-device. The 🌐 button can also open the text in Google Translate if you prefer it (that one does
  send the text to Google).

### Terminal cards
- **⇧⌘T** opens a terminal card with your own login shell, profile, aliases and tools.
- Each card has its own shell, which keeps running while the panel is hidden or you're on another card.
- The tab shows the title the running program sets, so you can follow Claude Code or Copilot CLI progress at a
  glance. A dot tells you a background card has new output.
- Closing a card or quitting the app asks first and names what would be stopped, for example
  *"Close terminal while “claude” is running?"*

### See what your agent changed
When a terminal card's shell is inside a git repository, Drop Prompter notices and shows a slim repo bar: the
branch and how many files changed, updated as commands run. It's built for watching Claude Code or Copilot CLI
work without switching to your IDE.
- **Changes (⇧⌘G)** lists `git status` next to the terminal. Click a file to see its diff, colored and read-only.
- **Quick Open (⌘P)**: type part of a file name and open the file as a viewer card next to your notes.
- **Open in your editor**: one click hands a file or the whole repository to VS Code, Android Studio, Xcode or
  your default app (choose in ⚙︎ › Code).
- Strictly read-only: Drop Prompter never changes your files, and it runs git without taking locks, so it can't
  get in the way of git commands running in the terminal.

### Make it yours
- **Themes:** Dark, Light, and Paper, a warm, yellowish tone that's easy on the eyes. Terminal cards follow
  the theme.
- **Hide from screen sharing** (on by default) keeps the panel out of most screen shares and recordings. It's
  best effort; see [Tips](#tips-and-troubleshooting).
- **Launch at login**, quietly in the menu bar until you need it.
- A short **welcome screen** explains the basics on first launch; open it again any time with **?**.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| **⌃Space** | Show or hide the panel, from any app (configurable in ⚙︎) |
| **Esc** | Hide the panel (in a terminal card, Esc goes to the terminal) |
| **⌘T** | New notes card |
| **⇧⌘T** | New terminal card |
| **⌘1 … ⌘9** | Switch to card 1 … 9 |
| **⌘P** | Open a file from the terminal card's git repository |
| **⇧⌘G** | Show or hide the repository's changes and diffs |
| **⌘C ⌘V ⌘Z** | Copy, paste, undo |
| Double-click a tab | Rename the card |

## Install

Requirements: macOS 15 or later and Xcode 16+ (or matching Command Line Tools).

```bash
git clone https://github.com/dineshvg/Drop-Prompter.git
cd Drop-Prompter
./scripts/install.sh
```

`install.sh` builds the app, moves it to `/Applications` and starts it. From then on, start it like any other
app from Spotlight, Launchpad or Finder, or turn on ⚙︎ › **Launch at login**. To update, run
`git pull && ./scripts/install.sh` again.

For development: `swift run`, or `open Package.swift` in Xcode. `./scripts/bundle.sh` builds the app into `build/`
without installing it.

## Privacy

- No account, no analytics, no network calls of its own.
- Notes and settings are stored locally in the app's preferences.
- Translation uses Apple's on-device Translation framework. The only feature that sends text anywhere is the 🌐
  button, which opens Google Translate in your browser.
- Terminal cards run your shell with your user's normal permissions, exactly like Terminal.app.
- The repository view only reads: it runs `git status`, `git diff` and `git ls-files` locally and never writes.

## Tips and troubleshooting

**The shortcut does nothing.** macOS uses ⌃Space for "Select the previous input source" by default and takes it
before any app sees it. Drop Prompter detects this and shows a banner. Either turn that shortcut off in System
Settings › Keyboard › Keyboard Shortcuts › Input Sources, or pick ⌃⇧Space, ⌃⌥Space, ⌃\` or ⌥\` in ⚙︎ › Shortcut.
The app also tells you when another app has already taken a combination.

**Is the panel really hidden in screen shares?** "Hide from screen sharing" uses `NSWindow.sharingType = .none`.
Some capture methods on recent macOS versions ignore it, so check it once with your meeting app before relying on
it.

**Translation asks to download a language.** That's macOS fetching the on-device model the first time you use a
language pair. Manage downloaded languages in System Settings › General › Language & Region › Translation
Languages.

**Terminal cards after a restart.** The cards come back, each with a fresh shell; running programs don't survive
quitting the app.

## Contributing

Issues and pull requests are welcome. The app is a small Swift package; the main pieces are:

| File | What it does |
|---|---|
| `AppDelegate.swift` | Panel, menu bar item, show/hide animation, shortcut, resizing |
| `ContentView.swift` | Toolbar, cards, editor, translation, settings |
| `Terminal.swift` | Terminal cards (built on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)) |
| `Repo.swift`, `RepoViews.swift` | Repository detection, changes, diffs, file viewer and Quick Open |
| `HotKey.swift` | Global shortcut and conflict detection |
| `Theme.swift` | Dark, Light and Paper themes |

## License

Open source under the [MIT License](LICENSE). Copyright (c) 2026 dineshvg.

You are free to use, copy, modify, merge, publish, distribute, sublicense and sell this software, in private
or commercial projects, as long as the copyright notice and license text are kept.

## Disclaimer

This is a personal tool, provided **as is, without warranty of any kind**. The author accepts no liability for
any damage, data loss or other issues arising from its use. In particular, "Hide from screen sharing" is best
effort and is not guaranteed to keep the panel out of every recording or screen share. Use at your own risk.
