import AppKit
import SwiftUI

// MARK: - Read-only code text

/// Monospaced, selectable, non-editable text without line wrapping. NSTextView handles large files far
/// better than SwiftUI's Text.
struct ReadOnlyText: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.isHorizontallyResizable = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.textStorage?.isEqual(to: text) != true
        else { return }
        textView.textStorage?.setAttributedString(text)
    }
}

@MainActor
enum CodeText {
    static func plain(_ text: String, size: CGFloat, theme: Theme) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: theme.codeTextColor,
        ])
    }

    /// Unified diff with added lines in green, removed in red and hunk headers in blue.
    static func diff(_ text: String, size: CGFloat, theme: Theme) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let result = NSMutableAttributedString()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let color: NSColor
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ")
                || line.hasPrefix("new file") || line.hasPrefix("deleted file") {
                color = .secondaryLabelColor
            } else if line.hasPrefix("+") {
                color = .systemGreen
            } else if line.hasPrefix("-") {
                color = .systemRed
            } else if line.hasPrefix("@@") {
                color = .systemBlue
            } else {
                color = theme.codeTextColor
            }
            result.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        return result
    }
}

// MARK: - Changes

/// `git status` of the terminal card's repository; selecting a file shows its diff.
struct ChangesPane: View {
    let repo: RepoStatus
    let theme: Theme
    let codeSize: CGFloat
    let editorBundleID: String
    let onOpenFile: (URL) -> Void

    @State private var selectedPath: String?
    @State private var diff: NSAttributedString?

    private struct DiffRequest: Equatable {
        let path: String?
        let changes: [FileChange]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let path = selectedPath, repo.changes.contains(where: { $0.path == path }) {
                diffView(path)
            } else {
                changesList
            }
        }
        // Reloads when another file is selected and whenever the repository status changes.
        .task(id: DiffRequest(path: selectedPath, changes: repo.changes)) {
            await loadDiff()
        }
    }

    private var changesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Changes").font(.headline)
                Spacer()
                Text("\(repo.changes.count)").foregroundStyle(.secondary)
            }
            .padding(10)
            Divider().opacity(0.4)
            if repo.changes.isEmpty {
                Text("No changes. The working tree is clean.")
                    .foregroundStyle(.secondary)
                    .padding(10)
                Spacer()
            } else {
                List(repo.changes) { change in
                    HStack(spacing: 8) {
                        StatusBadge(change: change)
                        Text(change.path)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selectedPath = change.path }
                    .help(change.path)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func diffView(_ path: String) -> some View {
        let fileURL = repo.root.appendingPathComponent(path)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { selectedPath = nil } label: { Image(systemName: "chevron.left") }
                    .help("Back to changes")
                Text(path)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(path)
                Spacer()
                Button { onOpenFile(fileURL) } label: { Image(systemName: "doc.text") }
                    .help("View the whole file")
                Button { CodeEditors.open(fileURL, with: editorBundleID) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .help("Open in \(CodeEditors.name(for: editorBundleID))")
            }
            .buttonStyle(.borderless)
            .padding(10)
            Divider().opacity(0.4)
            if let diff {
                ReadOnlyText(text: diff)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func loadDiff() async {
        guard let path = selectedPath, let change = repo.changes.first(where: { $0.path == path }) else {
            diff = nil
            return
        }
        let text = await Repo.diff(for: change, in: repo.root)
        guard !Task.isCancelled else { return }
        diff = CodeText.diff(text.isEmpty ? "No textual changes." : text, size: codeSize, theme: theme)
    }
}

struct StatusBadge: View {
    let change: FileChange

    private var color: Color {
        switch change.badge {
        case "U", "A": return .green
        case "D": return .red
        case "R", "C": return .blue
        default: return .orange
        }
    }

    var body: some View {
        Text(change.badge)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
            .help(change.isUntracked ? "Untracked" : "git status: \(change.code)")
    }
}

// MARK: - File viewer

/// Read-only view of one file, shown as its own card.
struct FileViewer: View {
    let url: URL
    let theme: Theme
    let codeSize: CGFloat
    let editorBundleID: String

    @State private var content: Repo.FileContent?
    @State private var reloads = 0

    private struct LoadRequest: Equatable {
        let url: URL
        let reloads: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(url.path)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
                    .help(url.path)
                Spacer()
                Button { reloads += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload")
                Button { CodeEditors.reveal(url) } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
                Button { CodeEditors.open(url, with: editorBundleID) } label: {
                    Label("Open in \(CodeEditors.name(for: editorBundleID))", systemImage: "arrow.up.forward.app")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider().opacity(0.4)
            switch content {
            case .text(let text):
                ReadOnlyText(text: CodeText.plain(text, size: codeSize, theme: theme))
            case .message(let message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Loads on open, when switching back to the card, and on Reload.
        .task(id: LoadRequest(url: url, reloads: reloads)) {
            content = await Repo.load(url)
        }
    }
}

// MARK: - Quick Open

/// ⌘P: type part of a file name, Return opens it as a viewer card.
struct QuickOpenView: View {
    let root: URL
    let onOpen: (URL) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var files: [String] = []
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private var matches: [String] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return Array(files.prefix(100)) }
        return files
            .compactMap { path -> (path: String, score: Int)? in
                guard let score = Self.score(path.lowercased(), for: needle) else { return nil }
                return (path, score)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.path.count < $1.path.count }
            .prefix(100)
            .map { $0.path }
    }

    /// Fuzzy match: every typed character must appear in order. Matches in the file name rank higher.
    private static func score(_ path: String, for needle: String) -> Int? {
        let fileName = path.split(separator: "/").last.map(String.init) ?? path
        if fileName.hasPrefix(needle) { return 300 }
        if fileName.contains(needle) { return 200 }
        if path.contains(needle) { return 100 }
        var remaining = Substring(needle)
        for character in path where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return 10 }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Open a file in \(root.lastPathComponent)…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($fieldFocused)
                .onAppear { fieldFocused = true }
                .onChange(of: query) { _, _ in selection = 0 }
                .onSubmit { open(at: selection) }
                .onExitCommand(perform: onCancel)
                .onKeyPress(.downArrow) {
                    selection = min(selection + 1, max(matches.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selection = max(selection - 1, 0)
                    return .handled
                }
            Divider().opacity(0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element) { index, path in
                            Text(path)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(index == selection ? Color.accentColor.opacity(0.25) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture { open(at: index) }
                                .id(index)
                        }
                    }
                }
                .onChange(of: selection) { _, index in proxy.scrollTo(index) }
            }
        }
        .frame(maxWidth: 560, maxHeight: 360)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThickMaterial))
        .shadow(radius: 20)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.15).onTapGesture(perform: onCancel))
        .task { files = await Repo.files(in: root) }
    }

    private func open(at index: Int) {
        let current = matches
        guard current.indices.contains(index) else { return }
        onOpen(root.appendingPathComponent(current[index]))
    }
}
