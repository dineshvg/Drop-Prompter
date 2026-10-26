import Foundation

/// How a terminal card's shell is confined. Uses macOS's built-in sandbox (Seatbelt) through
/// `sandbox-exec`, so it applies to every program started in that card: Claude Code, Copilot CLI, scripts.
enum SandboxLevel: String, Codable, CaseIterable, Identifiable {
    /// Writes only in the project folder, temporary files and tool caches; keys and credentials can't be read.
    case project
    /// Like `project`, and no network except to this Mac.
    case strict

    var id: String { rawValue }

    var name: String {
        switch self {
        case .project: return "Project Only"
        case .strict: return "Strict (No Network)"
        }
    }
}

struct SandboxConfig: Equatable {
    let level: SandboxLevel
    /// The only folder outside temp and caches the shell may change.
    let root: URL
}

enum Sandbox {
    static let executable = "/usr/bin/sandbox-exec"

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: executable) }

    /// Profiles live outside the project, where the sandboxed shell can't change them.
    static var profilesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shade/Sandbox", isDirectory: true)
    }

    /// Shows what the sandbox denied, live, in a normal terminal.
    static let blockedActionsCommand =
        #"log stream --style compact --predicate 'eventMessage CONTAINS "Sandbox:" AND eventMessage CONTAINS "deny"'"#

    static func writeProfile(for config: SandboxConfig, cardID: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        let file = profilesDirectory.appendingPathComponent("\(cardID.uuidString).sb")
        try profile(for: config, home: NSHomeDirectory()).write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Folders in the home directory that tools write to: agent settings, build and package caches, shell history.
    private static let writableHomeFolders = [
        ".claude", ".copilot", ".codex", ".gemini", ".config", ".cache", ".local",
        ".gradle", ".m2", ".android", ".konan", ".kotlin",
        ".npm", ".yarn", ".pnpm-store", ".bun", ".deno", ".cargo", ".rustup",
        ".zsh_sessions", "Library/Caches", "Library/Logs",
    ]

    private static let writableHomeFiles = [
        ".zsh_history", ".bash_history", ".lesshst", ".node_repl_history", ".python_history", ".viminfo",
    ]

    /// Keys, tokens and credentials that sandboxed programs can neither read nor change.
    private static let protectedHomeFolders = [
        ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker",
        ".config/gcloud", ".config/gh", ".config/hub",
    ]

    private static let protectedHomeFiles = [
        ".netrc", ".git-credentials", ".npmrc", ".pypirc", ".gradle/gradle.properties",
    ]

    /// SBPL profile. Later rules take precedence over earlier ones.
    static func profile(for config: SandboxConfig, home: String) -> String {
        let root = config.root.resolvingSymlinksInPath().path
        func quoted(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func homePath(_ relative: String) -> String { quoted(home + "/" + relative) }
        let escapedHome = NSRegularExpression.escapedPattern(for: home).replacingOccurrences(of: "\"", with: "\\\"")

        var lines = [
            "(version 1)",
            "(allow default)",
            "",
            "; Writes: only the project, temporary files, tool caches and the agents' own settings.",
            "(deny file-write*)",
            "(allow file-write*",
            "    (subpath \(quoted(root)))",
            "    (subpath \"/private/tmp\")",
            "    (subpath \"/private/var/folders\")",
            "    (subpath \"/dev\")",
        ]
        lines += writableHomeFolders.map { "    (subpath \(homePath($0)))" }
        lines += writableHomeFiles.map { "    (literal \(homePath($0)))" }
        lines += [
            "    ; Claude Code's settings file and its backups, zsh's completion cache.",
            "    (regex #\"^\(escapedHome)/\\.claude\\.json\")",
            "    (regex #\"^\(escapedHome)/\\.zcompdump\")",
            ")",
            "",
            "; Keys and credentials: no reading, no writing.",
            "(deny file-read* file-write*",
        ]
        lines += protectedHomeFolders.map { "    (subpath \(homePath($0)))" }
        lines += protectedHomeFiles.map { "    (literal \(homePath($0)))" }
        lines.append(")")

        if config.level == .strict {
            lines += [
                "",
                "; No network, except to this Mac (local dev servers, debuggers).",
                "(deny network-outbound (remote ip \"*:*\"))",
                "(allow network-outbound (remote ip \"localhost:*\"))",
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
