import AppKit
import Carbon
import Foundation

struct RecordingShortcut: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let displayName: String
    let isFunctionKey: Bool

    static let functionKey = RecordingShortcut(
        keyCode: 63,
        carbonModifiers: 0,
        displayName: "fn",
        isFunctionKey: true
    )

    var isRegisterableHotKey: Bool {
        !isFunctionKey && carbonModifiers != 0
    }

    var eventModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 {
            flags.insert(.command)
        }
        if carbonModifiers & UInt32(controlKey) != 0 {
            flags.insert(.control)
        }
        if carbonModifiers & UInt32(optionKey) != 0 {
            flags.insert(.option)
        }
        if carbonModifiers & UInt32(shiftKey) != 0 {
            flags.insert(.shift)
        }
        return flags
    }

    static func from(event: NSEvent) -> RecordingShortcut? {
        if event.keyCode == 63 || event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.function) {
            return .functionKey
        }

        guard event.type == .keyDown else {
            return nil
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifiers = carbonModifiers(from: flags)
        guard modifiers != 0 else {
            return nil
        }

        let keyCode = UInt32(event.keyCode)
        return RecordingShortcut(
            keyCode: keyCode,
            carbonModifiers: modifiers,
            displayName: displayName(keyCode: keyCode, modifiers: modifiers, characters: event.charactersIgnoringModifiers),
            isFunctionKey: false
        )
    }

    static func load(from defaults: UserDefaults) -> RecordingShortcut {
        if defaults.object(forKey: Keys.keyCode) == nil {
            return .functionKey
        }

        let keyCode = UInt32(defaults.integer(forKey: Keys.keyCode))
        let modifiers = UInt32(defaults.integer(forKey: Keys.modifiers))
        let isFunctionKey = (defaults.object(forKey: Keys.isFunctionKey) as? Bool) ?? (keyCode == 63)
        if isFunctionKey {
            return .functionKey
        }

        let displayName = defaults.string(forKey: Keys.displayName)
            ?? Self.displayName(keyCode: keyCode, modifiers: modifiers, characters: nil)
        return RecordingShortcut(keyCode: keyCode, carbonModifiers: modifiers, displayName: displayName, isFunctionKey: false)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(Int(keyCode), forKey: Keys.keyCode)
        defaults.set(Int(carbonModifiers), forKey: Keys.modifiers)
        defaults.set(displayName, forKey: Keys.displayName)
        defaults.set(isFunctionKey, forKey: Keys.isFunctionKey)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if flags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        if flags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        return modifiers
    }

    private static func displayName(keyCode: UInt32, modifiers: UInt32, characters: String?) -> String {
        var pieces: [String] = []
        if modifiers & UInt32(controlKey) != 0 {
            pieces.append("⌃")
        }
        if modifiers & UInt32(optionKey) != 0 {
            pieces.append("⌥")
        }
        if modifiers & UInt32(shiftKey) != 0 {
            pieces.append("⇧")
        }
        if modifiers & UInt32(cmdKey) != 0 {
            pieces.append("⌘")
        }

        pieces.append(keyName(keyCode: keyCode, characters: characters))
        return pieces.joined()
    }

    private static func keyName(keyCode: UInt32, characters: String?) -> String {
        switch Int(keyCode) {
        case kVK_Space:
            return "Space"
        case kVK_Return:
            return "Return"
        case kVK_Tab:
            return "Tab"
        case kVK_Escape:
            return "Esc"
        case kVK_Delete:
            return "Delete"
        case kVK_ForwardDelete:
            return "Del"
        case kVK_LeftArrow:
            return "←"
        case kVK_RightArrow:
            return "→"
        case kVK_UpArrow:
            return "↑"
        case kVK_DownArrow:
            return "↓"
        default:
            if let characters, let first = characters.uppercased().first {
                return String(first)
            }
            return "Key \(keyCode)"
        }
    }

    private enum Keys {
        static let keyCode = "recordingShortcutKeyCode"
        static let modifiers = "recordingShortcutModifiers"
        static let displayName = "recordingShortcutDisplayName"
        static let isFunctionKey = "recordingShortcutIsFunctionKey"
    }
}

final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onPressed: (() -> Void)?

    func register(_ shortcut: RecordingShortcut, onPressed: @escaping () -> Void) throws {
        unregister()
        guard shortcut.isRegisterableHotKey else {
            return
        }

        self.onPressed = onPressed

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else {
                    return noErr
                }

                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.onPressed?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &handlerRef
        )

        guard installStatus == noErr else {
            throw HotKeyError.registrationFailed(installStatus)
        }

        let hotKeyID = EventHotKeyID(signature: Self.fourCharCode("vtyp"), id: 1)
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            unregister()
            throw HotKeyError.registrationFailed(registerStatus)
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private static func fourCharCode(_ string: String) -> OSType {
        string.utf8.reduce(0) { result, byte in
            (result << 8) + OSType(byte)
        }
    }
}

enum HotKeyError: LocalizedError {
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let status):
            return "Carbon hotkey 注册失败，状态码 \(status)。"
        }
    }
}
