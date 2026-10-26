import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings.shared
    private let panel = PromptPanel.make()
    private let background = NSVisualEffectView()
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var escapeMonitor: Any?
    private var subscriptions = Set<AnyCancellable>()
    private var isShown = false

    private static let animationDuration = 0.18

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        buildMainMenu()
        buildStatusItem()

        // ⌃⌥Space toggles the panel from anywhere.
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.toggle()
        }

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == UInt16(kVK_Escape), self.panel.isKeyWindow else { return event }
            self.hide()
            return nil
        }

        settings.$opacity
            .sink { [weak self] in self?.background.alphaValue = $0 }
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
    }

    // MARK: - Setup

    private func buildPanel() {
        let container = NSView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = bottomRoundedMask(radius: 14)

        let content = NSHostingView(rootView: ContentView(settings: settings, onClose: { [weak self] in self?.hide() }))
        content.sizingOptions = []

        for view in [background, content] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        panel.contentView = container
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
        statusItem.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Drop Prompter")
        let menu = NSMenu()
        let toggleItem = menu.addItem(withTitle: "Show / Hide   ⌃⌥Space", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Drop Prompter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    // MARK: - Show / hide

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
