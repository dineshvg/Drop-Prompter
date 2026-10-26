import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var settings: Settings
    let onClose: () -> Void

    @State private var translation = ""
    @State private var translationError: String?
    @State private var isTranslating = false
    @State private var showSettings = false

    private struct TranslationRequest: Equatable {
        let text: String
        let target: String
        let enabled: Bool
        let keyRevision: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                TextEditor(text: $settings.text)
                    .font(.system(size: settings.fontSize))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                if settings.showTranslation {
                    Divider().opacity(0.4)
                    translationPane
                }
            }
        }
        .task(id: translationRequest) {
            await translate(translationRequest)
        }
    }

    private var translationRequest: TranslationRequest {
        TranslationRequest(
            text: settings.text,
            target: settings.targetLanguage,
            enabled: settings.showTranslation,
            keyRevision: settings.apiKeyRevision
        )
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

            Spacer()

            Toggle(isOn: $settings.showTranslation) { Label("Translate", systemImage: "character.bubble") }
                .toggleStyle(.button)
            Picker("Target language", selection: $settings.targetLanguage) {
                ForEach(Settings.languages) { Text($0.name).tag($0.code) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 120)
            Button {
                if let url = GoogleTranslate.webURL(for: settings.text, target: settings.targetLanguage) {
                    NSWorkspace.shared.open(url)
                }
            } label: { Image(systemName: "globe") }
                .help("Open in translate.google.com (no API key needed)")

            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { SettingsPopover(settings: settings) }
            Button(action: onClose) { Image(systemName: "chevron.up") }
                .help("Hide (Esc / ⌃⌥Space)")
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
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

    private func translate(_ request: TranslationRequest) async {
        guard request.enabled else { return }
        guard let apiKey = Keychain.get(Keychain.googleApiKey), !apiKey.isEmpty else {
            translation = ""
            translationError = "Add a Google Cloud Translation API key in ⚙︎, or use the 🌐 button to open translate.google.com."
            return
        }
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            translation = ""
            translationError = nil
            return
        }
        // Debounce: a newer keystroke cancels this task before the request is sent.
        do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }

        isTranslating = true
        do {
            let result = try await GoogleTranslate.translate(request.text, to: request.target, apiKey: apiKey)
            translation = result
            translationError = nil
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            translationError = error.localizedDescription
        }
        if !Task.isCancelled { isTranslating = false }
    }
}

struct SettingsPopover: View {
    @ObservedObject var settings: Settings
    @State private var apiKey = Keychain.get(Keychain.googleApiKey) ?? ""

    var body: some View {
        Form {
            Section("Panel") {
                Slider(value: $settings.widthFraction, in: 0.3...1) { Text("Width") }
                Slider(value: $settings.heightFraction, in: 0.2...0.9) { Text("Height") }
                Toggle("Hide from screen sharing", isOn: $settings.hideFromScreenShare)
                Text("Best effort: some capture tools on recent macOS versions ignore this. Test it with your meeting app first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Google Cloud Translation") {
                SecureField("API key", text: $apiKey)
                HStack {
                    Button("Save key") {
                        Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Keychain.googleApiKey)
                        settings.apiKeyRevision += 1
                    }
                    Spacer()
                    Link("Get a key", destination: URL(string: "https://console.cloud.google.com/apis/library/translate.googleapis.com")!)
                }
                Text("Stored in your login Keychain. Text you translate is sent to Google.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
    }
}
