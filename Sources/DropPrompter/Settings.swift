import Foundation

/// User preferences and note cards, persisted in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()

    /// Note cards; there is always at least one.
    @Published var cards: [Card] { didSet { saveCards() } }
    @Published var selectedCardID: UUID { didSet { save(selectedCardID.uuidString, "selectedCardID") } }
    @Published var fontSize: Double { didSet { save(fontSize, "fontSize") } }
    /// Background (blur) opacity only; text stays fully opaque, like iTerm2's transparency.
    @Published var opacity: Double { didSet { save(opacity, "opacity") } }
    @Published var widthFraction: Double { didSet { save(widthFraction, "widthFraction") } }
    @Published var heightFraction: Double { didSet { save(heightFraction, "heightFraction") } }
    /// Empty string means auto-detect.
    @Published var sourceLanguage: String { didSet { save(sourceLanguage, "sourceLanguage") } }
    @Published var targetLanguage: String { didSet { save(targetLanguage, "targetLanguage") } }
    @Published var showTranslation: Bool { didSet { save(showTranslation, "showTranslation") } }
    @Published var hideFromScreenShare: Bool { didSet { save(hideFromScreenShare, "hideFromScreenShare") } }
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
        let storedCards = d.data(forKey: "cards").flatMap { try? JSONDecoder().decode([Card].self, from: $0) } ?? []
        // Before cards existed, the single note was stored under "text".
        let initialCards = storedCards.isEmpty
            ? [Card(text: d.string(forKey: "text") ?? Self.welcomeText)]
            : storedCards
        cards = initialCards
        let storedSelection = d.string(forKey: "selectedCardID").flatMap(UUID.init(uuidString:))
        selectedCardID = initialCards.first { $0.id == storedSelection }?.id ?? initialCards[0].id
        fontSize = d.object(forKey: "fontSize") as? Double ?? 20
        opacity = d.object(forKey: "opacity") as? Double ?? 0.8
        widthFraction = d.object(forKey: "widthFraction") as? Double ?? 0.6
        heightFraction = d.object(forKey: "heightFraction") as? Double ?? 0.45
        sourceLanguage = d.string(forKey: "sourceLanguage") ?? ""
        targetLanguage = d.string(forKey: "targetLanguage") ?? "de"
        showTranslation = d.object(forKey: "showTranslation") as? Bool ?? false
        hideFromScreenShare = d.object(forKey: "hideFromScreenShare") as? Bool ?? true
        showWelcome = !d.bool(forKey: "hasSeenWelcome")
        hotKeyID = d.string(forKey: "hotKeyID") ?? HotKeyPreset.all[0].id
        dismissedHotKeyWarning = d.string(forKey: "dismissedHotKeyWarning") ?? ""
    }

    var hotKey: HotKeyPreset {
        HotKeyPreset.all.first { $0.id == hotKeyID } ?? HotKeyPreset.all[0]
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func saveCards() {
        if let data = try? JSONEncoder().encode(cards) { save(data, "cards") }
    }

    private static let welcomeText = """
        Paste your talking points here.

        ⌃Space shows/hides this panel, Esc hides it.
        + adds a card, ⌘1…⌘9 switches cards. Drag the bottom edge or corner to resize.
        """

    // MARK: - Cards

    struct Card: Codable, Identifiable, Equatable {
        enum Kind: String, Codable { case notes, terminal }

        var id = UUID()
        var kind: Kind
        /// Name the user gave the card; nil shows an automatic title.
        var name: String?
        var text: String

        init(kind: Kind = .notes, text: String = "") {
            self.kind = kind
            self.text = text
        }

        /// Cards saved before `kind` and `name` existed load as notes cards.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .notes
            name = try container.decodeIfPresent(String.self, forKey: .name)
            text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        }

        /// Tab label: the user's name if set; otherwise the running program's title for terminals,
        /// or the first non-empty line for notes.
        func title(fallback: String, terminalTitle: String?) -> String {
            if let name, !name.isEmpty { return name }
            switch kind {
            case .terminal:
                return Self.shortened(terminalTitle ?? "Terminal", limit: 32)
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

    func addCard(kind: Card.Kind = .notes) {
        let card = Card(kind: kind)
        cards.append(card)
        selectedCardID = card.id
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
