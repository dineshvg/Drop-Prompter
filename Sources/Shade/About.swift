import AppKit
import SwiftUI

enum ShadeInfo {
    static let repositoryURL = URL(string: "https://github.com/dineshvg/Shade")!
    static let author = "Dinesh Gangatharan"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
    }

    /// Credits for the standard macOS About window.
    @MainActor
    static var credits: NSAttributedString {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let text = NSMutableAttributedString(
            string: "Thanks for using Shade!\n— \(author)\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: centered]
        )
        text.append(NSAttributedString(
            string: repositoryURL.absoluteString.replacingOccurrences(of: "https://", with: ""),
            attributes: [.link: repositoryURL, .font: NSFont.systemFont(ofSize: 11), .paragraphStyle: centered]
        ))
        return text
    }
}

/// Opened from the ⓘ button in the toolbar.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Shade").font(.title2.bold())
            Text("Version \(ShadeInfo.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Thanks for using Shade! I hope it makes your meetings and your coding a little easier.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("— \(ShadeInfo.author)")
                .italic()
            Link(destination: ShadeInfo.repositoryURL) {
                Label("github.com/dineshvg/Shade", systemImage: "link")
            }
            Text("Open source under the MIT License. Ideas, issues and pull requests are welcome.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 300)
    }
}
