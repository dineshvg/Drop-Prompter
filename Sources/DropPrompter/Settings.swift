import Foundation

/// User preferences, persisted in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var text: String { didSet { save(text, "text") } }
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

    private init() {
        let d = UserDefaults.standard
        text = d.string(forKey: "text") ?? "Paste your talking points here.\n\n⌃Space shows/hides this panel, Esc hides it."
        fontSize = d.object(forKey: "fontSize") as? Double ?? 20
        opacity = d.object(forKey: "opacity") as? Double ?? 0.8
        widthFraction = d.object(forKey: "widthFraction") as? Double ?? 0.6
        heightFraction = d.object(forKey: "heightFraction") as? Double ?? 0.45
        sourceLanguage = d.string(forKey: "sourceLanguage") ?? ""
        targetLanguage = d.string(forKey: "targetLanguage") ?? "de"
        showTranslation = d.object(forKey: "showTranslation") as? Bool ?? false
        hideFromScreenShare = d.object(forKey: "hideFromScreenShare") as? Bool ?? true
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

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
