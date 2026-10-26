import AppKit
import SwiftUI

/// Syntax highlighting for file cards, built on highlight.js (via the vendored Highlightr). Finds the bundled
/// script and themes, picks a file's language, and downloads more themes.
@MainActor
final class SyntaxHighlighting: ObservableObject {
    static let shared = SyntaxHighlighting()

    /// highlight.js release the bundled script comes from; downloaded themes must match it.
    static let highlightJSVersion = "11.11.1"
    /// Files larger than this stay plain, so typing stays fast.
    static let maxHighlightedSize = 500_000

    /// Nil when highlight.js couldn't be loaded; files then show as plain text.
    private(set) var highlightr: Highlightr?
    /// Themes available right now: bundled ones plus downloaded ones.
    @Published private(set) var installedThemes: [String] = []
    /// Every theme of this highlight.js release, for "Get More Themes".
    @Published private(set) var catalog: [String] = []
    @Published private(set) var languages: [String] = []
    @Published private(set) var downloading: Set<String> = []
    @Published var downloadError: String?

    private var bundledThemes: Set<String> = []

    private init() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: Self.userThemesDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: Self.userLanguagesDirectory, withIntermediateDirectories: true)
        guard let bundled = Self.bundledDirectory else { return }

        let bundledThemesDirectory = bundled.appendingPathComponent("themes")
        let languageFiles = ((try? fileManager.contentsOfDirectory(
            at: Self.userLanguagesDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "js" }
        highlightr = Highlightr(
            highlightPath: bundled.appendingPathComponent("highlight.min.js").path,
            themeDirectories: [bundledThemesDirectory, Self.userThemesDirectory],
            languageFiles: languageFiles
        )
        highlightr?.ignoreIllegals = true
        languages = highlightr?.supportedLanguages().sorted() ?? []
        bundledThemes = Set(((try? fileManager.contentsOfDirectory(atPath: bundledThemesDirectory.path)) ?? [])
            .map { $0.replacingOccurrences(of: ".min.css", with: "") })
        catalog = ((try? String(contentsOf: bundled.appendingPathComponent("theme-catalog.txt"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        reloadInstalledThemes()
    }

    // MARK: - Files

    /// Shade.app/Contents/Resources/Highlighting, or the repository's Resources/Highlighting with `swift run`.
    static let bundledDirectory: URL? = {
        let fileManager = FileManager.default
        if let inApp = Bundle.main.resourceURL?.appendingPathComponent("Highlighting"),
           fileManager.fileExists(atPath: inApp.appendingPathComponent("highlight.min.js").path) {
            return inApp
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Shade
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent()
        let inRepository = repository.appendingPathComponent("Resources/Highlighting")
        return fileManager.fileExists(atPath: inRepository.path) ? inRepository : nil
    }()

    /// ~/Library/Application Support/Shade/Highlighting: downloaded themes and custom languages.
    static let userDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shade/Highlighting", isDirectory: true)
    static var userThemesDirectory: URL { userDirectory.appendingPathComponent("themes", isDirectory: true) }
    static var userLanguagesDirectory: URL { userDirectory.appendingPathComponent("languages", isDirectory: true) }

    // MARK: - Themes

    func reloadInstalledThemes() {
        installedThemes = highlightr?.availableThemes() ?? []
    }

    func isBundled(_ theme: String) -> Bool { bundledThemes.contains(theme) }

    /// Sets the theme and code font used for highlighting. Returns false if the theme isn't installed.
    @discardableResult
    func use(theme name: String, font: NSFont) -> Bool {
        guard let highlightr else { return false }
        let found = highlightr.setTheme(to: name)
        highlightr.theme.setCodeFont(font)
        return found
    }

    /// Downloads a theme of the bundled highlight.js release from cdnjs. Some themes live in the base16
    /// folder there, so both places are tried.
    func download(_ name: String) async {
        downloading.insert(name)
        defer { downloading.remove(name) }
        let base = "https://cdnjs.cloudflare.com/ajax/libs/highlight.js/\(Self.highlightJSVersion)/styles/"
        for path in ["\(name).min.css", "base16/\(name).min.css"] {
            guard let url = URL(string: base + path),
                  let result = try? await URLSession.shared.data(from: url),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200
            else { continue }
            do {
                try result.0.write(to: Self.userThemesDirectory.appendingPathComponent("\(name).min.css"))
                reloadInstalledThemes()
            } catch {
                downloadError = "Couldn't save “\(name)”: \(error.localizedDescription)"
            }
            return
        }
        downloadError = "Couldn't download “\(name)”. Check your internet connection and try again."
    }

    /// Removes a downloaded theme; bundled themes stay.
    func remove(_ name: String) {
        guard !isBundled(name) else { return }
        for file in ["\(name).min.css", "\(name).css"] {
            try? FileManager.default.removeItem(at: Self.userThemesDirectory.appendingPathComponent(file))
        }
        reloadInstalledThemes()
    }

    // MARK: - Languages

    /// highlight.js language for a file, from its name or extension; nil means plain text.
    static func language(forFileAt path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if let language = fileNames[name] { return language }
        return extensions[(name as NSString).pathExtension]
    }

    private static let fileNames: [String: String] = [
        "dockerfile": "dockerfile",
        "makefile": "makefile",
        "gnumakefile": "makefile",
        "cmakelists.txt": "cmake",
        "jenkinsfile": "groovy",
        "fastfile": "ruby",
        "appfile": "ruby",
        "matchfile": "ruby",
        "pluginfile": "ruby",
        "gemfile": "ruby",
        "podfile": "ruby",
        ".bashrc": "bash",
        ".zshrc": "bash",
        ".profile": "bash",
    ]

    private static let extensions: [String: String] = [
        "kt": "kotlin", "kts": "kotlin",
        "gradle": "gradle", "groovy": "groovy",
        "java": "java",
        "swift": "swift",
        "m": "objectivec", "mm": "objectivec",
        "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp",
        "cs": "csharp",
        "go": "go",
        "rs": "rust",
        "dart": "dart",
        "py": "python",
        "rb": "ruby",
        "php": "php",
        "lua": "lua",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "html": "xml", "htm": "xml", "xml": "xml", "plist": "xml", "svg": "xml", "xsd": "xml",
        "css": "css", "scss": "scss", "less": "less",
        "json": "json",
        "yml": "yaml", "yaml": "yaml",
        "toml": "ini", "ini": "ini", "cfg": "ini",
        "properties": "properties",
        "md": "markdown", "markdown": "markdown",
        "sh": "bash", "bash": "bash", "zsh": "bash",
        "sql": "sql",
        "proto": "protobuf",
        "graphql": "graphql", "gql": "graphql",
        "diff": "diff", "patch": "diff",
        "cmake": "cmake",
    ]
}

extension Theme {
    /// Highlighting theme used with this Shade theme until the user picks another.
    var defaultHighlightTheme: String {
        switch self {
        case .dark: return "atom-one-dark"
        case .light: return "xcode"
        case .paper: return "solarized-light"
        }
    }
}

/// "Get More Themes": every theme of the bundled highlight.js release, downloadable from cdnjs.
struct ThemeCatalogView: View {
    @ObservedObject var highlighting: SyntaxHighlighting
    let onDone: () -> Void

    @State private var filter = ""

    private var themes: [String] {
        filter.isEmpty ? highlighting.catalog : highlighting.catalog.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: onDone) { Label("Settings", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Text("highlight.js \(SyntaxHighlighting.highlightJSVersion) · \(highlighting.installedThemes.count) installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Search themes", text: $filter)
                .textFieldStyle(.roundedBorder)
            List(themes, id: \.self) { name in
                HStack {
                    Text(name)
                    Spacer()
                    if highlighting.downloading.contains(name) {
                        ProgressView().controlSize(.small)
                    } else if highlighting.installedThemes.contains(name) {
                        if highlighting.isBundled(name) {
                            Text("Built in").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Remove") { highlighting.remove(name) }
                        }
                    } else {
                        Button("Download") { Task { await highlighting.download(name) } }
                    }
                }
            }
            if let error = highlighting.downloadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(width: 360, height: 440)
    }
}
