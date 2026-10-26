import SwiftUI

/// Shown inside the panel the first time it opens, and again from the ? button or the menu bar icon.
struct WelcomeView: View {
    let hotKeyLabel: String
    let onDone: () -> Void

    private struct Shortcut: Identifiable {
        let keys: String
        let action: String
        var id: String { keys }
    }

    private struct Tip: Identifiable {
        let icon: String
        let text: String
        var id: String { text }
    }

    private var shortcuts: [Shortcut] {
        [
            (hotKeyLabel, "Show or hide the panel, from any app"),
            ("Esc", "Hide the panel"),
            ("⌘T", "New notes card"),
            ("⇧⌘T", "New terminal card"),
            ("⌘1 … ⌘9", "Switch between cards"),
            ("⌘P", "Open a file from the terminal's git repository"),
            ("⌘B", "Show or hide the repository sidebar"),
            ("⌘S", "Save the file in a file card"),
            ("⌘V  ⌘C  ⌘Z", "Paste, copy, undo"),
        ].map { Shortcut(keys: $0.0, action: $0.1) }
    }

    private let tips: [Tip] = [
        ("rectangle.stack", "Cards: keep a note per meeting or topic. + adds one, × closes it. "
            + "Double-click a card (or right-click › Rename) to give it your own name."),
        ("character.bubble", "Translate: shows a translation next to your text, on-device with Apple Translation."),
        ("apple.terminal", "Terminal cards run your shell inside the panel. Their tab shows the title the running "
            + "program sets, such as Claude Code or Copilot CLI status, and a dot when there's new output."),
        ("arrow.triangle.branch", "In a git repository, a terminal card shows the branch and changes. Pin the "
            + "sidebar (⌘B) left or right to browse changes and files. Edit files in place (⌘S saves) or view their "
            + "diff, and open them in your editor with one click."),
        ("circle.lefthalf.filled", "The slider changes how see-through the background is."),
        ("paintpalette", "Themes: Dark, Light or Paper (a warm, yellowish tone) from the palette button or ⚙︎."),
        ("arrow.up.left.and.arrow.down.right", "Drag the bottom grip or corner to resize the panel."),
        ("gearshape", "Settings: change the shortcut, launch at login, panel size, hide from screen sharing."),
        ("square.and.arrow.down", "Everything is saved automatically, also across restarts."),
    ].map { Tip(icon: $0.0, text: $0.1) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Drop Prompter")
                        .font(.title2.bold())
                    Text("A see-through notes panel that drops down from the top of your screen. "
                        + "Paste your talking points before a meeting and glance at them while you speak, "
                        + "optionally with a live translation next to them.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Keyboard shortcuts").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        ForEach(shortcuts) { shortcut in
                            GridRow {
                                Text(shortcut.keys)
                                    .font(.system(.body, design: .monospaced).weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.1)))
                                Text(shortcut.action)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Good to know").font(.headline)
                    ForEach(tips) { tip in
                        Label(tip.text, systemImage: tip.icon)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Before relying on \"Hide from screen sharing\" in a meeting, check it once with your meeting app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Open this again with ? in the toolbar or from the menu bar icon.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Get Started", action: onDone)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.ultraThickMaterial)
    }
}
