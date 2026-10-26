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
    @Published var hotkeyToggle: HotKeyChord
    @Published var hotkeyCapture: HotKeyChord
    @Published var sidebarHidden: Bool
    @Published var clotheslineEnabled: Bool
    /// 挂满 N 天自动取下；0 = 不自动
    @Published var lineAutoRemoveDays: Int
    /// 全屏 App 里也显示挂绳
    @Published var lineShowInFullScreen: Bool
    /// 钉住挂绳：一直放下，不自动收起
    @Published var linePinnedOpen: Bool
    @Published var hotkeyHang: HotKeyChord
    @Published var lineCardSize: LineCardSize
    /// 记录复制过的内容，挂在绳上的剪贴板卡片里
    @Published var clipboardHistoryEnabled: Bool
    @Published var clipboardCardSize: LineCardSize
    /// 剪贴板历史最多保留几条
    @Published var clipboardMaxEntries: Int
    /// 剪贴板历史超过几天自动清理；0 = 不清理
    @Published var clipboardRetentionDays: Int

    static let clipboardEntryOptions = [20, 40, 100, 200]
    static let clipboardRetentionOptions = [0, 1, 3, 7, 30]

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let alwaysOnTop = "EdgeNotes.alwaysOnTop"
        static let defaultOpacity = "EdgeNotes.defaultOpacity"
        static let launchAtLogin = "EdgeNotes.launchAtLogin"
        static let privacyHideBodies = "EdgeNotes.privacyHideBodies"
        static let hotkeyToggle = "EdgeNotes.hotkeyToggle"
        static let hotkeyCapture = "EdgeNotes.hotkeyCapture"
        static let sidebarHidden = "EdgeNotes.sidebarHidden"
        static let clotheslineEnabled = "EdgeNotes.clotheslineEnabled"
        static let lineAutoRemoveDays = "EdgeNotes.lineAutoRemoveDays"
        static let lineShowInFullScreen = "EdgeNotes.lineShowInFullScreen"
        static let linePinnedOpen = "EdgeNotes.linePinnedOpen"
        static let hotkeyHang = "EdgeNotes.hotkeyHang"
        static let lineCardSize = "EdgeNotes.lineCardSize"
        static let clipboardHistoryEnabled = "EdgeNotes.clipboardHistoryEnabled"
        static let clipboardCardSize = "EdgeNotes.clipboardCardSize"
        static let clipboardMaxEntries = "EdgeNotes.clipboardMaxEntries"
        static let clipboardRetentionDays = "EdgeNotes.clipboardRetentionDays"
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

        hotkeyToggle = Self.loadChord(d, Keys.hotkeyToggle) ?? .optionCommandN
        hotkeyCapture = Self.loadChord(d, Keys.hotkeyCapture) ?? .optionCommandT
        sidebarHidden = d.bool(forKey: Keys.sidebarHidden)
        clotheslineEnabled = d.object(forKey: Keys.clotheslineEnabled) == nil ? true : d.bool(forKey: Keys.clotheslineEnabled)
        lineAutoRemoveDays = max(0, d.integer(forKey: Keys.lineAutoRemoveDays))
        lineShowInFullScreen = d.bool(forKey: Keys.lineShowInFullScreen)
        linePinnedOpen = d.bool(forKey: Keys.linePinnedOpen)
        hotkeyHang = Self.loadChord(d, Keys.hotkeyHang) ?? .optionCommandShiftH
        lineCardSize = d.string(forKey: Keys.lineCardSize).flatMap(LineCardSize.init(rawValue:)) ?? .small
        clipboardHistoryEnabled = d.object(forKey: Keys.clipboardHistoryEnabled) == nil ? true : d.bool(forKey: Keys.clipboardHistoryEnabled)
        clipboardCardSize = d.string(forKey: Keys.clipboardCardSize).flatMap(LineCardSize.init(rawValue:)) ?? .small
        let maxEntries = d.integer(forKey: Keys.clipboardMaxEntries)
        clipboardMaxEntries = Self.clipboardEntryOptions.contains(maxEntries) ? maxEntries : 40
        clipboardRetentionDays = d.object(forKey: Keys.clipboardRetentionDays) == nil ? 7 : max(0, d.integer(forKey: Keys.clipboardRetentionDays))
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

    func setHotkeyToggle(_ chord: HotKeyChord) {
        hotkeyToggle = chord
        saveChord(chord, key: Keys.hotkeyToggle)
    }

    func setHotkeyCapture(_ chord: HotKeyChord) {
        hotkeyCapture = chord
        saveChord(chord, key: Keys.hotkeyCapture)
    }

    func setSidebarHidden(_ hidden: Bool) {
        sidebarHidden = hidden
        defaults.set(hidden, forKey: Keys.sidebarHidden)
    }

    func setClotheslineEnabled(_ on: Bool) {
        clotheslineEnabled = on
        defaults.set(on, forKey: Keys.clotheslineEnabled)
    }

    func setLineAutoRemoveDays(_ days: Int) {
        lineAutoRemoveDays = max(0, days)
        defaults.set(lineAutoRemoveDays, forKey: Keys.lineAutoRemoveDays)
    }

    func setLineShowInFullScreen(_ on: Bool) {
        lineShowInFullScreen = on
        defaults.set(on, forKey: Keys.lineShowInFullScreen)
    }

    func setLinePinnedOpen(_ on: Bool) {
        linePinnedOpen = on
        defaults.set(on, forKey: Keys.linePinnedOpen)
    }

    func setLineCardSize(_ size: LineCardSize) {
        lineCardSize = size
        defaults.set(size.rawValue, forKey: Keys.lineCardSize)
    }

    func setClipboardMaxEntries(_ n: Int) {
        clipboardMaxEntries = n
        defaults.set(n, forKey: Keys.clipboardMaxEntries)
    }

    func setClipboardRetentionDays(_ days: Int) {
        clipboardRetentionDays = max(0, days)
        defaults.set(clipboardRetentionDays, forKey: Keys.clipboardRetentionDays)
    }

    func setClipboardCardSize(_ size: LineCardSize) {
        clipboardCardSize = size
        defaults.set(size.rawValue, forKey: Keys.clipboardCardSize)
    }

    func setClipboardHistoryEnabled(_ on: Bool) {
        clipboardHistoryEnabled = on
        defaults.set(on, forKey: Keys.clipboardHistoryEnabled)
    }

    func setHotkeyHang(_ chord: HotKeyChord) {
        hotkeyHang = chord
        saveChord(chord, key: Keys.hotkeyHang)
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

/// 挂绳卡片大小：小 = 原尺寸
enum LineCardSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    /// 各尺寸卡片的版面：大卡不是放大，而是更宽更高、能显示更多内容
    var metrics: CardMetrics {
        switch self {
        case .small:  return CardMetrics(width: 128, minHeight: 96, maxHeight: 150, titleLines: 2, bodyLines: 5, photoWidth: 124, photoMaxHeight: 160, iconSize: 64)
        case .medium: return CardMetrics(width: 184, minHeight: 130, maxHeight: 250, titleLines: 3, bodyLines: 11, photoWidth: 180, photoMaxHeight: 240, iconSize: 88)
        case .large:  return CardMetrics(width: 250, minHeight: 170, maxHeight: 360, titleLines: 3, bodyLines: 18, photoWidth: 246, photoMaxHeight: 340, iconSize: 112)
        }
    }

    /// 剪贴板大卡片的尺寸
    var clipboardSize: CGSize {
        switch self {
        case .small: return CGSize(width: 236, height: 206)
        case .medium: return CGSize(width: 290, height: 290)
        case .large: return CGSize(width: 350, height: 380)
        }
    }
    var label: String {
        switch self {
        case .small: return L("小")
        case .medium: return L("中")
        case .large: return L("大")
        }
    }
}

struct CardMetrics {
    var width: CGFloat
    var minHeight: CGFloat
    var maxHeight: CGFloat
    var titleLines: Int
    var bodyLines: Int
    var photoWidth: CGFloat
    var photoMaxHeight: CGFloat
    var iconSize: CGFloat
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

    static var optionCommandShiftH: HotKeyChord {
        HotKeyChord(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | optionKey | shiftKey), label: "⌥⇧⌘H")
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
            alert.messageText = L("解锁这条便签？")
            alert.informativeText = L("解锁后正文可以编辑。")
            alert.addButton(withTitle: L("解锁"))
            alert.addButton(withTitle: L("取消"))
            NSApp.activate(ignoringOtherApps: true)
            let ok = alert.runModal() == .alertFirstButtonReturn
            if ok { store.setLocked(id: id, false) }
            completion?(ok)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L("解锁便签")) { success, _ in
            Task { @MainActor in
                if success { store.setLocked(id: id, false) }
                completion?(success)
            }
        }
    }
}
