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

/// Read-only view of one file, shown as its own card. A changed file can switch between its diff and
/// the whole file. The view reloads by itself when the file changes on disk.
struct FileViewer: View {
    let url: URL
    /// Uncommitted change of this file, if any.
    let change: FileChange?
    let repoRoot: URL?
    let theme: Theme
    let codeSize: CGFloat
    let editorBundleID: String

    private enum Display {
        case text(NSAttributedString)
        case message(String)
    }

    @State private var display: Display?
    @State private var preferDiff = true
    @State private var reloads = 0

    private var showsDiff: Bool { preferDiff && change != nil && repoRoot != nil }

    private struct LoadRequest: Equatable {
        let url: URL
        let showsDiff: Bool
        let changeCode: String?
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
                if change != nil, repoRoot != nil {
                    Picker("View", selection: $preferDiff) {
                        Text("Changes").tag(true)
                        Text("File").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
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
            switch display {
            case .text(let text):
                ReadOnlyText(text: text)
            case .message(let message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: LoadRequest(url: url, showsDiff: showsDiff, changeCode: change?.code, reloads: reloads)) {
            // Loads now, then again whenever the file's modification date changes (an agent editing it).
            var lastModified: Date?
            var loaded = false
            while !Task.isCancelled {
                let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                if !loaded || modified != lastModified {
                    lastModified = modified
                    loaded = true
                    let rendered = await render()
                    guard !Task.isCancelled else { return }
                    display = rendered
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func render() async -> Display {
        if showsDiff, let change, let repoRoot {
            let text = await Repo.diff(for: change, in: repoRoot)
            return .text(CodeText.diff(text.isEmpty ? "No textual changes." : text, size: codeSize, theme: theme))
        }
        switch await Repo.load(url) {
        case .text(let text): return .text(CodeText.plain(text, size: codeSize, theme: theme))
        case .message(let message): return .message(message)
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
