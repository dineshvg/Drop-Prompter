import Foundation

/// Opens text in the Google Translate website, as an alternative to the on-device translation.
enum GoogleTranslate {
    /// Long texts are truncated to keep the URL within limits.
    static func webURL(for text: String, target: String) -> URL? {
        var components = URLComponents(string: "https://translate.google.com/")
        components?.queryItems = [
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: target == "zh-Hans" ? "zh-CN" : target),
            URLQueryItem(name: "text", value: String(text.prefix(5000))),
            URLQueryItem(name: "op", value: "translate"),
        ]
        return components?.url
    }
}
