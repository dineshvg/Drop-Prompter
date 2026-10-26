import AppKit
import Carbon.HIToolbox

/// System-wide hotkey via Carbon's RegisterEventHotKey. Needs no Accessibility permission.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    /// False when another app already registered the same combination.
    private(set) var isRegistered = false

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &eventType, userData, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x5348_4445), id: 1) // 'SHDE'
        isRegistered = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

/// The shortcuts offered in Settings for showing and hiding the panel.
struct HotKeyPreset: Identifiable, Equatable {
    let id: String
    let label: String
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let cocoaModifiers: NSEvent.ModifierFlags

    static let all: [HotKeyPreset] = [
        HotKeyPreset(id: "ctrl-space", label: "⌃Space", keyCode: UInt32(kVK_Space),
                     carbonModifiers: UInt32(controlKey), cocoaModifiers: [.control]),
        HotKeyPreset(id: "ctrl-shift-space", label: "⌃⇧Space", keyCode: UInt32(kVK_Space),
                     carbonModifiers: UInt32(controlKey | shiftKey), cocoaModifiers: [.control, .shift]),
        HotKeyPreset(id: "ctrl-opt-space", label: "⌃⌥Space", keyCode: UInt32(kVK_Space),
                     carbonModifiers: UInt32(controlKey | optionKey), cocoaModifiers: [.control, .option]),
        HotKeyPreset(id: "ctrl-grave", label: "⌃`", keyCode: UInt32(kVK_ANSI_Grave),
                     carbonModifiers: UInt32(controlKey), cocoaModifiers: [.control]),
        HotKeyPreset(id: "opt-grave", label: "⌥`", keyCode: UInt32(kVK_ANSI_Grave),
                     carbonModifiers: UInt32(optionKey), cocoaModifiers: [.option]),
    ]
}

/// Reads macOS's own keyboard shortcuts (System Settings › Keyboard › Keyboard Shortcuts). Those win over
/// RegisterEventHotKey without reporting an error, so a clash has to be detected separately.
enum SystemShortcuts {
    /// Shortcuts macOS enables by default but only writes to its preferences once the user changes them:
    /// 60 = Select the previous input source (⌃Space), 61 = Select next source in Input menu (⌃⌥Space).
    private static let defaults: [String: (keyCode: Int, modifiers: UInt)] = [
        "60": (kVK_Space, NSEvent.ModifierFlags.control.rawValue),
        "61": (kVK_Space, NSEvent.ModifierFlags([.control, .option]).rawValue),
    ]

    static func isTaken(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) -> Bool {
        let wanted = modifiers.intersection(.deviceIndependentFlagsMask).rawValue
        let stored = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]

        let takenByStored = stored.values.contains { entry in
            guard let entry = entry as? [String: Any],
                  (entry["enabled"] as? Bool) == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Int], parameters.count == 3
            else { return false }
            let flags = UInt(parameters[2]) & NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue
            return parameters[1] == Int(keyCode) && flags == wanted
        }
        let takenByDefault = defaults.contains { id, shortcut in
            stored[id] == nil && shortcut.keyCode == Int(keyCode) && shortcut.modifiers == wanted
        }
        return takenByStored || takenByDefault
    }
}
