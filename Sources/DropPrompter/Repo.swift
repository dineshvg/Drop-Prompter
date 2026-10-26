import AppKit
import Darwin

/// A git repository as seen from a terminal card: where it is, which branch, what changed.
struct RepoStatus: Equatable {
    let root: URL
    let branch: String
    let changes: [FileChange]
}

/// One line of `git status --porcelain`.
struct FileChange: Identifiable, Equatable {
    /// Porcelain XY code, e.g. " M", "A ", "D ", "R ", "??".
    let code: String
    /// Path relative to the repository root.
    let path: String

    var id: String { path }
    var isUntracked: Bool { code == "??" }

    /// Short label shown in the changes list.
    var badge: String {
        if isUntracked { return "U" }
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(1))
    }
}

/// Read-only git access. Every command runs with GIT_OPTIONAL_LOCKS=0, so it never takes the index lock
/// that git commands running in the terminal (for example an agent's commits) may need.
enum Repo {
    static func status(at directory: URL) async -> RepoStatus? {
        guard let top = await git(["rev-parse", "--show-toplevel"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty
        else { return nil }
        let root = URL(fileURLWithPath: top, isDirectory: true)
        guard let output = await git(["status", "--porcelain=v1", "--branch", "-z"], in: root) else { return nil }
        return parseStatus(output, root: root)
    }

    static func parseStatus(_ output: String, root: URL) -> RepoStatus {
        var entries = output.split(separator: "\0").map(String.init)
        var branch = "unknown"
        if let header = entries.first, header.hasPrefix("## ") {
            branch = branchName(fromHeader: String(header.dropFirst(3)))
            entries.removeFirst()
        }
        var changes: [FileChange] = []
        var skipOriginalPath = false
        for entry in entries {
            // With -z, renames and copies are followed by an extra entry holding the original path.
            if skipOriginalPath {
                skipOriginalPath = false
                continue
            }
            guard entry.count > 3 else { continue }
            let code = String(entry.prefix(2))
            changes.append(FileChange(code: code, path: String(entry.dropFirst(3))))
            skipOriginalPath = code.contains("R") || code.contains("C")
        }
        return RepoStatus(root: root, branch: branch, changes: changes)
    }

    /// "main...origin/main [ahead 1]" → "main"; handles new and detached repositories.
    static func branchName(fromHeader header: String) -> String {
        let noCommits = "No commits yet on "
        if header.hasPrefix(noCommits) { return String(header.dropFirst(noCommits.count)) }
        if header.hasPrefix("HEAD (no branch)") { return "detached HEAD" }
        let local = header.components(separatedBy: "...").first ?? header
        return local.split(separator: " ").first.map(String.init) ?? local
    }

    /// Diff of one changed file against HEAD; untracked files show as entirely added.
    static func diff(for change: FileChange, in root: URL) async -> String {
        let options = ["--no-color", "--no-ext-diff"]
        if change.isUntracked {
            // `diff --no-index` exits with 1 when the files differ, which is always the case here.
            return await git(["diff"] + options + ["--no-index", "--", "/dev/null", change.path],
                             in: root, allowedExitCodes: [0, 1]) ?? ""
        }
        if let againstHead = await git(["diff"] + options + ["HEAD", "--", change.path], in: root),
           !againstHead.isEmpty {
            return againstHead
        }
        // A repository without commits has no HEAD yet; show what's staged instead.
        return await git(["diff"] + options + ["--cached", "--", change.path], in: root) ?? ""
    }

    /// Tracked and untracked files, without ignored ones, for Quick Open.
    static func files(in root: URL) async -> [String] {
        guard let output = await git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: root)
        else { return [] }
        return Array(output.split(separator: "\0").prefix(50_000).map(String.init))
    }

    static func git(_ arguments: [String], in directory: URL, allowedExitCodes: Set<Int32> = [0]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                process.currentDirectoryURL = directory
                var environment = ProcessInfo.processInfo.environment
                environment["GIT_OPTIONAL_LOCKS"] = "0"
                process.environment = environment
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let succeeded = allowedExitCodes.contains(process.terminationStatus)
                continuation.resume(returning: succeeded ? String(decoding: data, as: UTF8.self) : nil)
            }
        }
    }

    // MARK: - Files

    enum FileContent: Equatable {
        case text(String, modified: Date?)
        case message(String)
    }

    /// Text of a file for the editor, or a message when it can't be edited safely here.
    static func load(_ url: URL) async -> FileContent {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let modified = modificationDate(of: url)
                guard let data = FileManager.default.contents(atPath: url.path) else {
                    continuation.resume(returning: .message("File not found: \(url.path)"))
                    return
                }
                if data.count > 2_000_000 {
                    continuation.resume(returning: .message("This file is too large to edit here. Open it in your editor."))
                } else if data.prefix(8_000).contains(0) {
                    continuation.resume(returning: .message("Binary file. Open it in your editor."))
                } else if let text = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: .text(text, modified: modified))
                } else {
                    // Decoding leniently and saving would silently damage the file's encoding.
                    continuation.resume(returning: .message("This file isn't UTF-8 text. Open it in your editor."))
                }
            }
        }
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// Current directory of a process (the terminal card's shell), read from the kernel, so it works
/// without any shell configuration.
enum ProcessDirectory {
    static func of(_ pid: pid_t) -> URL? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }
}

// MARK: - Code editors

struct CodeEditor: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

/// Hand-off to a real editor; Drop Prompter itself never changes files.
@MainActor
enum CodeEditors {
    private static let candidates: [CodeEditor] = [
        CodeEditor(bundleID: "com.microsoft.VSCode", name: "VS Code"),
        CodeEditor(bundleID: "com.google.android.studio", name: "Android Studio"),
        CodeEditor(bundleID: "com.apple.dt.Xcode", name: "Xcode"),
        CodeEditor(bundleID: "dev.zed.Zed", name: "Zed"),
        CodeEditor(bundleID: "com.jetbrains.intellij", name: "IntelliJ IDEA"),
        CodeEditor(bundleID: "com.jetbrains.intellij.ce", name: "IntelliJ IDEA CE"),
        CodeEditor(bundleID: "com.sublimetext.4", name: "Sublime Text"),
    ]

    static var installed: [CodeEditor] {
        candidates.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    static func name(for bundleID: String) -> String {
        candidates.first { $0.bundleID == bundleID }?.name ?? "Default App"
    }

    /// Opens a file or folder in the chosen editor. An empty ID uses the macOS default (Finder for folders).
    static func open(_ url: URL, with bundleID: String) {
        if !bundleID.isEmpty, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
