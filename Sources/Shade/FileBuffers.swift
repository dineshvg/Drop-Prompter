import AppKit
import SwiftUI

/// Text of open file cards, kept outside the views so unsaved edits survive switching cards and hiding
/// the panel. Watches the files on disk and resolves conflicts with programs editing them too.
@MainActor
final class FileBuffers: ObservableObject {
    static let shared = FileBuffers()

    struct Buffer {
        var text: String
        /// The file on disk as last loaded or saved.
        var diskText: String
        var diskModified: Date?
        /// A newer version on disk that arrived while there were unsaved edits.
        var pendingDisk: (text: String, modified: Date?)? = nil

        var isDirty: Bool { text != diskText }
        var changedOnDisk: Bool { pendingDisk != nil }
    }

    @Published private(set) var buffers: [UUID: Buffer] = [:]
    /// Why a card's file can't be edited (missing, binary, too large, not UTF-8).
    @Published private(set) var messages: [UUID: String] = [:]

    func isDirty(_ cardID: UUID) -> Bool { buffers[cardID]?.isDirty == true }

    var dirtyCount: Int { buffers.values.filter { $0.isDirty }.count }

    /// Loads the file if it changed on disk. Without unsaved edits the new version replaces the buffer;
    /// with edits it's held back until the user chooses (see `acceptDiskVersion` and `keepMine`).
    func refresh(_ cardID: UUID, url: URL) async {
        if let buffer = buffers[cardID],
           Repo.modificationDate(of: url) == (buffer.pendingDisk?.modified ?? buffer.diskModified) {
            return
        }
        switch await Repo.load(url) {
        case .message(let message):
            // Keep an open buffer if the file disappeared, so edits can still be saved.
            if buffers[cardID] == nil { messages[cardID] = message }
        case .text(let text, let modified):
            messages[cardID] = nil
            guard var buffer = buffers[cardID], buffer.isDirty else {
                buffers[cardID] = Buffer(text: text, diskText: text, diskModified: modified)
                return
            }
            if text == buffer.text || text == buffer.diskText {
                // Same content as the edits, or only touched: nothing to decide.
                buffer.diskText = text
                buffer.diskModified = modified
                buffer.pendingDisk = nil
            } else {
                buffer.pendingDisk = (text, modified)
            }
            buffers[cardID] = buffer
        }
    }

    func update(_ cardID: UUID, text: String) {
        buffers[cardID]?.text = text
    }

    func revert(_ cardID: UUID) {
        guard var buffer = buffers[cardID] else { return }
        if let pending = buffer.pendingDisk {
            buffer = Buffer(text: pending.text, diskText: pending.text, diskModified: pending.modified)
        } else {
            buffer.text = buffer.diskText
        }
        buffers[cardID] = buffer
    }

    func acceptDiskVersion(_ cardID: UUID) {
        guard let pending = buffers[cardID]?.pendingDisk else { return }
        buffers[cardID] = Buffer(text: pending.text, diskText: pending.text, diskModified: pending.modified)
    }

    /// Keeps the edits; the next save replaces the newer version on disk without asking again.
    func keepMine(_ cardID: UUID) {
        guard var buffer = buffers[cardID], let pending = buffer.pendingDisk else { return }
        buffer.diskText = pending.text
        buffer.diskModified = pending.modified
        buffer.pendingDisk = nil
        buffers[cardID] = buffer
    }

    /// Writes the buffer. Returns false without writing when the file changed on disk since it was loaded
    /// and `overwrite` is false, so the caller can ask first.
    func save(_ cardID: UUID, to url: URL, overwrite: Bool) throws -> Bool {
        guard let buffer = buffers[cardID] else { return true }
        if !overwrite, buffer.changedOnDisk || Repo.modificationDate(of: url) != buffer.diskModified {
            return false
        }
        // Written in place rather than atomically, so the file keeps its permissions (e.g. executable scripts).
        try Data(buffer.text.utf8).write(to: url)
        buffers[cardID] = Buffer(text: buffer.text, diskText: buffer.text, diskModified: Repo.modificationDate(of: url))
        return true
    }

    func close(_ cardID: UUID) {
        buffers[cardID] = nil
        messages[cardID] = nil
    }
}

/// Plain-text code editor: monospaced, no wrapping, undo, and none of the automatic substitutions that
/// would break code (smart quotes, dashes, spelling correction). With `highlighting`, it colors the code
/// with highlight.js as you type.
struct CodeEditorView: NSViewRepresentable {
    struct Highlighting: Equatable {
        let language: String
        let theme: String
    }

    let text: String
    let font: NSFont
    let color: NSColor
    /// Nil shows plain text.
    let highlighting: Highlighting?
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // Highlighting needs Highlightr's text storage. Swapping it in also switches the view to TextKit 1.
        if let highlightr = SyntaxHighlighting.shared.highlightr {
            let storage = CodeAttributedString(highlightr: highlightr)
            textView.layoutManager?.replaceTextStorage(storage)
            context.coordinator.storage = storage
        }
        textView.string = text
        applyAppearance(to: textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onChange = onChange
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Only when the text changed from outside (reload, revert), not on every keystroke.
        if textView.string != text {
            let cursor = min(textView.selectedRange().location, (text as NSString).length)
            textView.string = text
            textView.setSelectedRange(NSRange(location: cursor, length: 0))
            if context.coordinator.storage?.language == nil {
                textView.font = font
                textView.textColor = color
            }
        }
        applyAppearance(to: textView, coordinator: context.coordinator)
    }

    /// Applies font, color, theme and language, but only when one of them changed: re-highlighting a whole
    /// file on every SwiftUI update would be slow.
    private func applyAppearance(to textView: NSTextView, coordinator: Coordinator) {
        let appearance = Coordinator.Appearance(highlighting: highlighting, fontSize: font.pointSize, color: color)
        guard coordinator.appearance != appearance else { return }
        coordinator.appearance = appearance
        textView.insertionPointColor = color
        textView.typingAttributes = [.font: font, .foregroundColor: color]
        if let highlighting, let storage = coordinator.storage,
           SyntaxHighlighting.shared.use(theme: highlighting.theme, font: font) {
            storage.language = highlighting.language // re-highlights the whole text
        } else {
            coordinator.storage?.language = nil
            textView.font = font
            textView.textColor = color
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        struct Appearance: Equatable {
            let highlighting: Highlighting?
            let fontSize: CGFloat
            let color: NSColor
        }

        var onChange: (String) -> Void
        var storage: CodeAttributedString?
        var appearance: Appearance?

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onChange(textView.string)
        }
    }
}
