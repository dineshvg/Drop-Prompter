import AppKit
import Carbon.HIToolbox
import Combine
import SwiftTerm
import SwiftUI

/// Everything here is UI work on the main thread.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings.shared
    private let panel = PromptPanel.make()
    private let background = NSVisualEffectView()
    /// Color over the blur for themes that tint it (Paper).
    private let tintView = NSView()
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem?
    private var hotKey: HotKey?
    private var escapeMonitor: Any?
    private var subscriptions = Set<AnyCancellable>()
    private var isShown = false
    private var resizeStart: (mouse: NSPoint, frame: NSRect)?

    private static let animationDuration = 0.18

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        buildMainMenu()
        buildStatusItem()

        // Esc hides the panel, except in a terminal (programs like vim need it) or while renaming a card.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == UInt16(kVK_Escape), self.panel.isKeyWindow,
                  !(self.panel.firstResponder is TerminalView),
                  (self.panel.firstResponder as? NSTextView)?.isFieldEditor != true else { return event }
            self.hide()
            return nil
        }

        // Registers the show/hide shortcut now and again whenever it's changed in Settings.
        settings.$hotKeyID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.registerHotKey() }
            .store(in: &subscriptions)

        settings.$theme.combineLatest(settings.$opacity, settings.$codeBackgroundOpacity)
            .sink { [weak self] theme, opacity, codeOpacity in
                self?.apply(theme, opacity: opacity, codeBackgroundOpacity: codeOpacity)
            }
            .store(in: &subscriptions)
        settings.$hideFromScreenShare
            .sink { [weak self] in self?.panel.sharingType = $0 ? .none : .readOnly }
            .store(in: &subscriptions)
        // @Published emits before the value is stored, so hop to the next run loop turn before re-reading it.
        settings.$widthFraction.combineLatest(settings.$heightFraction)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isShown, let screen = self.panel.screen else { return }
                self.panel.setFrame(self.frames(on: screen).shown, display: true)
            }
            .store(in: &subscriptions)

        // Show the panel once when opened by hand, so starting it from Applications or Spotlight visibly
        // does something. When macOS starts it at login, stay quietly in the menu bar.
        if !Self.launchedAsLoginItem { show() }
    }

    private func registerHotKey() {
        let preset = settings.hotKey
        hotKey = nil // unregister the old combination first
        let newHotKey = HotKey(keyCode: preset.keyCode, modifiers: preset.carbonModifiers) { [weak self] in
            self?.toggle()
        }
        hotKey = newHotKey

        if !newHotKey.isRegistered {
            settings.hotKeyProblem = "\(preset.label) is already used by another app, so it can't show the panel. "
                + "Pick another shortcut in ⚙︎."
        } else if SystemShortcuts.isTaken(keyCode: preset.keyCode, modifiers: preset.cocoaModifiers) {
            settings.hotKeyProblem = "macOS also uses \(preset.label) (for example to switch keyboard input source) "
                + "and takes it first. Turn that off in System Settings › Keyboard › Keyboard Shortcuts, "
                + "or pick another shortcut in ⚙︎."
        } else {
            settings.hotKeyProblem = nil
        }
        toggleItem?.title = "Show / Hide   \(preset.label)"
    }

    /// True when macOS opened the app as a login item (the "oapp" event carries a launched-as-login-item marker).
    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    /// Quitting stops every shell and drops unsaved edits, so ask first when either would be lost.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = TerminalSessions.shared.runningPrograms
        let unsaved = FileBuffers.shared.dirtyCount
        guard !running.isEmpty || unsaved > 0 else { return .terminateNow }
        var consequences: [String] = []
        if !running.isEmpty {
            consequences.append("stops what's running in its terminal cards: "
                + running.map { "“\($0)”" }.joined(separator: ", "))
        }
        if unsaved > 0 {
            consequences.append(unsaved == 1 ? "discards unsaved changes in 1 file" : "discards unsaved changes in \(unsaved) files")
        }
        let alert = NSAlert()
        alert.messageText = "Quit Shade?"
        alert.informativeText = "Quitting " + consequences.joined(separator: " and ") + "."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Opening the app again (Finder, Spotlight, Dock) while it's running brings the panel down.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return false
    }

    // MARK: - Setup

    private func buildPanel() {
        let container = NSView()
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = bottomRoundedMask(radius: 14)

        let content = NSHostingView(rootView: ContentView(
            settings: settings,
            terminals: TerminalSessions.shared,
            buffers: FileBuffers.shared,
            onClose: { [weak self] in self?.hide() }
        ))
        content.sizingOptions = []

        tintView.wantsLayer = true
        tintView.layer?.cornerRadius = 14
        tintView.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner] // bottom corners only

        for view in [background, tintView, content] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        // Resize grips sit above the SwiftUI content, along the bottom edge.
        let bottomHandle = ResizeHandleView(kind: .bottom)
        let cornerHandle = ResizeHandleView(kind: .corner)
        for handle in [bottomHandle, cornerHandle] {
            handle.onBegin = { [weak self] in self?.beginResize() }
            handle.onDrag = { [weak self] in self?.updateResize(includeWidth: $0) }
            handle.onEnd = { [weak self] in self?.endResize() }
            handle.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(handle)
        }
        NSLayoutConstraint.activate([
            bottomHandle.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bottomHandle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bottomHandle.widthAnchor.constraint(equalToConstant: 140),
            bottomHandle.heightAnchor.constraint(equalToConstant: 14),
            cornerHandle.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cornerHandle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            cornerHandle.widthAnchor.constraint(equalToConstant: 22),
            cornerHandle.heightAnchor.constraint(equalToConstant: 22),
        ])
        panel.contentView = container
    }

    /// Colors the whole panel. Opacity applies to the blur and tint only, so text stays fully readable.
    private func apply(_ theme: Theme, opacity: Double, codeBackgroundOpacity: Double) {
        panel.appearance = theme.appearance
        background.material = theme.material
        background.alphaValue = opacity
        tintView.layer?.backgroundColor = theme.tint?.cgColor
        tintView.alphaValue = opacity
        TerminalSessions.shared.apply(theme, backgroundOpacity: codeBackgroundOpacity)
    }

    /// Hidden main menu so ⌘C/⌘V/⌘Z also work in the settings popover.
    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = mainMenu
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Shade")
        let menu = NSMenu()
        let toggleItem = menu.addItem(withTitle: "Show / Hide   \(settings.hotKey.label)",
                                      action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        self.toggleItem = toggleItem
        let welcomeItem = menu.addItem(withTitle: "Welcome & Shortcuts", action: #selector(showWelcome), keyEquivalent: "")
        welcomeItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Shade", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    // MARK: - Show / hide

    @objc private func showWelcome() {
        settings.showWelcome = true
        show()
    }

    @objc private func toggle() {
        isShown ? hide() : show()
    }

    private func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let (shown, hidden) = frames(on: screen)
        isShown = true
        if !panel.isVisible { panel.setFrame(hidden, display: false) }
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(shown, display: true)
        }
    }

    private func hide() {
        guard isShown, let screen = panel.screen ?? NSScreen.main else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(frames(on: screen).hidden, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // The hotkey may have been pressed again mid-animation.
                guard let self, !self.isShown else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    // MARK: - Resize

    private func beginResize() {
        resizeStart = (NSEvent.mouseLocation, panel.frame)
    }

    /// The top edge stays under the menu bar and the panel stays centered, so dragging
    /// down grows the height and dragging sideways grows both sides at once.
    private func updateResize(includeWidth: Bool) {
        guard let start = resizeStart, let visible = panel.screen?.visibleFrame else { return }
        let mouse = NSEvent.mouseLocation
        let width = includeWidth ? start.frame.width + (mouse.x - start.mouse.x) * 2 : start.frame.width
        let height = start.frame.height + (start.mouse.y - mouse.y)
        let clampedWidth = CGFloat(Double(width / visible.width).clamped(to: Settings.widthRange)) * visible.width
        let clampedHeight = CGFloat(Double(height / visible.height).clamped(to: Settings.heightRange)) * visible.height
        panel.setFrame(
            NSRect(x: (visible.midX - clampedWidth / 2).rounded(), y: visible.maxY - clampedHeight,
                   width: clampedWidth.rounded(), height: clampedHeight.rounded()),
            display: true
        )
    }

    private func endResize() {
        resizeStart = nil
        guard let visible = panel.screen?.visibleFrame else { return }
        settings.widthFraction = Double(panel.frame.width / visible.width)
        settings.heightFraction = Double(panel.frame.height / visible.height)
    }

    /// Centered horizontally, attached to the bottom of the menu bar; hidden = just above the screen.
    private func frames(on screen: NSScreen) -> (shown: NSRect, hidden: NSRect) {
        let visible = screen.visibleFrame
        let width = (visible.width * settings.widthFraction).rounded()
        let height = (visible.height * settings.heightFraction).rounded()
        let x = (visible.midX - width / 2).rounded()
        return (
            NSRect(x: x, y: visible.maxY - height, width: width, height: height),
            NSRect(x: x, y: screen.frame.maxY, width: width, height: height)
        )
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
