import AppKit
import SwiftTerm
import SwiftUI

/// A terminal view that reports output, so cards in the background can show an activity dot.
final class ActivityTerminalView: LocalProcessTerminalView {
    var onOutput: () -> Void = {}

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput()
    }
}

/// One shell per terminal card. Sessions live as long as the app, so hiding the panel or switching
/// cards keeps them running.
@MainActor
final class TerminalSessions: ObservableObject {
    static let shared = TerminalSessions()

    /// Window title set by the running program (OSC 0/2), e.g. the status Claude Code or Copilot CLI shows.
    @Published private(set) var titles: [UUID: String] = [:]
    /// Terminal cards that printed output while they weren't on screen.
    @Published private(set) var unseenOutput: Set<UUID> = []
    /// The card currently on screen; its output never counts as unseen.
    var visibleCardID: UUID? {
        didSet {
            guard let visibleCardID else { return }
            unseenOutput.remove(visibleCardID)
            if sessions[visibleCardID] != nil { refreshRepo(of: visibleCardID, after: 0) }
        }
    }

    /// Git repository each terminal card's shell is in, if any.
    @Published private(set) var repos: [UUID: RepoStatus] = [:]

    private var sessions: [UUID: TerminalSession] = [:]
    private var repoRefreshes: [UUID: Task<Void, Never>] = [:]
    private(set) var theme: Theme = .dark

    func apply(_ theme: Theme) {
        self.theme = theme
        sessions.values.forEach { $0.apply(theme) }
    }

    func view(for cardID: UUID) -> ActivityTerminalView {
        if let session = sessions[cardID] { return session.view }
        let session = TerminalSession(cardID: cardID, owner: self)
        sessions[cardID] = session
        return session.view
    }

    /// Name of the program running in the foreground of a card's shell (e.g. "claude", "npm"),
    /// or nil when the shell is idle at its prompt.
    func runningProgram(in cardID: UUID) -> String? {
        guard let process = sessions[cardID]?.view.process, process.running, process.childfd >= 0 else { return nil }
        let foreground = tcgetpgrp(process.childfd)
        guard foreground > 0, foreground != process.shellPid else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        return proc_name(foreground, &name, UInt32(name.count)) > 0 ? String(cString: name) : "a program"
    }

    /// Programs still running in any terminal card, for the quit confirmation.
    var runningPrograms: [String] {
        sessions.keys.compactMap(runningProgram(in:))
    }

    func close(_ cardID: UUID) {
        sessions.removeValue(forKey: cardID)?.close()
        repoRefreshes.removeValue(forKey: cardID)?.cancel()
        titles[cardID] = nil
        repos[cardID] = nil
        unseenOutput.remove(cardID)
    }

    /// Re-reads the shell's directory and git status. While output streams in (an agent at work), this runs
    /// at most once per `delay`, so git isn't started for every chunk of output.
    func refreshRepo(of cardID: UUID, after delay: Double = 1) {
        guard repoRefreshes[cardID] == nil else { return }
        repoRefreshes[cardID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            defer { self.repoRefreshes[cardID] = nil }
            guard let shell = self.sessions[cardID]?.view.process?.shellPid,
                  let directory = ProcessDirectory.of(shell) else {
                self.repos[cardID] = nil
                return
            }
            let status = await Repo.status(at: directory)
            // The card may have been closed while git was running.
            guard self.sessions[cardID] != nil, self.repos[cardID] != status else { return }
            self.repos[cardID] = status
        }
    }

    fileprivate func titleChanged(_ cardID: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        titles[cardID] = trimmed.isEmpty ? nil : trimmed
    }

    fileprivate func outputArrived(_ cardID: UUID) {
        refreshRepo(of: cardID)
        guard cardID != visibleCardID, !unseenOutput.contains(cardID) else { return }
        unseenOutput.insert(cardID)
    }
}

@MainActor
private final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let cardID: UUID
    weak var owner: TerminalSessions?
    let view = ActivityTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
    private var isClosed = false

    init(cardID: UUID, owner: TerminalSessions) {
        self.cardID = cardID
        self.owner = owner
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        apply(owner.theme)
        // Keep ⌥ for typing characters such as @ { } [ ] on German and other layouts.
        view.optionAsMetaKey = false
        view.onOutput = { [weak self] in
            guard let self else { return }
            self.owner?.outputArrived(self.cardID)
        }
        startShell()
    }

    func apply(_ theme: Theme) {
        view.nativeForegroundColor = theme.terminalForeground
        view.nativeBackgroundColor = theme.terminalBackground
        view.backgroundOpacity = theme.terminalBackgroundOpacity
    }

    func close() {
        isClosed = true
        view.terminate()
    }

    private func startShell() {
        var environment = ProcessInfo.processInfo.environment
        let shell = environment["SHELL"] ?? "/bin/zsh"
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        // A leading "-" in argv[0] starts a login shell, which loads the user's profile like Terminal.app does.
        view.startProcess(
            executable: shell,
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: NSHomeDirectory()
        )
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { self.owner?.titleChanged(self.cardID, to: title) }
        }
    }

    /// `exit` starts a fresh shell instead of leaving a dead card; closing the card doesn't.
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                guard !self.isClosed else { return }
                self.view.feed(text: "\r\n[Shell exited. Starting a new one…]\r\n")
                self.startShell()
            }
        }
    }
}

struct TerminalPane: NSViewRepresentable {
    let sessions: TerminalSessions
    let cardID: UUID

    func makeNSView(context: Context) -> ActivityTerminalView {
        let view = sessions.view(for: cardID)
        // Type straight into the shell when the card is shown.
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: ActivityTerminalView, context: Context) {}
}
