import Foundation

/// User preferences and note cards, persisted in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()

    /// Note cards; there is always at least one.
    @Published var cards: [Card] { didSet { saveCards() } }
    @Published var selectedCardID: UUID {
        didSet {
            save(selectedCardID.uuidString, "selectedCardID")
            // Like Chrome: selecting a card in a collapsed group opens the group.
            if let groupID = currentCard.groupID, let index = groups.firstIndex(where: { $0.id == groupID }),
               groups[index].isCollapsed {
                groups[index].isCollapsed = false
            }
        }
    }
    /// Named, colored groups of cards.
    @Published var groups: [CardGroup] { didSet { saveGroups() } }
    @Published var fontSize: Double { didSet { save(fontSize, "fontSize") } }
    /// Background (blur) opacity only; text stays fully opaque, like iTerm2's transparency.
    @Published var opacity: Double { didSet { save(opacity, "opacity") } }
    @Published var theme: Theme { didSet { save(theme.rawValue, "theme") } }
    /// Bundle ID of the editor for "Open in…"; empty means the macOS default app.
    @Published var editorBundleID: String { didSet { save(editorBundleID, "editorBundleID") } }
    @Published var syntaxHighlighting: Bool { didSet { save(syntaxHighlighting, "syntaxHighlighting") } }
    /// Whether new sandboxed terminal cards record their model API calls (Agent Traffic).
    @Published var recordAgentTraffic: Bool { didSet { save(recordAgentTraffic, "recordAgentTraffic") } }
    /// Opacity of the solid background behind code and terminals, separate from the see-through panel.
    @Published var codeBackgroundOpacity: Double { didSet { save(codeBackgroundOpacity, "codeBackgroundOpacity") } }
    static let codeBackgroundRange = 0.3...1.0
    /// Highlighting theme chosen for each Shade theme, by Shade theme raw value.
    @Published var highlightThemes: [String: String] { didSet { save(highlightThemes, "highlightThemes") } }
    /// Repository sidebar: pinned open or not, and on which side.
    @Published var showSidebar: Bool { didSet { save(showSidebar, "showSidebar") } }
    @Published var sidebarOnRight: Bool { didSet { save(sidebarOnRight, "sidebarOnRight") } }
    /// Repository the sidebar shows while a notes card is selected.
    @Published var lastRepoPath: String? { didSet { save(lastRepoPath ?? "", "lastRepoPath") } }
    @Published var widthFraction: Double { didSet { save(widthFraction, "widthFraction") } }
    @Published var heightFraction: Double { didSet { save(heightFraction, "heightFraction") } }
    /// Empty string means auto-detect.
    @Published var sourceLanguage: String { didSet { save(sourceLanguage, "sourceLanguage") } }
    @Published var targetLanguage: String { didSet { save(targetLanguage, "targetLanguage") } }
    @Published var showTranslation: Bool { didSet { save(showTranslation, "showTranslation") } }
    @Published var hideFromScreenShare: Bool { didSet { save(hideFromScreenShare, "hideFromScreenShare") } }
    /// A Dock icon also lists Shade in Force Quit (⌥⌘⎋), which only shows apps that have one.
    @Published var showInDock: Bool { didSet { save(showInDock, "showInDock") } }
    @Published var hotKeyID: String { didSet { save(hotKeyID, "hotKeyID") } }
    /// Set by the app delegate after registering the shortcut; nil when nothing is in the way.
    @Published var hotKeyProblem: String? = nil
    /// The shortcut whose warning the user dismissed, so the banner doesn't nag about it again.
    @Published var dismissedHotKeyWarning: String { didSet { save(dismissedHotKeyWarning, "dismissedHotKeyWarning") } }
    /// Whether the welcome screen is showing. Starts true until the user has dismissed it once.
    @Published var showWelcome: Bool { didSet { if !showWelcome { save(true, "hasSeenWelcome") } } }

    static let widthRange = 0.25...1.0
    static let heightRange = 0.15...0.95

    private init() {
        let d = UserDefaults.standard
        Self.migrateFromDropPrompter(d)
        let storedCards = d.data(forKey: "cards").flatMap { try? JSONDecoder().decode([Card].self, from: $0) } ?? []
        // Before cards existed, the single note was stored under "text".
        let initialCards = storedCards.isEmpty
            ? [Card(text: d.string(forKey: "text") ?? Self.welcomeText)]
            : storedCards
        cards = initialCards
        let storedSelection = d.string(forKey: "selectedCardID").flatMap(UUID.init(uuidString:))
        selectedCardID = initialCards.first { $0.id == storedSelection }?.id ?? initialCards[0].id
        groups = d.data(forKey: "groups").flatMap { try? JSONDecoder().decode([CardGroup].self, from: $0) } ?? []
        fontSize = d.object(forKey: "fontSize") as? Double ?? 20
        opacity = d.object(forKey: "opacity") as? Double ?? 0.8
        theme = d.string(forKey: "theme").flatMap(Theme.init(rawValue:)) ?? .dark
        editorBundleID = d.string(forKey: "editorBundleID") ?? ""
        syntaxHighlighting = d.object(forKey: "syntaxHighlighting") as? Bool ?? true
        recordAgentTraffic = d.bool(forKey: "recordAgentTraffic")
        codeBackgroundOpacity = d.object(forKey: "codeBackgroundOpacity") as? Double ?? 0.75
        highlightThemes = d.dictionary(forKey: "highlightThemes") as? [String: String] ?? [:]
        showSidebar = d.bool(forKey: "showSidebar")
        sidebarOnRight = d.bool(forKey: "sidebarOnRight")
        lastRepoPath = d.string(forKey: "lastRepoPath").flatMap { $0.isEmpty ? nil : $0 }
        widthFraction = d.object(forKey: "widthFraction") as? Double ?? 0.6
        heightFraction = d.object(forKey: "heightFraction") as? Double ?? 0.45
        sourceLanguage = d.string(forKey: "sourceLanguage") ?? ""
        targetLanguage = d.string(forKey: "targetLanguage") ?? "de"
        showTranslation = d.object(forKey: "showTranslation") as? Bool ?? false
        hideFromScreenShare = d.object(forKey: "hideFromScreenShare") as? Bool ?? true
        showInDock = d.object(forKey: "showInDock") as? Bool ?? true
        showWelcome = !d.bool(forKey: "hasSeenWelcome")
        hotKeyID = d.string(forKey: "hotKeyID") ?? HotKeyPreset.all[0].id
        dismissedHotKeyWarning = d.string(forKey: "dismissedHotKeyWarning") ?? ""
    }

    var hotKey: HotKeyPreset {
        HotKeyPreset.all.first { $0.id == hotKeyID } ?? HotKeyPreset.all[0]
    }

    /// Shade used to be called Drop Prompter (bundle ID local.dropprompter). Copies its cards and settings
    /// once, on the first launch under the new name.
    private static func migrateFromDropPrompter(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: "migratedFromDropPrompter") else { return }
        defaults.set(true, forKey: "migratedFromDropPrompter")
        guard defaults.object(forKey: "cards") == nil,
              let old = defaults.persistentDomain(forName: "local.dropprompter") else { return }
        for (key, value) in old {
            defaults.set(value, forKey: key)
        }
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func saveCards() {
        if let data = try? JSONEncoder().encode(cards) { save(data, "cards") }
    }

    private func saveGroups() {
        if let data = try? JSONEncoder().encode(groups) { save(data, "groups") }
    }

    private static let welcomeText = """
        Paste your talking points here.

        ⌃Space shows/hides this panel, Esc hides it.
        + adds a card, ⌘1…⌘9 switches cards. Drag the bottom edge or corner to resize.
        """

    // MARK: - Cards

    struct Card: Codable, Identifiable, Equatable {
        enum Kind: String, Codable { case notes, terminal, file, traffic }

        var id = UUID()
        var kind: Kind
        /// Name the user gave the card; nil shows an automatic title.
        var name: String?
        var text: String
        /// Absolute path of the file a `.file` card shows.
        var filePath: String?
        /// Root of the git repository the file belongs to, for its diff and the sidebar.
        var repoRoot: String?
        var groupID: UUID?
        /// Highlighting language chosen for a file card: nil detects it from the file name,
        /// `Card.plainText` turns highlighting off.
        var language: String?
        /// Set for sandboxed terminal cards, with the folder they may change.
        var sandbox: SandboxLevel?
        var sandboxRoot: String?
        var recordTraffic: Bool?

        static let plainText = "plaintext"

        var sandboxConfig: SandboxConfig? {
            guard kind == .terminal, let sandbox, let sandboxRoot else { return nil }
            return SandboxConfig(level: sandbox, root: URL(fileURLWithPath: sandboxRoot, isDirectory: true),
                                 recordTraffic: recordTraffic == true)
        }

        init(kind: Kind = .notes, text: String = "", filePath: String? = nil, repoRoot: String? = nil) {
            self.kind = kind
            self.text = text
            self.filePath = filePath
            self.repoRoot = repoRoot
        }

        /// Cards saved before `kind` and `name` existed load as notes cards.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .notes
            name = try container.decodeIfPresent(String.self, forKey: .name)
            text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
            repoRoot = try container.decodeIfPresent(String.self, forKey: .repoRoot)
            groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
            language = try container.decodeIfPresent(String.self, forKey: .language)
            sandbox = try container.decodeIfPresent(SandboxLevel.self, forKey: .sandbox)
            sandboxRoot = try container.decodeIfPresent(String.self, forKey: .sandboxRoot)
            recordTraffic = try container.decodeIfPresent(Bool.self, forKey: .recordTraffic)
        }

        /// Tab label: the user's name if set; otherwise the running program's title for terminals,
        /// or the first non-empty line for notes.
        func title(fallback: String, terminalTitle: String?) -> String {
            if let name, !name.isEmpty { return name }
            switch kind {
            case .terminal:
                return Self.shortened(terminalTitle ?? "Terminal", limit: 32)
            case .file:
                return Self.shortened(filePath.map { ($0 as NSString).lastPathComponent } ?? fallback, limit: 28)
            case .traffic:
                return "Agent Traffic"
            case .notes:
                let line = text.split(separator: "\n").lazy
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty }
                return line.map { Self.shortened($0, limit: 22) } ?? fallback
            }
        }

        private static func shortened(_ text: String, limit: Int) -> String {
            text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
        }
    }

    private var selectedIndex: Int {
        cards.firstIndex { $0.id == selectedCardID } ?? 0
    }

    var currentCard: Card { cards[selectedIndex] }

    /// Text of the selected card.
    var currentText: String {
        get { cards[selectedIndex].text }
        set { cards[selectedIndex].text = newValue }
    }

    /// New cards join the current card's group, like a tab opened from a grouped tab in Chrome.
    @discardableResult
    func addCard(kind: Card.Kind = .notes, name: String? = nil, sandbox: SandboxConfig? = nil) -> UUID {
        var card = Card(kind: kind)
        card.name = name
        card.sandbox = sandbox?.level
        card.sandboxRoot = sandbox?.root.path
        card.recordTraffic = sandbox?.recordTraffic
        card.groupID = currentCard.groupID
        cards.append(card)
        keepGroupsTogether()
        selectedCardID = card.id
        return card.id
    }

    /// Shows a file in a viewer card, reusing the card if the file is already open.
    func openFileCard(_ url: URL, repoRoot: URL?) {
        if let existing = cards.first(where: { $0.kind == .file && $0.filePath == url.path }) {
            selectedCardID = existing.id
        } else {
            var card = Card(kind: .file, filePath: url.path, repoRoot: repoRoot?.path)
            card.groupID = currentCard.groupID
            cards.append(card)
            keepGroupsTogether()
            selectedCardID = card.id
        }
    }

    /// Shows the Agent Traffic card, creating it if needed.
    func openTrafficCard() {
        if let existing = cards.first(where: { $0.kind == .traffic }) {
            selectedCardID = existing.id
        } else {
            addCard(kind: .traffic)
        }
    }

    /// An empty name switches back to the automatic title.
    func rename(_ id: UUID, to name: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        cards[index].name = trimmed.isEmpty ? nil : trimmed
    }

    func removeCard(_ id: UUID) {
        guard cards.count > 1, let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards.remove(at: index)
        if selectedCardID == id {
            selectedCardID = cards[min(index, cards.count - 1)].id
        }
        removeEmptyGroups()
    }

    // MARK: - Highlighting

    func highlightTheme(for theme: Theme) -> String {
        highlightThemes[theme.rawValue] ?? theme.defaultHighlightTheme
    }

    func setHighlightTheme(_ name: String, for theme: Theme) {
        highlightThemes[theme.rawValue] = name
    }

    func setLanguage(_ language: String?, of cardID: UUID) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[index].language = language
    }

    // MARK: - Groups

    /// Puts a card into a new group with the next unused color and returns the group's ID.
    @discardableResult
    func newGroup(with cardID: UUID, name: String) -> UUID {
        let used = Set(groups.map(\.color))
        let color = GroupColor.allCases.first { !used.contains($0) }
            ?? GroupColor.allCases[groups.count % GroupColor.allCases.count]
        let group = CardGroup(name: name, color: color)
        groups.append(group)
        move(cardID, to: group.id)
        return group.id
    }

    /// Moves a card into a group, or out of any group with nil.
    func move(_ cardID: UUID, to groupID: UUID?) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[index].groupID = groupID
        keepGroupsTogether()
        removeEmptyGroups()
    }

    func renameGroup(_ groupID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].name = trimmed
    }

    func setColor(_ color: GroupColor, of groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].color = color
    }

    func toggleCollapsed(_ groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        // Collapsing the group of the selected card moves the selection outside it, as Chrome does.
        if !groups[index].isCollapsed, currentCard.groupID == groupID,
           let outside = cards.first(where: { $0.groupID != groupID }) {
            selectedCardID = outside.id
        }
        groups[index].isCollapsed.toggle()
    }

    /// Dissolves the group; its cards stay open.
    func ungroup(_ groupID: UUID) {
        for index in cards.indices where cards[index].groupID == groupID {
            cards[index].groupID = nil
        }
        groups.removeAll { $0.id == groupID }
    }

    func cardIDs(in groupID: UUID) -> [UUID] {
        cards.filter { $0.groupID == groupID }.map(\.id)
    }

    /// Keeps the cards of each group next to each other, at the position of the group's first card.
    private func keepGroupsTogether() {
        var ordered: [Card] = []
        var placed = Set<UUID>()
        for card in cards {
            guard let groupID = card.groupID else {
                ordered.append(card)
                continue
            }
            if placed.insert(groupID).inserted {
                ordered.append(contentsOf: cards.filter { $0.groupID == groupID })
            }
        }
        if ordered.map(\.id) != cards.map(\.id) { cards = ordered }
    }

    private func removeEmptyGroups() {
        let used = Set(cards.compactMap(\.groupID))
        if groups.contains(where: { !used.contains($0.id) }) {
            groups.removeAll { !used.contains($0.id) }
        }
    }

    struct CardGroup: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var color: GroupColor
        var isCollapsed = false
    }

    /// Group colors in the order they're handed out, like Chrome's tab groups.
    enum GroupColor: String, Codable, CaseIterable {
        case blue, red, yellow, green, pink, purple, cyan, orange, grey
    }

    // MARK: - Languages

    struct Language: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    /// A subset of the languages Apple's on-device Translation supports.
    static let languages: [Language] = [
        ("de", "German"), ("en", "English"), ("fr", "French"), ("es", "Spanish"),
        ("it", "Italian"), ("nl", "Dutch"), ("pl", "Polish"), ("tr", "Turkish"),
        ("pt", "Portuguese"), ("hi", "Hindi"), ("ja", "Japanese"), ("zh-Hans", "Chinese"),
    ].map { Language(code: $0.0, name: $0.1) }
}
