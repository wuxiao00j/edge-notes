import Foundation
import Combine
import ServiceManagement
import Carbon

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var isAlwaysOnTop: Bool
    @Published var defaultOpacity: Double
    @Published var launchAtLogin: Bool
    @Published var privacyHideBodies: Bool
    @Published var mainViewMode: MainViewMode
    @Published var hotkeyToggle: HotKeyChord
    @Published var hotkeyCapture: HotKeyChord
    @Published var hotkeyPaste: HotKeyChord
    @Published var sidebarHidden: Bool
    @Published var clotheslineEnabled: Bool
    /// 鼠标移到屏幕右边缘呼出侧栏。默认关：只留挂绳，侧栏从菜单栏图标或快捷键打开
    @Published var edgeDockEnabled: Bool

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let alwaysOnTop = "EdgeNotes.alwaysOnTop"
        static let defaultOpacity = "EdgeNotes.defaultOpacity"
        static let launchAtLogin = "EdgeNotes.launchAtLogin"
        static let privacyHideBodies = "EdgeNotes.privacyHideBodies"
        static let mainViewMode = "EdgeNotes.mainViewMode"
        static let hotkeyToggle = "EdgeNotes.hotkeyToggle"
        static let hotkeyCapture = "EdgeNotes.hotkeyCapture"
        static let hotkeyPaste = "EdgeNotes.hotkeyPaste"
        static let sidebarHidden = "EdgeNotes.sidebarHidden"
        static let clotheslineEnabled = "EdgeNotes.clotheslineEnabled"
        static let edgeDockEnabled = "EdgeNotes.edgeDockEnabled"
    }

    private init() {
        let d = UserDefaults.standard
        if d.object(forKey: Keys.alwaysOnTop) == nil {
            isAlwaysOnTop = true
        } else {
            isAlwaysOnTop = d.bool(forKey: Keys.alwaysOnTop)
        }
        let opacity = d.double(forKey: Keys.defaultOpacity)
        defaultOpacity = opacity == 0 ? 1.0 : min(1.0, max(0.35, opacity))
        launchAtLogin = d.bool(forKey: Keys.launchAtLogin)
        privacyHideBodies = d.bool(forKey: Keys.privacyHideBodies)
        if let raw = d.string(forKey: Keys.mainViewMode), let mode = MainViewMode(rawValue: raw) {
            mainViewMode = mode
        } else {
            mainViewMode = .all
        }

        hotkeyToggle = Self.loadChord(d, Keys.hotkeyToggle) ?? .optionCommandN
        hotkeyCapture = Self.loadChord(d, Keys.hotkeyCapture) ?? .optionCommandT
        hotkeyPaste = Self.loadChord(d, Keys.hotkeyPaste) ?? .optionCommandShiftV
        sidebarHidden = d.bool(forKey: Keys.sidebarHidden)
        clotheslineEnabled = d.object(forKey: Keys.clotheslineEnabled) == nil ? true : d.bool(forKey: Keys.clotheslineEnabled)
        edgeDockEnabled = d.bool(forKey: Keys.edgeDockEnabled)
    }

    private static func loadChord(_ d: UserDefaults, _ key: String) -> HotKeyChord? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotKeyChord.self, from: data)
    }

    private func saveChord(_ chord: HotKeyChord, key: String) {
        if let data = try? JSONEncoder().encode(chord) {
            defaults.set(data, forKey: key)
        }
    }

    func setAlwaysOnTop(_ on: Bool) {
        isAlwaysOnTop = on
        defaults.set(on, forKey: Keys.alwaysOnTop)
    }

    func setDefaultOpacity(_ value: Double) {
        defaultOpacity = min(1, max(0.35, value))
        defaults.set(defaultOpacity, forKey: Keys.defaultOpacity)
    }

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLogin = on
        defaults.set(on, forKey: Keys.launchAtLogin)
        applyLaunchAtLogin()
    }

    func setPrivacyHideBodies(_ on: Bool) {
        privacyHideBodies = on
        defaults.set(on, forKey: Keys.privacyHideBodies)
    }

    func setMainViewMode(_ mode: MainViewMode) {
        mainViewMode = mode
        defaults.set(mode.rawValue, forKey: Keys.mainViewMode)
    }

    func setHotkeyToggle(_ chord: HotKeyChord) {
        hotkeyToggle = chord
        saveChord(chord, key: Keys.hotkeyToggle)
    }

    func setHotkeyCapture(_ chord: HotKeyChord) {
        hotkeyCapture = chord
        saveChord(chord, key: Keys.hotkeyCapture)
    }

    func setHotkeyPaste(_ chord: HotKeyChord) {
        hotkeyPaste = chord
        saveChord(chord, key: Keys.hotkeyPaste)
    }

    func setSidebarHidden(_ hidden: Bool) {
        sidebarHidden = hidden
        defaults.set(hidden, forKey: Keys.sidebarHidden)
    }

    func setClotheslineEnabled(_ on: Bool) {
        clotheslineEnabled = on
        defaults.set(on, forKey: Keys.clotheslineEnabled)
    }

    func setEdgeDockEnabled(_ on: Bool) {
        edgeDockEnabled = on
        defaults.set(on, forKey: Keys.edgeDockEnabled)
    }

    private func applyLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("EdgeNotes: 开机启动设置失败 — \(error.localizedDescription)")
            }
        }
    }
}

enum MainViewMode: String, CaseIterable, Identifiable {
    case desktop
    case all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .desktop: return "桌面贴"
        case .all: return "全部列表"
        }
    }
}

struct HotKeyChord: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    static var optionCommandN: HotKeyChord {
        HotKeyChord(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | optionKey), label: "⌥⌘N")
    }

    static var optionCommandT: HotKeyChord {
        HotKeyChord(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | optionKey), label: "⌥⌘T")
    }

    static var optionCommandShiftV: HotKeyChord {
        HotKeyChord(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey | shiftKey), label: "⌥⇧⌘V")
    }
}

import LocalAuthentication
import AppKit

/// 锁定便签：解锁需要 Touch ID 或登录密码（系统对话框，App 不接触密码）。
@MainActor
enum NoteLock {
    static func unlock(_ id: UUID, store: NoteStore, completion: ((Bool) -> Void)? = nil) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // 没有可用的验证方式时退回确认对话框
            let alert = NSAlert()
            alert.messageText = "解锁这条便签？"
            alert.informativeText = "解锁后正文可以编辑。"
            alert.addButton(withTitle: "解锁")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            let ok = alert.runModal() == .alertFirstButtonReturn
            if ok { store.setLocked(id: id, false) }
            completion?(ok)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解锁便签") { success, _ in
            Task { @MainActor in
                if success { store.setLocked(id: id, false) }
                completion?(success)
            }
        }
    }
}
