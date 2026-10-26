import AppKit

@main
enum ShadeApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only unless "Show in Dock" is on; the app delegate follows later changes.
        app.setActivationPolicy(Settings.shared.showInDock ? .regular : .accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
