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

// MARK: - Watching a repository

/// Keeps the status and file list of the repository shown in the sidebar and file cards up to date.
@MainActor
final class RepoWatcher: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var status: RepoStatus?
    @Published private(set) var files: [String] = []
    @Published private(set) var tree: [FileNode] = []

    private var loop: Task<Void, Never>?

    /// Starts polling `newRoot` (status every 2 seconds, file list every 10), or stops for nil.
    func watch(_ newRoot: URL?) {
        guard newRoot != root else { return }
        loop?.cancel()
        root = newRoot
        status = nil
        files = []
        tree = []
        guard let newRoot else { return }
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                let status = await Repo.status(at: newRoot)
                guard let self, !Task.isCancelled else { return }
                if self.status != status { self.status = status }
                if tick % 5 == 0 {
                    let files = await Repo.files(in: newRoot)
                    if !Task.isCancelled, self.files != files {
                        self.files = files
                        self.tree = FileTree.build(files)
                    }
                }
                tick += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// The uncommitted change for an absolute file path, if any.
    func change(forFileAt path: String) -> FileChange? {
        guard let root, let status else { return nil }
        return status.changes.first { root.appendingPathComponent($0.path).path == path }
    }
}

struct FileNode: Identifiable, Hashable {
    /// Relative path; folders end in "/".
    let id: String
    let name: String
    /// Children for folders, nil for files.
    var children: [FileNode]?

    var isFolder: Bool { children != nil }
}

enum FileTree {
    static func build(_ paths: [String]) -> [FileNode] {
        let root = Folder()
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            var folder = root
            for part in parts.dropLast() { folder = folder.child(part) }
            if let name = parts.last { folder.files.append(name) }
        }
        return root.nodes(prefix: "")
    }

    private final class Folder {
        var folders: [String: Folder] = [:]
        var files: [String] = []

        func child(_ name: String) -> Folder {
            if let existing = folders[name] { return existing }
            let folder = Folder()
            folders[name] = folder
            return folder
        }

        /// Folders first, then files, each in Finder order.
        func nodes(prefix: String) -> [FileNode] {
            let byName: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
            let folderNodes = folders.keys.sorted(by: byName).map { name in
                FileNode(id: prefix + name + "/", name: name,
                         children: folders[name]?.nodes(prefix: prefix + name + "/") ?? [])
            }
            let fileNodes = files.sorted(by: byName).map { name in
                FileNode(id: prefix + name, name: name, children: nil)
            }
            return folderNodes + fileNodes
        }
    }
}

/// Every typed character must appear in order. Matches in the file name rank higher.
enum FuzzyMatch {
    static func score(_ path: String, for query: String) -> Int? {
        let path = path.lowercased()
        let needle = query.lowercased()
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

    static func best(_ paths: [String], for query: String, limit: Int) -> [String] {
        paths
            .compactMap { path -> (path: String, score: Int)? in
                score(path, for: query).map { (path, $0) }
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.path.count < $1.path.count }
            .prefix(limit)
            .map { $0.path }
    }
}

// MARK: - Sidebar

/// Pinnable repository sidebar: changes and files of the current repository. It sits next to the cards,
/// so it stays visible while switching between them.
struct RepoSidebar: View {
    @ObservedObject var watcher: RepoWatcher
    /// Absolute path of the file shown in the current card, highlighted in the lists.
    let openFilePath: String?
    let isOnRight: Bool
    let onOpen: (URL) -> Void
    let onSwitchSide: () -> Void
    let onHide: () -> Void

    private enum Tab { case changes, files }

    @State private var tab = Tab.changes
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            if let root = watcher.root {
                Picker("Show", selection: $tab) {
                    Text("Changes (\(watcher.status?.changes.count ?? 0))").tag(Tab.changes)
                    Text("Files").tag(Tab.files)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                switch tab {
                case .changes: changesList(root)
                case .files: filesList(root)
                }
            } else {
                Text("Open a terminal card in a git repository, or a file from one, and its changes and files show up here.")
                    .foregroundStyle(.secondary)
                    .padding(12)
                Spacer()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let root = watcher.root {
                Label(watcher.status?.branch ?? "…", systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                Text(root.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(root.path)
            } else {
                Text("Repository").font(.headline)
            }
            Spacer()
            Button(action: onSwitchSide) {
                Image(systemName: isOnRight ? "sidebar.left" : "sidebar.right")
            }
            .help(isOnRight ? "Move to the left" : "Move to the right")
            Button(action: onHide) { Image(systemName: "xmark") }
                .help("Hide sidebar (⌘B)")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func changesList(_ root: URL) -> some View {
        Group {
            if let changes = watcher.status?.changes, !changes.isEmpty {
                List(changes) { change in
                    HStack(spacing: 8) {
                        StatusBadge(change: change)
                        fileLabel(change.path)
                    }
                    .padding(.vertical, 1)
                    .listRowBackground(rowBackground(root.appendingPathComponent(change.path)))
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(root.appendingPathComponent(change.path)) }
                    .help(change.path)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            } else {
                Text(watcher.status == nil ? "Reading repository…" : "No changes. The working tree is clean.")
                    .foregroundStyle(.secondary)
                    .padding(12)
                Spacer()
            }
        }
    }

    private func filesList(_ root: URL) -> some View {
        VStack(spacing: 0) {
            TextField("Filter files", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            if filter.isEmpty {
                List(watcher.tree, children: \.children) { node in
                    Label(node.name, systemImage: node.isFolder ? "folder" : "doc")
                        .lineLimit(1)
                        .listRowBackground(node.isFolder ? nil : rowBackground(root.appendingPathComponent(node.id)))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !node.isFolder { onOpen(root.appendingPathComponent(node.id)) }
                        }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            } else {
                List(FuzzyMatch.best(watcher.files, for: filter, limit: 200), id: \.self) { path in
                    fileLabel(path)
                        .listRowBackground(rowBackground(root.appendingPathComponent(path)))
                        .contentShape(Rectangle())
                        .onTapGesture { onOpen(root.appendingPathComponent(path)) }
                        .help(path)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// File name first, folder dimmed after it, so the name stays readable in a narrow sidebar.
    private func fileLabel(_ path: String) -> some View {
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        return HStack(spacing: 6) {
            Text(name).lineLimit(1)
            if !folder.isEmpty {
                Text(folder)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    private func rowBackground(_ url: URL) -> Color? {
        url.path == openFilePath ? Color.accentColor.opacity(0.25) : nil
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

/// One file as its own card. File mode edits it (⌘S saves); for a changed file, Changes mode shows the
/// read-only diff. Reloads by itself when the file changes on disk.
struct FileViewer: View {
    let cardID: UUID
    let url: URL
    /// Uncommitted change of this file, if any.
    let change: FileChange?
    let repoRoot: URL?
    let theme: Theme
    let codeSize: CGFloat
    let editorBundleID: String
    /// Language chosen for this card (nil: from the file name; `Card.plainText`: off).
    let languageOverride: String?
    let highlightingEnabled: Bool
    let highlightTheme: String
    let onSetLanguage: (String?) -> Void
    @ObservedObject var buffers: FileBuffers

    @State private var diff: NSAttributedString?
    @State private var preferDiff = true
    @State private var reloads = 0
    @State private var confirmOverwrite = false
    @State private var saveError: String?

    private var showsDiff: Bool { preferDiff && change != nil && repoRoot != nil }
    private var buffer: FileBuffers.Buffer? { buffers.buffers[cardID] }
    private var isDirty: Bool { buffer?.isDirty == true }

    private var detectedLanguage: String? { SyntaxHighlighting.language(forFileAt: url.path) }

    /// Language actually used for highlighting; nil shows plain text.
    private var language: String? {
        guard highlightingEnabled, languageOverride != Settings.Card.plainText,
              (buffer?.text.utf8.count ?? 0) <= SyntaxHighlighting.maxHighlightedSize
        else { return nil }
        return languageOverride ?? detectedLanguage
    }

    private struct LoadRequest: Equatable {
        let url: URL
        let showsDiff: Bool
        let changeCode: String?
        let reloads: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if buffer?.changedOnDisk == true {
                diskChangedBanner
            }
            Divider().opacity(0.4)
            content
        }
        .task(id: LoadRequest(url: url, showsDiff: showsDiff, changeCode: change?.code, reloads: reloads)) {
            // Now, then every 2 seconds: picks up changes on disk (an agent editing the file).
            var diffModified: Date?
            var diffLoaded = false
            while !Task.isCancelled {
                await buffers.refresh(cardID, url: url)
                let modified = Repo.modificationDate(of: url)
                if showsDiff, let change, let repoRoot, !diffLoaded || modified != diffModified {
                    diffModified = modified
                    diffLoaded = true
                    let text = await Repo.diff(for: change, in: repoRoot)
                    guard !Task.isCancelled else { return }
                    diff = CodeText.diff(text.isEmpty ? "No textual changes." : text, size: codeSize, theme: theme)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .alert("The file changed on disk", isPresented: $confirmOverwrite) {
            Button("Overwrite", role: .destructive) { save(overwrite: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saving replaces the newer version on disk with yours.")
        }
        .alert(
            "Couldn't save the file",
            isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text(url.path)
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(.secondary)
                .help(url.path)
            if isDirty {
                Text("Edited")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Spacer()
            if change != nil, repoRoot != nil {
                Picker("View", selection: $preferDiff) {
                    Text("Changes").tag(true)
                    Text("File").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if !showsDiff, buffer != nil, highlightingEnabled {
                languageMenu
            }
            if !showsDiff, buffer != nil {
                Button("Revert") { buffers.revert(cardID) }
                    .disabled(!isDirty && buffer?.changedOnDisk != true)
                    .help("Discard your edits")
                Button("Save") { save(overwrite: false) }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty)
                    .help("Save (⌘S)")
            }
            Button { reloads += 1 } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload")
            Button { CodeEditors.reveal(url) } label: { Image(systemName: "folder") }
                .help("Show in Finder")
            Button { CodeEditors.open(url, with: editorBundleID) } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .help("Open in \(CodeEditors.name(for: editorBundleID))")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var languageMenu: some View {
        Menu {
            Button("Automatic (\(detectedLanguage ?? "Plain Text"))") { onSetLanguage(nil) }
            Button("Plain Text") { onSetLanguage(Settings.Card.plainText) }
            Divider()
            ForEach(SyntaxHighlighting.shared.languages, id: \.self) { name in
                Button(name) { onSetLanguage(name) }
            }
        } label: {
            Text(language ?? "Plain Text")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help((buffer?.text.utf8.count ?? 0) > SyntaxHighlighting.maxHighlightedSize
              ? "This file is too large to highlight"
              : "Highlighting language")
    }

    private var diskChangedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("This file changed on disk while you were editing it.")
                .font(.callout)
            Spacer()
            Button("Load Disk Version") { buffers.acceptDiskVersion(cardID) }
                .help("Discard your edits and show the version on disk")
            Button("Keep Mine") { buffers.keepMine(cardID) }
                .help("Keep your edits; saving replaces the version on disk")
        }
        .padding(8)
        .background(Color.yellow.opacity(0.12))
    }

    @ViewBuilder
    private var content: some View {
        if showsDiff {
            VStack(spacing: 0) {
                if isDirty {
                    Text("The diff shows the file on disk. Your unsaved edits aren't included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                if let diff {
                    ReadOnlyText(text: diff)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else if let buffer {
            CodeEditorView(
                text: buffer.text,
                font: NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular),
                color: theme.codeTextColor,
                highlighting: language.map { CodeEditorView.Highlighting(language: $0, theme: highlightTheme) },
                onChange: { buffers.update(cardID, text: $0) }
            )
        } else if let message = buffers.messages[cardID] {
            Text(message)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func save(overwrite: Bool) {
        do {
            if try !buffers.save(cardID, to: url, overwrite: overwrite) {
                confirmOverwrite = true
            }
        } catch {
            saveError = error.localizedDescription
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
        query.isEmpty ? Array(files.prefix(100)) : FuzzyMatch.best(files, for: query, limit: 100)
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
