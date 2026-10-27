import AppKit
import SwiftTerm
import SwiftUI

/// A terminal view that reports the bell, so a card can ask for attention.
final class ActivityTerminalView: LocalProcessTerminalView {
    /// Runs on the main thread when the program rings the terminal bell.
    var onBell: () -> Void = {}

    /// Called on SwiftTerm's parsing thread.
    override nonisolated func bell(source: SwiftTerm.Terminal) {
        super.bell(source: source)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onBell() }
        }
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
    /// Terminal cards that need the user, for example an agent asking a question. Cleared once the card is looked at.
    @Published private(set) var needsAttention: Set<UUID> = []
    /// Whether the user is looking at a card right now: the panel is in front with that card on screen.
    var isWatching: (UUID) -> Bool = { _ in false }
    /// Tells the user a card needs them (a notification); set by the app delegate.
    var onAttention: (_ cardID: UUID, _ message: String) -> Void = { _, _ in }
    /// The user looked at a card that needed them.
    var onAttentionCleared: (_ cardID: UUID) -> Void = { _ in }
    /// The card currently on screen; its output never counts as unseen.
    var visibleCardID: UUID? {
        didSet {
            guard let visibleCardID else { return }
            lookedAt(visibleCardID)
            unseenOutput.remove(visibleCardID)
            if sessions[visibleCardID] != nil { refreshRepo(of: visibleCardID, after: 0) }
        }
    }

    /// Git repository each terminal card's shell is in, if any.
    @Published private(set) var repos: [UUID: RepoStatus] = [:]

    private var sessions: [UUID: TerminalSession] = [:]
    private var lastOutput: [UUID: Date] = [:]
    private var quietChecks: [UUID: Task<Void, Never>] = [:]
    /// Relay that records model API calls of cards with Record Agent Traffic.
    let agentTraffic = AgentTraffic.shared
    private var repoRefreshes: [UUID: Task<Void, Never>] = [:]
    private(set) var theme: Theme = .dark
    private(set) var backgroundOpacity: Double = 0.75

    func apply(_ theme: Theme, backgroundOpacity: Double) {
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        sessions.values.forEach { $0.apply(theme, backgroundOpacity: backgroundOpacity) }
    }

    /// Commands to type into a card's shell once it starts (e.g. the sandbox log).
    private var pendingCommands: [UUID: String] = [:]

    init() {
        agentTraffic.identifyCaller = { [weak self] port in self?.caller(clientPort: port) }
    }

    /// The card's terminal; its shell starts on first use, inside `sandbox` when given, with its network calls
    /// going through Agent Traffic when `recordTraffic` is set.
    func view(for cardID: UUID, sandbox: SandboxConfig? = nil, recordTraffic: Bool = false) -> ActivityTerminalView {
        if let session = sessions[cardID] { return session.view }
        let session = TerminalSession(
            cardID: cardID, owner: self, sandbox: sandbox, recordTraffic: recordTraffic,
            initialCommand: pendingCommands.removeValue(forKey: cardID))
        sessions[cardID] = session
        return session.view
    }

    /// Runs `command` in the card's shell as soon as the card is first shown.
    func run(_ command: String, whenStarting cardID: UUID) {
        pendingCommands[cardID] = command
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

    /// The card whose shell (or one of its child processes) has a connection to Agent Traffic open from
    /// `clientPort`.
    private func caller(clientPort: UInt16) -> AgentTraffic.Caller? {
        var shells: [pid_t: (cardID: UUID, isStrict: Bool)] = [:]
        for (cardID, session) in sessions {
            guard let pid = session.view.process?.shellPid, pid > 0 else { continue }
            shells[pid] = (cardID, session.sandbox?.level == .strict)
        }
        guard let found = SocketOwner.find(localPort: clientPort, remotePort: AgentTraffic.port, under: Set(shells.keys)),
              let card = shells[found.shell] else { return nil }
        return AgentTraffic.Caller(cardID: card.cardID, process: SocketOwner.name(of: found.pid), restricted: card.isStrict)
    }

    func close(_ cardID: UUID) {
        sessions.removeValue(forKey: cardID)?.close()
        repoRefreshes.removeValue(forKey: cardID)?.cancel()
        titles[cardID] = nil
        repos[cardID] = nil
        unseenOutput.remove(cardID)
        lookedAt(cardID)
        lastOutput[cardID] = nil
        quietChecks.removeValue(forKey: cardID)?.cancel()
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
        lastOutput[cardID] = Date()
        if quietChecks[cardID] == nil {
            quietChecks[cardID] = Task { [weak self] in await self?.waitForQuiet(cardID) }
        }
        guard cardID != visibleCardID, !unseenOutput.contains(cardID) else { return }
        unseenOutput.insert(cardID)
    }

    // MARK: - Attention

    /// How long an agent has to stay quiet after printing before it counts as waiting for the user.
    static let quietDelay: TimeInterval = 5
    /// Command-line agents, by process name. Agents that run on Node, Bun, Deno or Python are recognized by the
    /// terminal title they set instead.
    static let agentNames: Set<String> = [
        "claude", "copilot", "codex", "gemini", "aider", "opencode", "cursor-agent", "amp", "goose", "qwen", "crush",
    ]
    private static let agentRuntimes: Set<String> = ["node", "bun", "deno", "python", "python3"]

    /// A program asked for the user: an explicit notification or the bell, or an agent that went quiet.
    /// `repeats` lets a card that already waits for the user notify again, for a new message.
    fileprivate func attentionRequested(_ cardID: UUID, message: String, repeats: Bool = true) {
        guard sessions[cardID] != nil, !isWatching(cardID) else { return }
        guard repeats || !needsAttention.contains(cardID) else { return }
        needsAttention.insert(cardID)
        onAttention(cardID, message)
    }

    /// The user is looking at the card now, so it no longer waits for them.
    func lookedAt(_ cardID: UUID) {
        guard needsAttention.remove(cardID) != nil else { return }
        onAttentionCleared(cardID)
    }

    /// Waits until the card has printed nothing for `quietDelay`; if an agent is running in it then, it's
    /// most likely waiting for an answer.
    private func waitForQuiet(_ cardID: UUID) async {
        defer { quietChecks[cardID] = nil }
        while let last = lastOutput[cardID] {
            let remaining = last.addingTimeInterval(Self.quietDelay).timeIntervalSinceNow
            guard remaining > 0 else { break }
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            if Task.isCancelled { return }
        }
        guard let agent = runningAgent(in: cardID) else { return }
        attentionRequested(cardID, message: "\(agent) is waiting for you.", repeats: false)
    }

    /// The agent running in the foreground of a card, by name, or nil when it's something else.
    private func runningAgent(in cardID: UUID) -> String? {
        guard let program = runningProgram(in: cardID)?.lowercased() else { return nil }
        if Self.agentNames.contains(program) { return program.prefix(1).uppercased() + program.dropFirst() }
        guard Self.agentRuntimes.contains(program), let title = titles[cardID]?.lowercased() else { return nil }
        return Self.agentNames.first { title.contains($0) }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }
}

/// Reads the desktop notifications programs send with escape codes: OSC 9 (iTerm2), OSC 777 (rxvt, Ghostty)
/// and OSC 99 (kitty). Claude Code sends OSC 9 with its iTerm2 notification setting.
enum TerminalNotification {
    /// The message to show, or nil for OSC sequences that aren't notifications.
    static func message(code: Int, payload: [UInt8]) -> String? {
        let text = String(decoding: payload, as: UTF8.self)
        let message: String
        switch code {
        case 9:
            // OSC 9;4 is a progress bar and other OSC 9;<number> are ConEmu commands, not notifications.
            if let first = text.split(separator: ";", maxSplits: 1).first, Int(first) != nil { return nil }
            message = text
        case 777:
            // notify;<title>;<body>
            let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.first == "notify", parts.count >= 2 else { return nil }
            message = parts.count == 3 && !parts[2].isEmpty ? parts[2] : parts[1]
        case 99:
            // <metadata>;<text>
            guard let separator = text.firstIndex(of: ";") else { return nil }
            message = String(text[text.index(after: separator)...])
        default:
            return nil
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
private final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let cardID: UUID
    weak var owner: TerminalSessions?
    let view = ActivityTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
    let sandbox: SandboxConfig?
    private let recordTraffic: Bool
    private var isClosed = false
    private var startedAt = Date()
    private var notificationObservation: TerminalOscObservation?

    init(cardID: UUID, owner: TerminalSessions, sandbox: SandboxConfig?, recordTraffic: Bool, initialCommand: String?) {
        self.cardID = cardID
        self.owner = owner
        self.sandbox = sandbox
        self.recordTraffic = recordTraffic
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        apply(owner.theme, backgroundOpacity: owner.backgroundOpacity)
        // Keep ⌥ for typing characters such as @ { } [ ] on German and other layouts.
        view.optionAsMetaKey = false
        // SwiftTerm parses output on a background thread and reports each batch there.
        view.setProcessOutputHandler { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.owner?.outputArrived(self.cardID)
                }
            }
        }
        view.onBell = { [weak self] in
            guard let self else { return }
            self.owner?.attentionRequested(self.cardID, message: "Rang the bell.")
        }
        notificationObservation = view.observeOscEvents { [weak self] event in
            guard let message = TerminalNotification.message(code: event.code, payload: event.payload) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.owner?.attentionRequested(self.cardID, message: message)
                }
            }
        }
        startShell()
        if let initialCommand {
            // The shell reads it from the terminal once its startup files have run.
            view.send(data: ArraySlice(Array((initialCommand + "\n").utf8)))
        }
    }

    func apply(_ theme: Theme, backgroundOpacity: Double) {
        view.nativeForegroundColor = theme.terminalForeground
        view.nativeBackgroundColor = theme.terminalBackground
        view.backgroundOpacity = CGFloat(backgroundOpacity)
        // Like iTerm2's "Minimum contrast": text too close to its background, such as the fixed greys Copilot CLI
        // picks for the other brightness, is lightened or darkened as it's drawn, so it also follows theme changes.
        // 4.5 is WCAG AA; a see-through panel shows a background less solid than the theme's, so it asks a bit more.
        view.minimumContrastRatio = CGFloat(4.5 + 2 * (1 - backgroundOpacity))
        view.installColors(theme.terminalPalette.map { rgb in
            SwiftTerm.Color(red: UInt16((rgb >> 16) & 0xff) * 257,
                            green: UInt16((rgb >> 8) & 0xff) * 257,
                            blue: UInt16(rgb & 0xff) * 257)
        })
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
        // Lets tools that check it pick dark or light colors to match the card.
        environment["COLORFGBG"] = owner?.theme.colorFGBG ?? Theme.dark.colorFGBG
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        startedAt = Date()

        guard let sandbox else {
            if recordTraffic {
                guard recordedEnvironment(&environment) else { return }
            }
            // A leading "-" in argv[0] starts a login shell, which loads the user's profile like Terminal.app does.
            view.startProcess(
                executable: shell,
                environment: environment.map { "\($0.key)=\($0.value)" },
                execName: "-" + (shell as NSString).lastPathComponent,
                currentDirectory: NSHomeDirectory()
            )
            return
        }

        // Sandboxed: never fall back to an unsandboxed shell.
        guard Sandbox.isAvailable else {
            view.feed(text: "Shade: \(Sandbox.executable) isn't available, so the sandboxed shell was not started.\r\n")
            return
        }
        let profile: URL
        do {
            profile = try Sandbox.writeProfile(for: sandbox, cardID: cardID)
        } catch {
            view.feed(text: "Shade: couldn't write the sandbox profile (\(error.localizedDescription)), "
                + "so the shell was not started.\r\n")
            return
        }
        environment["SHADE_SANDBOX"] = sandbox.level.rawValue
        view.feed(text: "Shade: sandboxed shell (\(sandbox.level.name)). Writes are limited to "
            + "\(sandbox.root.path), temp and tool caches; keys and credentials can't be read.\r\n")

        if recordTraffic {
            guard recordedEnvironment(&environment) else { return }
            if sandbox.level == .strict {
                // Strict only lets agent services through, so skip Claude Code's others (telemetry, update checks).
                environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
            }
        }
        launchSandboxed(shell: shell, profile: profile, root: sandbox.root, environment: environment)
    }

    /// Points the card's model calls and proxy at Shade's relay. If it can't run, the shell isn't started at all,
    /// so nothing runs unrecorded.
    private func recordedEnvironment(_ environment: inout [String: String]) -> Bool {
        guard let relay = owner?.agentTraffic.environment(for: cardID) else {
            let reason = owner?.agentTraffic.listenerError ?? "Agent Traffic couldn't start."
            view.feed(text: "Shade: \(reason) The shell was not started.\r\n")
            return false
        }
        environment.merge(relay) { _, recorded in recorded }
        view.feed(text: "Shade: this card's network calls are recorded. See them in Agent Traffic.\r\n")
        if sandbox?.level == .strict {
            view.feed(text: "Shade: Strict lets programs reach only agent services, through Shade.\r\n")
        }
        return true
    }

    private func launchSandboxed(shell: String, profile: URL, root: URL, environment: [String: String]) {
        startedAt = Date()
        view.startProcess(
            executable: Sandbox.executable,
            args: ["-f", profile.path, shell, "-l"],
            environment: environment.map { "\($0.key)=\($0.value)" },
            currentDirectory: root.path
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
                // A shell that dies right away (e.g. a sandbox profile macOS rejects) would restart forever.
                guard Date().timeIntervalSince(self.startedAt) > 2 else {
                    self.view.feed(text: "\r\n[The shell exited right after starting, so Shade didn't restart it. "
                        + "Close this card and open a new one.]\r\n")
                    return
                }
                self.view.feed(text: "\r\n[Shell exited. Starting a new one…]\r\n")
                self.startShell()
            }
        }
    }
}

struct TerminalPane: NSViewRepresentable {
    let sessions: TerminalSessions
    let cardID: UUID
    let sandbox: SandboxConfig?
    let recordTraffic: Bool

    func makeNSView(context: Context) -> ActivityTerminalView {
        let view = sessions.view(for: cardID, sandbox: sandbox, recordTraffic: recordTraffic)
        // Type straight into the shell when the card is shown.
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: ActivityTerminalView, context: Context) {}
}
