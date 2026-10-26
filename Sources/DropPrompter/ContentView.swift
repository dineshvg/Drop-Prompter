import AppKit
import ServiceManagement
import SwiftUI
import Translation

/// Hooks the SwiftUI resize handles up to the panel, which AppKit owns.
struct PanelResizer {
    let begin: () -> Void
    let update: (_ includeWidth: Bool) -> Void
    let end: () -> Void
}

struct ContentView: View {
    @ObservedObject var settings: Settings
    let resizer: PanelResizer
    let onClose: () -> Void

    @State private var translation = ""
    @State private var translationError: String?
    @State private var isTranslating = false
    @State private var showSettings = false
    @State private var isResizing = false
    @State private var cardPendingRemoval: UUID?
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
            cardStrip
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                TextEditor(text: $settings.currentText)
                    .font(.system(size: settings.fontSize))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .id(settings.selectedCardID) // fresh undo history and scroll position per card
                if settings.showTranslation {
                    Divider().opacity(0.4)
                    translationPane
                }
            }
            resizeBar
        }
        .overlay {
            if settings.showWelcome {
                WelcomeView { settings.showWelcome = false }
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
                if let url = GoogleTranslate.webURL(for: settings.currentText, target: settings.targetLanguage) {
                    NSWorkspace.shared.open(url)
                }
            } label: { Image(systemName: "globe") }
                .help("Open in translate.google.com (sends the text to Google)")

            Button { settings.showWelcome = true } label: { Image(systemName: "questionmark.circle") }
                .help("Welcome and keyboard shortcuts")
            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { SettingsPopover(settings: settings) }
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
                ForEach(Array(settings.cards.enumerated()), id: \.element.id) { index, card in
                    cardChip(card, index: index)
                }
                Button { settings.addCard() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("t", modifiers: .command)
                    .help("New card (⌘T)")
            }
        }
        .confirmationDialog(
            "Delete this card and its text?",
            isPresented: Binding(get: { cardPendingRemoval != nil }, set: { if !$0 { cardPendingRemoval = nil } })
        ) {
            Button("Delete Card", role: .destructive) {
                if let id = cardPendingRemoval { settings.removeCard(id) }
            }
        }
    }

    private func cardChip(_ card: Settings.Card, index: Int) -> some View {
        let isSelected = card.id == settings.selectedCardID
        return HStack(spacing: 6) {
            Button { settings.selectedCardID = card.id } label: {
                Text(card.title(fallback: "Card \(index + 1)"))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command) : nil)
            .help(index < 9 ? "⌘\(index + 1)" : "")
            if isSelected && settings.cards.count > 1 {
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
        .background(Capsule().fill(Color.white.opacity(isSelected ? 0.18 : 0.06)))
    }

    /// Empty cards close right away; cards with text ask first.
    private func requestRemoval(of card: Settings.Card) {
        if card.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.removeCard(card.id)
        } else {
            cardPendingRemoval = card.id
        }
    }

    // MARK: - Resize

    /// Bottom edge: the centre grip changes the height, the corner grip changes width and height.
    private var resizeBar: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(isResizing ? 0.5 : 0.25))
                .frame(width: 44, height: 5)
                .frame(width: 120, height: 14)
                .contentShape(Rectangle())
                .gesture(resizeGesture(includeWidth: false))
                .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
            HStack {
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 14)
                    .contentShape(Rectangle())
                    .gesture(resizeGesture(includeWidth: true))
                    .onHover { $0 ? NSCursor.crosshair.push() : NSCursor.pop() }
                    .help("Drag to resize")
            }
            .padding(.trailing, 6)
        }
        .frame(height: 14)
        .padding(.bottom, 2)
    }

    private func resizeGesture(includeWidth: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { _ in
                if !isResizing {
                    isResizing = true
                    resizer.begin()
                }
                resizer.update(includeWidth)
            }
            .onEnded { _ in
                isResizing = false
                resizer.end()
            }
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
    /// Read from the system each time the popover opens; macOS owns the login item.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemMessage: String?

    var body: some View {
        Form {
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
            loginItemMessage = "Allow Drop Prompter in System Settings › General › Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
        launchAtLogin = service.status == .enabled
    }
}
