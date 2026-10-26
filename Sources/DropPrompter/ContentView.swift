import AppKit
import SwiftUI
import Translation

struct ContentView: View {
    @ObservedObject var settings: Settings
    let onClose: () -> Void

    @State private var translation = ""
    @State private var translationError: String?
    @State private var isTranslating = false
    @State private var showSettings = false
    /// Setting or invalidating this makes `.translationTask` run with a fresh session.
    @State private var translationConfig: TranslationSession.Configuration?

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
            await scheduleTranslation(translationRequest)
        }
        .translationTask(translationConfig) { session in
            await translate(using: session)
        }
    }

    private var translationRequest: TranslationRequest {
        TranslationRequest(
            text: settings.text,
            source: settings.sourceLanguage,
            target: settings.targetLanguage,
            enabled: settings.showTranslation
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
                if let url = GoogleTranslate.webURL(for: settings.text, target: settings.targetLanguage) {
                    NSWorkspace.shared.open(url)
                }
            } label: { Image(systemName: "globe") }
                .help("Open in translate.google.com (sends the text to Google)")

            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { SettingsPopover(settings: settings) }
            Button(action: onClose) { Image(systemName: "chevron.up") }
                .help("Hide (Esc / ⌃Space)")
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
        var lines = settings.text.components(separatedBy: "\n")
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
}
