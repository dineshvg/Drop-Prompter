import AppKit
import ServiceManagement
import SwiftUI
import Translation

struct ContentView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var terminals: TerminalSessions
    @ObservedObject var buffers: FileBuffers
    let onClose: () -> Void

    @State private var translation = ""
    @State private var translationError: String?
    @State private var isTranslating = false
    @State private var showSettings = false
    @State private var pendingRemoval: PendingRemoval?
    /// Status and files of the repository shown in the sidebar and file cards.
    @StateObject private var repoWatcher = RepoWatcher()
    /// Repository root while Quick Open (⌘P) is showing.
    @State private var quickOpenRoot: URL?
    @State private var renamingCardID: UUID?
    @State private var renamingGroupID: UUID?
    @FocusState private var groupRenameFocused: Bool
    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool
    /// Setting or invalidating this makes `.translationTask` run with a fresh session.
    @State private var translationConfig: TranslationSession.Configuration?

    private struct PendingRemoval {
        let cardIDs: [UUID]
        let title: String
        let message: String
        var confirmLabel = "Close Card"
    }

    /// One entry of the card strip: an ungrouped card, or a group with its cards.
    private enum StripItem: Identifiable {
        case card(StripCard)
        case group(Settings.CardGroup, [StripCard])

        var id: UUID {
            switch self {
            case .card(let item): return item.card.id
            case .group(let group, _): return group.id
            }
        }
    }

    private struct StripCard: Identifiable {
        let card: Settings.Card
        /// Position in all cards, for ⌘1…⌘9 and fallback titles.
        let index: Int
        var id: UUID { card.id }
    }

    private struct TranslationRequest: Equatable {
        let text: String
        let source: String
        let target: String
        let enabled: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            if let problem = settings.hotKeyProblem, settings.dismissedHotKeyWarning != settings.hotKeyID {
                hotKeyBanner(problem)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
            cardStrip
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            Divider().opacity(0.4)
            // The sidebar sits next to the card content, so it stays put while switching cards.
            HSplitView {
                if settings.showSidebar && !settings.sidebarOnRight { sidebar }
                cardContent
                    .frame(minWidth: 300, maxWidth: .infinity)
                if settings.showSidebar && settings.sidebarOnRight { sidebar }
            }
            // Room for the AppKit resize grips along the bottom edge (see ResizeHandleView).
            Color.clear.frame(height: 14)
        }
        .overlay {
            if let root = quickOpenRoot {
                QuickOpenView(
                    root: root,
                    onOpen: { url in
                        settings.openFileCard(url, repoRoot: root)
                        quickOpenRoot = nil
                    },
                    onCancel: { quickOpenRoot = nil }
                )
            }
        }
        .overlay {
            if settings.showWelcome {
                WelcomeView(hotKeyLabel: settings.hotKey.label) { settings.showWelcome = false }
            }
        }
        .onChange(of: settings.selectedCardID, initial: true) { _, id in
            terminals.visibleCardID = id
        }
        // Watch the repository only while something shows it: the sidebar or a file card.
        .onChange(of: watchRequest, initial: true) { _, request in
            repoWatcher.watch(request.isNeeded ? request.root : nil)
            if let root = request.root, root.path != settings.lastRepoPath {
                settings.lastRepoPath = root.path
            }
        }
        .task(id: translationRequest) {
            await scheduleTranslation(translationRequest)
        }
        .translationTask(translationConfig) { session in
            await translate(using: session)
        }
    }

    private var translationRequest: TranslationRequest {
        TranslationRequest(
            text: settings.currentText,
            source: settings.sourceLanguage,
            target: settings.targetLanguage,
            enabled: settings.showTranslation
        )
    }

    private var editorRow: some View {
        HStack(spacing: 0) {
            TextEditor(text: $settings.currentText)
                .font(.system(size: settings.fontSize))
                .foregroundStyle(settings.theme.textColor ?? .primary)
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(12)
                .id(settings.selectedCardID) // fresh undo history and scroll position per card
            if settings.showTranslation {
                Divider().opacity(0.4)
                translationPane
            }
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        let card = settings.currentCard
        switch card.kind {
        case .notes:
            editorRow
        case .terminal:
            terminalArea
        case .file:
            if let path = card.filePath {
                FileViewer(
                    cardID: card.id,
                    url: URL(fileURLWithPath: path),
                    change: repoWatcher.change(forFileAt: path),
                    repoRoot: card.repoRoot.map { URL(fileURLWithPath: $0, isDirectory: true) },
                    theme: settings.theme,
                    codeSize: codeSize,
                    editorBundleID: settings.editorBundleID,
                    languageOverride: card.language,
                    highlightingEnabled: settings.syntaxHighlighting,
                    highlightTheme: settings.highlightTheme(for: settings.theme),
                    onSetLanguage: { settings.setLanguage($0, of: card.id) },
                    buffers: buffers
                )
                .id(card.id)
            }
        }
    }

    private var sidebar: some View {
        RepoSidebar(
            watcher: repoWatcher,
            openFilePath: settings.currentCard.kind == .file ? settings.currentCard.filePath : nil,
            isOnRight: settings.sidebarOnRight,
            onOpen: { settings.openFileCard($0, repoRoot: repoWatcher.root) },
            onSwitchSide: { settings.sidebarOnRight.toggle() },
            onHide: { settings.showSidebar = false }
        )
        .frame(minWidth: 200, idealWidth: 280, maxWidth: 480)
    }

    /// The repository of the current card: a terminal's shell directory or a file's repository. On a notes
    /// card, the last one used.
    private var activeRepoRoot: URL? {
        let card = settings.currentCard
        switch card.kind {
        case .terminal:
            if let root = terminals.repos[card.id]?.root { return root }
        case .file:
            if let path = card.repoRoot { return URL(fileURLWithPath: path, isDirectory: true) }
        case .notes:
            break
        }
        return settings.lastRepoPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private struct WatchRequest: Equatable {
        let root: URL?
        let isNeeded: Bool
    }

    private var watchRequest: WatchRequest {
        WatchRequest(root: activeRepoRoot, isNeeded: settings.showSidebar || settings.currentCard.kind == .file)
    }

    /// Code in the file and diff viewers is smaller than notes text, but follows its size.
    private var codeSize: CGFloat {
        CGFloat(max(11, settings.fontSize * 0.65))
    }

    // MARK: - Terminal and repository

    private var terminalArea: some View {
        let cardID = settings.selectedCardID
        let repo = terminals.repos[cardID]
        return VStack(spacing: 0) {
            if let repo {
                repoBar(repo)
                Divider().opacity(0.4)
            }
            TerminalPane(sessions: terminals, cardID: cardID)
                .id(cardID)
                .padding(.horizontal, 8)
                .padding(.top, 6)
        }
    }

    /// Shown above a terminal card whose shell is inside a git repository.
    private func repoBar(_ repo: RepoStatus) -> some View {
        HStack(spacing: 10) {
            Label(repo.branch, systemImage: "arrow.triangle.branch")
                .help("Current branch")
            Text(repo.root.lastPathComponent)
                .foregroundStyle(.secondary)
                .help(repo.root.path)
            Text(repo.changes.isEmpty ? "clean" : "\(repo.changes.count) changed")
                .foregroundStyle(repo.changes.isEmpty ? Color.secondary : Color.orange)
            Spacer()
            Button { quickOpenRoot = repo.root } label: { Label("Open File", systemImage: "magnifyingglass") }
                .keyboardShortcut("p", modifiers: .command)
                .help("Quick Open a file in this repository (⌘P)")
            Button { settings.showSidebar = true } label: { Label("Changes", systemImage: "plusminus") }
                .help("Show changes and files in the sidebar (⌘B)")
            Button { CodeEditors.open(repo.root, with: settings.editorBundleID) } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .help("Open the repository in \(CodeEditors.name(for: settings.editorBundleID))")
            Button { CodeEditors.reveal(repo.root) } label: { Image(systemName: "folder") }
                .help("Show in Finder")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func hotKeyBanner(_ problem: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(problem)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Change") { showSettings = true }
            Button("Dismiss") { settings.dismissedHotKeyWarning = settings.hotKeyID }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.12)))
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { settings.fontSize = max(12, settings.fontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }
                .help("Smaller text")
            Button { settings.fontSize = min(72, settings.fontSize + 2) } label: { Image(systemName: "textformat.size.larger") }
                .help("Larger text")

            Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
            Slider(value: $settings.opacity, in: 0.1...1)
                .frame(width: 110)
                .help("Background opacity")

            Toggle(isOn: $settings.showSidebar) {
                Image(systemName: settings.sidebarOnRight ? "sidebar.right" : "sidebar.left")
            }
            .toggleStyle(.button)
            .keyboardShortcut("b", modifiers: .command)
            .help("Repository sidebar (⌘B)")

            Menu {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(Theme.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "paintpalette")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Theme")

            Spacer()

            Toggle(isOn: $settings.showTranslation) { Label("Translate", systemImage: "character.bubble") }
                .toggleStyle(.button)
            Picker("Source language", selection: $settings.sourceLanguage) {
                Text("Auto-detect").tag("")
                Divider()
                ForEach(Settings.languages) { Text($0.name).tag($0.code) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 120)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Picker("Target language", selection: $settings.targetLanguage) {
                ForEach(Settings.languages) { Text($0.name).tag($0.code) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 120)
            Button {
                if let url = GoogleTranslate.webURL(for: settings.currentText, target: settings.targetLanguage) {
                    NSWorkspace.shared.open(url)
                }
            } label: { Image(systemName: "globe") }
                .help("Open in translate.google.com (sends the text to Google)")

            Button { settings.showWelcome = true } label: { Image(systemName: "questionmark.circle") }
                .help("Welcome and keyboard shortcuts")
            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { SettingsPopover(settings: settings, highlighting: SyntaxHighlighting.shared) }
            Button(action: onClose) { Image(systemName: "chevron.up") }
                .help("Hide (Esc / ⌃Space)")
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }

    // MARK: - Cards

    private var cardStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(stripItems) { item in
                    switch item {
                    case .card(let item):
                        cardChip(item.card, index: item.index)
                    case .group(let group, let members):
                        groupView(group, members: members)
                    }
                }
                Button { settings.addCard() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("t", modifiers: .command)
                    .help("New notes card (⌘T)")
                Button { settings.addCard(kind: .terminal) } label: { Image(systemName: "apple.terminal") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .help("New terminal card (⇧⌘T)")
            }
        }
        .alert(
            pendingRemoval?.title ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { removal in
            Button(removal.confirmLabel, role: .destructive) { removal.cardIDs.forEach(removeCard) }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            Text(removal.message)
        }
    }

    private func cardChip(_ card: Settings.Card, index: Int) -> some View {
        let isSelected = card.id == settings.selectedCardID
        return HStack(spacing: 6) {
            if card.kind != .notes {
                Image(systemName: card.kind == .terminal ? "apple.terminal" : "doc.text").font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if renamingCardID == card.id {
                TextField("Card name", text: $renameText)
                    .textFieldStyle(.plain)
                    .frame(width: 150)
                    .focused($renameFieldFocused)
                    .onAppear { renameFieldFocused = true }
                    .onSubmit(commitRename)
                    .onExitCommand { renamingCardID = nil }
                    .onChange(of: renameFieldFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Button { settings.selectedCardID = card.id } label: {
                    Text(card.title(fallback: "Card \(index + 1)", terminalTitle: terminals.titles[card.id]))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .help(card.filePath ?? "")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command) : nil)
                .simultaneousGesture(TapGesture(count: 2).onEnded { startRename(card, index: index) })
                .help(index < 9 ? "⌘\(index + 1) · double-click to rename" : "Double-click to rename")
            }
            if buffers.isDirty(card.id) {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
            if terminals.unseenOutput.contains(card.id) {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    .help("New output")
            }
            if isSelected && settings.cards.count > 1 && renamingCardID != card.id {
                Button { requestRemoval(of: card) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close card")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(isSelected ? 0.16 : 0.06)))
        .contextMenu {
            Button("Rename…") { startRename(card, index: index) }
            if card.name != nil {
                Button("Use Automatic Title") { settings.rename(card.id, to: "") }
            }
            Divider()
            Button("Add to New Group") { addToNewGroup(card) }
            let otherGroups = settings.groups.filter { $0.id != card.groupID }
            if !otherGroups.isEmpty {
                Menu("Add to Group") {
                    ForEach(otherGroups) { group in
                        Button(group.name) { settings.move(card.id, to: group.id) }
                    }
                }
            }
            if card.groupID != nil {
                Button("Remove from Group") { settings.move(card.id, to: nil) }
            }
            if settings.cards.count > 1 {
                Divider()
                Button("Close Card") { requestRemoval(of: card) }
            }
        }
    }

    // MARK: - Groups

    private var stripItems: [StripItem] {
        let all = settings.cards.enumerated().map { StripCard(card: $0.element, index: $0.offset) }
        var items: [StripItem] = []
        var placed = Set<UUID>()
        for item in all {
            guard let groupID = item.card.groupID,
                  let group = settings.groups.first(where: { $0.id == groupID }) else {
                items.append(.card(item))
                continue
            }
            if placed.insert(groupID).inserted {
                items.append(.group(group, all.filter { $0.card.groupID == groupID }))
            }
        }
        return items
    }

    private func groupView(_ group: Settings.CardGroup, members: [StripCard]) -> some View {
        HStack(spacing: 4) {
            groupLabel(group, count: members.count)
            if !group.isCollapsed {
                ForEach(members) { member in
                    cardChip(member.card, index: member.index)
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 14).fill(group.color.swiftUIColor.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(group.color.swiftUIColor.opacity(0.5), lineWidth: 1))
    }

    private func groupLabel(_ group: Settings.CardGroup, count: Int) -> some View {
        Group {
            if renamingGroupID == group.id {
                TextField("Group name", text: $renameText)
                    .textFieldStyle(.plain)
                    .frame(width: 120)
                    .padding(.horizontal, 8)
                    .focused($groupRenameFocused)
                    .onAppear { groupRenameFocused = true }
                    .onSubmit(commitGroupRename)
                    .onExitCommand { renamingGroupID = nil }
                    .onChange(of: groupRenameFocused) { _, focused in
                        if !focused { commitGroupRename() }
                    }
            } else {
                Text(group.isCollapsed ? "\(group.name) · \(count)" : group.name)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(group.color.swiftUIColor))
                    .contentShape(Capsule())
                    .onTapGesture(count: 2) { startGroupRename(group) }
                    .onTapGesture { settings.toggleCollapsed(group.id) }
                    .help(group.isCollapsed ? "Expand group" : "Collapse group · double-click to rename")
            }
        }
        .contextMenu {
            Button("Rename Group…") { startGroupRename(group) }
            Menu("Color") {
                ForEach(Settings.GroupColor.allCases, id: \.self) { color in
                    Button {
                        settings.setColor(color, of: group.id)
                    } label: {
                        Label(color.rawValue.capitalized, systemImage: color == group.color ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            }
            Button(group.isCollapsed ? "Expand Group" : "Collapse Group") { settings.toggleCollapsed(group.id) }
            Divider()
            Button("Ungroup") { settings.ungroup(group.id) }
            Button("Close Group") { requestRemoval(of: group) }
        }
    }

    /// New group named after the card's repository when it has one, then ready to rename.
    private func addToNewGroup(_ card: Settings.Card) {
        let repoName = terminals.repos[card.id]?.root.lastPathComponent
            ?? card.repoRoot.map { ($0 as NSString).lastPathComponent }
        let groupID = settings.newGroup(with: card.id, name: repoName ?? "Group \(settings.groups.count + 1)")
        if let group = settings.groups.first(where: { $0.id == groupID }) {
            startGroupRename(group)
        }
    }

    private func startGroupRename(_ group: Settings.CardGroup) {
        renamingCardID = nil
        renameText = group.name
        renamingGroupID = group.id
    }

    private func commitGroupRename() {
        guard let id = renamingGroupID else { return }
        settings.renameGroup(id, to: renameText)
        renamingGroupID = nil
    }

    /// Closing a group closes all its cards, so it always asks and says what would be lost.
    private func requestRemoval(of group: Settings.CardGroup) {
        let ids = settings.cardIDs(in: group.id)
        var details = ["Closes its \(ids.count) \(ids.count == 1 ? "card" : "cards"), including notes in them."]
        let running = ids.compactMap { terminals.runningProgram(in: $0) }
        if !running.isEmpty {
            details.append("Stops " + running.map { "“\($0)”" }.joined(separator: ", ") + ".")
        }
        let unsaved = ids.filter { buffers.isDirty($0) }.count
        if unsaved > 0 {
            details.append("Discards unsaved changes in \(unsaved) \(unsaved == 1 ? "file" : "files").")
        }
        pendingRemoval = PendingRemoval(
            cardIDs: ids,
            title: "Close group “\(group.name)”?",
            message: details.joined(separator: " "),
            confirmLabel: "Close Group"
        )
    }

    private func startRename(_ card: Settings.Card, index: Int) {
        renamingGroupID = nil
        settings.selectedCardID = card.id
        renameText = card.name ?? card.title(fallback: "Card \(index + 1)", terminalTitle: terminals.titles[card.id])
        renamingCardID = card.id
    }

    private func commitRename() {
        guard let id = renamingCardID else { return }
        settings.rename(id, to: renameText)
        renamingCardID = nil
    }

    /// Empty notes cards close right away. Notes with text and terminals ask first; a terminal says
    /// which program would be stopped.
    private func requestRemoval(of card: Settings.Card) {
        switch card.kind {
        case .terminal:
            if let program = terminals.runningProgram(in: card.id) {
                pendingRemoval = PendingRemoval(
                    cardIDs: [card.id],
                    title: "Close terminal while “\(program)” is running?",
                    message: "Closing this card stops “\(program)” and anything else running in it."
                )
            } else {
                pendingRemoval = PendingRemoval(
                    cardIDs: [card.id],
                    title: "Close this terminal card?",
                    message: "The shell running in it will be closed."
                )
            }
        case .file:
            if buffers.isDirty(card.id) {
                pendingRemoval = PendingRemoval(
                    cardIDs: [card.id],
                    title: "Close without saving?",
                    message: "Your changes to “\(card.title(fallback: "this file", terminalTitle: nil))” will be lost."
                )
            } else {
                removeCard(card.id)
            }
        case .notes:
            if card.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                removeCard(card.id)
            } else {
                pendingRemoval = PendingRemoval(
                    cardIDs: [card.id],
                    title: "Delete this card?",
                    message: "Its text will be deleted."
                )
            }
        }
    }

    private func removeCard(_ id: UUID) {
        terminals.close(id) // no-op for other kinds
        buffers.close(id)
        settings.removeCard(id)
    }

    // MARK: - Translation

    private var translationPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let translationError {
                    Text(translationError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Text(translation)
                    .font(.system(size: settings.fontSize))
                    .foregroundStyle(settings.theme.textColor ?? .primary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(17) // matches TextEditor's padding + text inset
        }
        .overlay(alignment: .topTrailing) {
            if isTranslating { ProgressView().controlSize(.small).padding(8) }
        }
    }

    /// Debounces edits, then (re)triggers `.translationTask`.
    private func scheduleTranslation(_ request: TranslationRequest) async {
        guard request.enabled else {
            translationConfig = nil
            return
        }
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            translation = ""
            translationError = nil
            return
        }
        // A newer keystroke cancels this task before anything is translated.
        do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }

        let source = request.source.isEmpty ? nil : Locale.Language(identifier: request.source)
        let target = Locale.Language(identifier: request.target)
        if var config = translationConfig, config.source == source, config.target == target {
            config.invalidate()
            translationConfig = config
        } else {
            translationConfig = TranslationSession.Configuration(source: source, target: target)
        }
    }

    /// Translates line by line so the layout of the notes is kept. Runs fully on-device; the first use
    /// of a language pair shows a system prompt to download it.
    private func translate(using session: TranslationSession) async {
        var lines = settings.currentText.components(separatedBy: "\n")
        let requests = lines.indices
            .filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
            .map { TranslationSession.Request(sourceText: lines[$0], clientIdentifier: String($0)) }
        guard !requests.isEmpty else { return }

        isTranslating = true
        defer { isTranslating = false }
        do {
            for response in try await session.translations(from: requests) {
                if let id = response.clientIdentifier, let index = Int(id) {
                    lines[index] = response.targetText
                }
            }
            translation = lines.joined(separator: "\n")
            translationError = nil
        } catch is CancellationError {
        } catch {
            translationError = "Translation failed: \(error.localizedDescription). "
                + "If the text is already in the target language, pick another one."
        }
    }
}

struct SettingsPopover: View {
    @ObservedObject var settings: Settings
    @ObservedObject var highlighting: SyntaxHighlighting
    @State private var showThemeCatalog = false
    /// Read from the system each time the popover opens; macOS owns the login item.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemMessage: String?

    var body: some View {
        if showThemeCatalog {
            ThemeCatalogView(highlighting: highlighting) { showThemeCatalog = false }
        } else {
            settingsForm
        }
    }

    private var settingsForm: some View {
        Form {
            Section("Shortcut") {
                Picker("Show / hide panel", selection: $settings.hotKeyID) {
                    ForEach(HotKeyPreset.all) { Text($0.label).tag($0.id) }
                }
                if let problem = settings.hotKeyProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Open Keyboard Shortcuts Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } else {
                    Text("Works from any app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(Theme.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Code") {
                Picker("Open files and repositories in", selection: $settings.editorBundleID) {
                    Text("Default App").tag("")
                    ForEach(CodeEditors.installed) { Text($0.name).tag($0.bundleID) }
                }
            }
            Section("Syntax Highlighting") {
                Toggle("Highlight code in file cards", isOn: $settings.syntaxHighlighting)
                Picker("Theme with \(settings.theme.name)", selection: Binding(
                    get: { settings.highlightTheme(for: settings.theme) },
                    set: { settings.setHighlightTheme($0, for: settings.theme) }
                )) {
                    ForEach(highlighting.installedThemes, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!settings.syntaxHighlighting)
                HStack {
                    Button("Get More Themes…") { showThemeCatalog = true }
                    Button("Open Folder") { NSWorkspace.shared.open(SyntaxHighlighting.userDirectory) }
                }
                Text("Each Shade theme keeps its own highlighting theme. To add a language, put its highlight.js "
                    + "browser build (.js) into the folder's “languages” subfolder and restart Shade.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginItemMessage {
                    Text(loginItemMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Panel") {
                Slider(value: $settings.widthFraction, in: Settings.widthRange) { Text("Width") }
                Slider(value: $settings.heightFraction, in: Settings.heightRange) { Text("Height") }
                Toggle("Hide from screen sharing", isOn: $settings.hideFromScreenShare)
                Text("Best effort: some capture tools on recent macOS versions ignore this. Test it with your meeting app first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Translation") {
                Text("Translation runs on-device with Apple's Translation framework; nothing is sent to a server. "
                    + "Downloaded languages are managed in System Settings › General › Language & Region › Translation Languages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Language & Region Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        guard enabled != (service.status == .enabled) else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            loginItemMessage = nil
        } catch {
            loginItemMessage = "Could not change the login item: \(error.localizedDescription)"
        }
        if service.status == .requiresApproval {
            loginItemMessage = "Allow Shade in System Settings › General › Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
        launchAtLogin = service.status == .enabled
    }
}
