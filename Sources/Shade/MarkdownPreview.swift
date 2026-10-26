import AppKit
import JavaScriptCore
import SwiftUI
import WebKit

/// Turns Markdown into HTML with marked (GitHub-flavored: tables, task lists, strikethrough), highlighting code
/// blocks with highlight.js. It runs in JavaScriptCore, apart from the web view that shows the result, so nothing
/// in a Markdown file ever runs as a script.
@MainActor
final class MarkdownRenderer {
    static let shared = MarkdownRenderer()

    /// Nil when the scripts couldn't be loaded; the preview then says so.
    private let render: JSValue?

    private init() {
        guard let highlight = SyntaxHighlighting.bundledDirectory?.appendingPathComponent("highlight.min.js"),
              let marked = Self.bundledDirectory?.appendingPathComponent("marked.min.js"),
              let highlightScript = try? String(contentsOf: highlight, encoding: .utf8),
              let markedScript = try? String(contentsOf: marked, encoding: .utf8),
              let context = JSContext()
        else {
            render = nil
            return
        }
        context.evaluateScript(highlightScript)
        context.evaluateScript(markedScript)
        context.evaluateScript("""
            function escapeHTML(text) {
                return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
            }
            // Heading ids like GitHub's, so links within the document (a table of contents) work.
            let usedSlugs = {};
            function slug(text) {
                const base = text.toLowerCase().replace(/<[^>]*>/g, "").replace(/[^\\p{L}\\p{N}\\s_-]/gu, "").trim().replace(/\\s/g, "-");
                const count = usedSlugs[base] || 0;
                usedSlugs[base] = count + 1;
                return count ? base + "-" + count : base;
            }
            marked.use({ gfm: true, renderer: {
                heading({ tokens, depth, text }) {
                    return "<h" + depth + ' id="' + escapeHTML(slug(text)) + '">' + this.parser.parseInline(tokens) + "</h" + depth + ">\\n";
                },
                code({ text, lang }) {
                    const language = (lang || "").split(/\\s/)[0];
                    const body = language && hljs.getLanguage(language)
                        ? hljs.highlight(text, { language, ignoreIllegals: true }).value
                        : escapeHTML(text);
                    return '<pre><code class="hljs">' + body + "</code></pre>\\n";
                }
            }});
            function renderMarkdown(text) { usedSlugs = {}; return marked.parse(text); }
            """)
        render = context.objectForKeyedSubscript("renderMarkdown")
    }

    /// Shade.app/Contents/Resources/Markdown, or the repository's Resources/Markdown with `swift run`.
    static let bundledDirectory: URL? = {
        let fileManager = FileManager.default
        if let inApp = Bundle.main.resourceURL?.appendingPathComponent("Markdown"),
           fileManager.fileExists(atPath: inApp.appendingPathComponent("marked.min.js").path) {
            return inApp
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Shade
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent()
        let inRepository = repository.appendingPathComponent("Resources/Markdown")
        return fileManager.fileExists(atPath: inRepository.path) ? inRepository : nil
    }()

    func html(for markdown: String) -> String? {
        guard let result = render?.call(withArguments: [markdown]), result.isString else { return nil }
        return result.toString()
    }

    /// A whole page: the rendered Markdown, styled like GitHub in the card's colors. The policy at the top
    /// blocks scripts, frames and anything from the network; only local and inline images load.
    func page(for markdown: String, theme: Theme, highlightTheme: String, fontSize: CGFloat) -> String {
        let body = html(for: markdown) ?? "<p>The Markdown preview couldn't start.</p>"
        let text = Self.css(theme.terminalForeground)
        let isDark = theme == .dark
        let muted = isDark ? "rgba(255,255,255,0.55)" : "rgba(0,0,0,0.55)"
        let line = isDark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.12)"
        let fill = isDark ? "rgba(255,255,255,0.07)" : "rgba(0,0,0,0.05)"
        let link = isDark ? "#58a6ff" : "#0969da"
        let codeTheme = SyntaxHighlighting.shared.css(ofTheme: highlightTheme) ?? ""
        return """
            <!doctype html>
            <html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: data:; style-src 'unsafe-inline'">
            <style>
            \(codeTheme)
            html { background: transparent; }
            body { font: \(fontSize)px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; color: \(text);
                   margin: 0; padding: 16px 24px 32px; max-width: 900px; word-wrap: break-word; }
            h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 24px 0 12px; font-weight: 600; }
            h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid \(line); }
            h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid \(line); }
            h3 { font-size: 1.25em; } h4 { font-size: 1em; } h5 { font-size: .875em; } h6 { font-size: .85em; color: \(muted); }
            body > :first-child { margin-top: 0; }
            p, ul, ol, blockquote, table, pre { margin: 0 0 16px; }
            a { color: \(link); text-decoration: none; } a:hover { text-decoration: underline; }
            ul, ol { padding-left: 2em; } li + li { margin-top: .25em; }
            li > input[type=checkbox] { margin: 0 .4em 0 -1.4em; vertical-align: middle; }
            ul:has(> li > input[type=checkbox]) { list-style: none; }
            blockquote { padding: 0 1em; color: \(muted); border-left: .25em solid \(line); }
            code { font: .875em ui-monospace, SFMono-Regular, Menlo, monospace; padding: .2em .4em;
                   border-radius: 6px; background: \(fill); }
            pre { border-radius: 6px; overflow: auto; }
            pre code, pre code.hljs { display: block; padding: 14px 16px; font-size: .85em; line-height: 1.45;
                                      border-radius: 6px; white-space: pre; }
            pre code:not(.hljs) { background: \(fill); }
            table { border-collapse: collapse; display: block; overflow: auto; }
            th, td { padding: 6px 13px; border: 1px solid \(line); }
            th { font-weight: 600; } th:not([align]) { text-align: left; } tr:nth-child(2n) { background: \(fill); }
            hr { height: 1px; border: 0; background: \(line); margin: 24px 0; }
            img { max-width: 100%; }
            </style></head>
            <body>\(body)</body></html>
            """
    }

    private static func css(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "inherit" }
        return String(format: "rgb(%d,%d,%d)", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }
}

/// Shows rendered Markdown. JavaScript is off and the page can't load anything from the network; links open in
/// the browser, and links within the page jump to their heading.
struct MarkdownPreview: NSViewRepresentable {
    let markdown: String
    /// Folder of the Markdown file, so relative images resolve.
    let baseURL: URL
    let theme: Theme
    let highlightTheme: String
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        // Show the card's background through the page.
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let page = MarkdownRenderer.shared.page(
            for: markdown, theme: theme, highlightTheme: highlightTheme, fontSize: fontSize)
        context.coordinator.show(page, baseURL: baseURL, in: view)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var shownPage: String?
        private var baseURL: URL?
        /// Scroll position to restore once a re-rendered page has loaded (the file changed on disk).
        private var pendingScroll: Double?

        @MainActor
        func show(_ page: String, baseURL: URL, in view: WKWebView) {
            guard page != shownPage else { return }
            let isFirst = shownPage == nil
            shownPage = page
            self.baseURL = baseURL
            guard !isFirst else {
                view.loadHTMLString(page, baseURL: baseURL)
                return
            }
            // Keep the reader's place when the file changes under them.
            view.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
                self?.pendingScroll = value as? Double
                view.loadHTMLString(page, baseURL: baseURL)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let scroll = pendingScroll else { return }
            pendingScroll = nil
            webView.evaluateJavaScript("window.scrollTo(0, \(scroll))")
        }

        /// Only Shade's own page and jumps within it load here. Raw HTML in a Markdown file can't navigate the
        /// preview anywhere else (a refresh tag, a form); clicked web and mail links open in their usual app.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            let isPage = url.scheme == "file" && url.path == baseURL?.path
            if isPage && (action.navigationType == .other || url.fragment != nil) {
                return decisionHandler(.allow)
            }
            if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
