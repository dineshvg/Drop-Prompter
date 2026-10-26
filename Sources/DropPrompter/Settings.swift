import Foundation

/// User preferences, persisted in UserDefaults. The Google API key lives in the Keychain instead.
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var text: String { didSet { save(text, "text") } }
    @Published var fontSize: Double { didSet { save(fontSize, "fontSize") } }
    /// Background (blur) opacity only; text stays fully opaque, like iTerm2's transparency.
    @Published var opacity: Double { didSet { save(opacity, "opacity") } }
    @Published var widthFraction: Double { didSet { save(widthFraction, "widthFraction") } }
    @Published var heightFraction: Double { didSet { save(heightFraction, "heightFraction") } }
    @Published var targetLanguage: String { didSet { save(targetLanguage, "targetLanguage") } }
    @Published var showTranslation: Bool { didSet { save(showTranslation, "showTranslation") } }
    @Published var hideFromScreenShare: Bool { didSet { save(hideFromScreenShare, "hideFromScreenShare") } }
    /// Bumped when the API key changes, so the translation refreshes.
    @Published var apiKeyRevision = 0

    private init() {
        let d = UserDefaults.standard
        text = d.string(forKey: "text") ?? "Paste your talking points here.\n\n⌃⌥Space shows/hides this panel, Esc hides it."
        fontSize = d.object(forKey: "fontSize") as? Double ?? 20
        opacity = d.object(forKey: "opacity") as? Double ?? 0.8
        widthFraction = d.object(forKey: "widthFraction") as? Double ?? 0.6
        heightFraction = d.object(forKey: "heightFraction") as? Double ?? 0.45
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

    static let languages: [Language] = [
        ("de", "German"), ("en", "English"), ("fr", "French"), ("es", "Spanish"),
        ("it", "Italian"), ("nl", "Dutch"), ("pl", "Polish"), ("tr", "Turkish"),
        ("hi", "Hindi"), ("ta", "Tamil"), ("ja", "Japanese"), ("zh-CN", "Chinese"),
    ].map { Language(code: $0.0, name: $0.1) }
}
