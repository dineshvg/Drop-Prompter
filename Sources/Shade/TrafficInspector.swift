import AppKit
import Foundation

/// Local HTTPS inspector for terminal cards. Runs mitmproxy's web interface (`mitmweb`) and gives inspected
/// cards the proxy settings and certificates they need, so every request an agent sends to its backend, and
/// every response, can be read.
@MainActor
final class TrafficInspector: ObservableObject {
    static let shared = TrafficInspector()

    /// Ports away from the usual dev-server ports (8080 and friends).
    static let proxyPort = 18080
    static let webPort = 18081

    enum State: Equatable {
        case stopped
        case starting
        case running(webURL: URL)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped

    private var process: Process?
    private var startup: Task<Bool, Never>?
    private var output = ""
    /// Address mitmweb printed while starting (with its access token, when it uses one).
    private var printedWebURL: URL?

    // MARK: - Files

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shade/Inspector", isDirectory: true)
    }

    /// mitmproxy's own folder: its CA private key lives here, so sandboxed cards can only read the certificate.
    static var mitmproxyDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".mitmproxy", isDirectory: true)
    }

    static var certificate: URL { mitmproxyDirectory.appendingPathComponent("mitmproxy-ca-cert.pem") }

    /// macOS's root certificates plus the inspector's, for tools that replace rather than extend their trust
    /// store (curl, git, Python).
    static var certificateBundle: URL { directory.appendingPathComponent("ca-bundle.pem") }

    /// Finds mitmweb from Homebrew, pipx or uv (~/.local/bin), `pip install --user`, or the login shell's PATH.
    nonisolated static var mitmwebPath: String? {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        var candidates = ["/opt/homebrew/bin/mitmweb", "/usr/local/bin/mitmweb", home + "/.local/bin/mitmweb"]
        let userPython = home + "/Library/Python"
        for version in ((try? fileManager.contentsOfDirectory(atPath: userPython)) ?? []).sorted().reversed() {
            candidates.append("\(userPython)/\(version)/bin/mitmweb")
        }
        if let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) { return found }
        return loginShellLookup("mitmweb")
    }

    /// `command -v` in the user's login shell: apps started from Finder don't see the PATH set in .zshrc.
    nonisolated private static func loginShellLookup(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "command -v \(command)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Installs mitmproxy with the best tool on this Mac; PyPI packages also work where Homebrew's download
    /// is blocked. Runs in a visible terminal card, never silently.
    nonisolated static var installCommand: String {
        let done = " && echo && echo 'mitmproxy is installed. Open a new inspected card to use it.'"
        if loginShellLookup("pipx") != nil { return "pipx install mitmproxy" + done }
        if loginShellLookup("uv") != nil { return "uv tool install mitmproxy" + done }
        if loginShellLookup("brew") != nil { return "brew install pipx && pipx install mitmproxy" + done }
        return "python3 -m pip install --user pipx && python3 -m pipx install mitmproxy" + done
    }

    // MARK: - Use

    /// Environment for an inspected shell, starting the inspector first if needed. Nil when it can't run;
    /// `state` then says why.
    func environment() async -> [String: String]? {
        guard await ensureRunning() else { return nil }
        let proxy = "http://127.0.0.1:\(Self.proxyPort)"
        let local = "localhost,127.0.0.1,::1"
        let bundle = Self.certificateBundle.path
        return [
            "HTTPS_PROXY": proxy, "HTTP_PROXY": proxy, "https_proxy": proxy, "http_proxy": proxy,
            "NO_PROXY": local, "no_proxy": local,
            // Node (Claude Code, Copilot CLI) adds this certificate to its built-in ones.
            "NODE_EXTRA_CA_CERTS": Self.certificate.path,
            "SSL_CERT_FILE": bundle, "REQUESTS_CA_BUNDLE": bundle, "CURL_CA_BUNDLE": bundle, "GIT_SSL_CAINFO": bundle,
            "SHADE_INSPECT": "1",
        ]
    }

    var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    var webURL: URL? {
        if case .running(let url) = state { return url }
        return nil
    }

    func openWebInterface() {
        if let webURL { NSWorkspace.shared.open(webURL) }
    }

    func stop() {
        process?.terminate()
        process = nil
        state = .stopped
    }

    // MARK: - Starting

    private func ensureRunning() async -> Bool {
        if case .running = state, process?.isRunning == true { return true }
        if let startup { return await startup.value }
        let task = Task { await self.start() }
        startup = task
        let started = await task.value
        startup = nil
        return started
    }

    private func start() async -> Bool {
        guard let mitmweb = Self.mitmwebPath else {
            state = .failed("mitmproxy isn't installed. Install it with “pipx install mitmproxy” "
                + "(or “brew install mitmproxy”), then open a new card.")
            return false
        }
        state = .starting
        output = ""
        printedWebURL = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: mitmweb)
        process.arguments = [
            "--listen-host", "127.0.0.1", "--listen-port", "\(Self.proxyPort)",
            "--web-host", "127.0.0.1", "--web-port", "\(Self.webPort)",
            "--no-web-open-browser",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(text) } }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.process === process else { return }
                    self.process = nil
                    if case .running = self.state { self.state = .stopped }
                }
            }
        }
        do {
            try process.run()
        } catch {
            state = .failed("Couldn't start mitmweb: \(error.localizedDescription)")
            return false
        }
        self.process = process

        // Ready once its certificate exists and it has printed where its web interface is.
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard process.isRunning else {
                let lastLines = output.split(separator: "\n").suffix(3).joined(separator: " ")
                state = .failed("mitmweb stopped while starting. \(lastLines)")
                return false
            }
            if FileManager.default.fileExists(atPath: Self.certificate.path), printedWebURL != nil { break }
        }
        guard FileManager.default.fileExists(atPath: Self.certificate.path) else {
            stop()
            state = .failed("mitmweb didn't create its certificate in ~/.mitmproxy.")
            return false
        }
        guard await writeCertificateBundle() else {
            stop()
            state = .failed("Couldn't build the certificate bundle in \(Self.directory.path).")
            return false
        }
        // Older mitmweb versions don't print a URL with an access token.
        state = .running(webURL: printedWebURL ?? URL(string: "http://127.0.0.1:\(Self.webPort)/")!)
        return true
    }

    /// Picks the web interface's address (with its access token, when there is one) out of mitmweb's output.
    private func consume(_ text: String) {
        output += text
        guard printedWebURL == nil,
              let range = output.range(of: #"http://127\.0\.0\.1:\#(Self.webPort)/\S*"#, options: .regularExpression)
        else { return }
        printedWebURL = URL(string: String(output[range]))
    }

    private func writeCertificateBundle() async -> Bool {
        // Read on the main actor; the work below runs on a background queue.
        let certificate = Self.certificate
        let directory = Self.directory
        let bundle = Self.certificateBundle
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let roots = Process()
                roots.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                roots.arguments = ["find-certificate", "-a", "-p", "/System/Library/Keychains/SystemRootCertificates.keychain"]
                let pipe = Pipe()
                roots.standardOutput = pipe
                roots.standardError = FileHandle.nullDevice
                do {
                    try roots.run()
                    let rootCertificates = pipe.fileHandleForReading.readDataToEndOfFile()
                    roots.waitUntilExit()
                    let inspector = try Data(contentsOf: certificate)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try (rootCertificates + Data("\n".utf8) + inspector).write(to: bundle)
                    continuation.resume(returning: roots.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
