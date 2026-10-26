import Foundation

/// Google Cloud Translation API (v2, "Basic") client plus a no-key fallback to translate.google.com.
enum GoogleTranslate {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Response: Decodable {
        struct Payload: Decodable {
            struct Translation: Decodable { let translatedText: String }
            let translations: [Translation]
        }
        let data: Payload
    }

    private struct ErrorResponse: Decodable {
        struct Body: Decodable { let message: String }
        let error: Body
    }

    static func translate(_ text: String, to target: String, apiKey: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://translation.googleapis.com/language/translate/v2")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Key in a header rather than the query string, so it does not end up in URL logs.
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.httpBody = try JSONEncoder().encode(["q": text, "target": target, "format": "text"])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.message
            throw Failure(message: message ?? "HTTP \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.data.translations.map(\.translatedText).joined(separator: "\n")
    }

    /// Opens the text in the Google Translate website. Needs no API key; long texts are truncated.
    static func webURL(for text: String, target: String) -> URL? {
        var components = URLComponents(string: "https://translate.google.com/")
        components?.queryItems = [
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "text", value: String(text.prefix(5000))),
            URLQueryItem(name: "op", value: "translate"),
        ]
        return components?.url
    }
}
