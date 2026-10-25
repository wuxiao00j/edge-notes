import AppKit
import Carbon

enum HotKeyAction: UInt32 {
    case toggle = 1
    case capture = 2
    case paste = 3
}

/// 可自定义全局快捷键（Carbon）。
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRefs: [EventHotKeyRef?] = [nil, nil, nil, nil]
    private var handlerRef: EventHandlerRef?
    private var handlers: [HotKeyAction: () -> Void] = [:]

    private init() {}

    func register(
        toggle: @escaping () -> Void,
        capture: @escaping () -> Void,
        paste: @escaping () -> Void
    ) {
        unregister()
        handlers = [.toggle: toggle, .capture: capture, .paste: paste]

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if let action = HotKeyAction(rawValue: hotKeyID.id) {
                    DispatchQueue.main.async {
                        manager.handlers[action]?()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )

        let settings = AppSettings.shared
        install(action: .toggle, chord: settings.hotkeyToggle)
        install(action: .capture, chord: settings.hotkeyCapture)
        install(action: .paste, chord: settings.hotkeyPaste)
    }

    func reloadFromSettings() {
        let settings = AppSettings.shared
        // Re-register only hotkeys
        for i in 1...3 {
            if let ref = hotKeyRefs[i] {
                UnregisterEventHotKey(ref)
                hotKeyRefs[i] = nil
            }
        }
        install(action: .toggle, chord: settings.hotkeyToggle)
        install(action: .capture, chord: settings.hotkeyCapture)
        install(action: .paste, chord: settings.hotkeyPaste)
    }

    private func install(action: HotKeyAction, chord: HotKeyChord) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x45444E54), id: action.rawValue)
        RegisterEventHotKey(
            chord.keyCode,
            chord.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        hotKeyRefs[Int(action.rawValue)] = ref
    }

    func unregister() {
        for i in hotKeyRefs.indices {
            if let ref = hotKeyRefs[i] {
                UnregisterEventHotKey(ref)
                hotKeyRefs[i] = nil
            }
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        handlers.removeAll()
    }
}
