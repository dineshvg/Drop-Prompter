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
        var id = UUID()
        var text: String

        /// First non-empty line, shortened; used as the card's tab label.
        func title(fallback: String) -> String {
            let line = text.split(separator: "\n").lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            guard let line else { return fallback }
            return line.count > 22 ? String(line.prefix(21)) + "…" : line
        }
    }

    private var selectedIndex: Int {
        cards.firstIndex { $0.id == selectedCardID } ?? 0
    }

    /// Text of the selected card.
    var currentText: String {
        get { cards[selectedIndex].text }
        set { cards[selectedIndex].text = newValue }
    }

    func addCard() {
        let card = Card(text: "")
        cards.append(card)
        selectedCardID = card.id
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
