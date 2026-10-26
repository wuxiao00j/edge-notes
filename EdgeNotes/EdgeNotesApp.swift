import SwiftUI
import AppKit
import Sparkle

@main
struct EdgeNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

/// 设置界面（菜单栏「设置…」打开独立窗口；⌘, 走 Settings 场景）
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
    ScrollView {
        Form {
        Section(L("挂绳")) {
            Toggle(L("挂绳模式（屏幕顶部的晾衣绳）"), isOn: Binding(
                get: { settings.clotheslineEnabled },
                set: { settings.setClotheslineEnabled($0) }
            ))
            Picker(L("卡片大小"), selection: Binding(
                get: { settings.lineCardSize },
                set: { settings.setLineCardSize($0) }
            )) {
                ForEach(LineCardSize.allCases) { size in
                    Text(size.label).tag(size)
                }
            }
            .pickerStyle(.segmented)
            Picker(L("挂满后自动取下"), selection: Binding(
                get: { settings.lineAutoRemoveDays },
                set: { settings.setLineAutoRemoveDays($0) }
            )) {
                Text(L("不自动取下")).tag(0)
                Text(L("1 天")).tag(1)
                Text(L("3 天")).tag(3)
                Text(L("7 天")).tag(7)
                Text(L("30 天")).tag(30)
            }
            Toggle(L("钉住挂绳（一直放下，不自动收起）"), isOn: Binding(
                get: { settings.linePinnedOpen },
                set: { settings.setLinePinnedOpen($0) }
            ))
            Toggle(L("在全屏 App 中也显示"), isOn: Binding(
                get: { settings.lineShowInFullScreen },
                set: { settings.setLineShowInFullScreen($0) }
            ))
            Text(L("鼠标移到菜单栏正下方停一下，绳子就会放下来并置顶；把图片、文字、链接或文件拖到绳上即可挂起（文件只记位置，不复制）；左右拖动换位置，往下拖出来可放进其它 App；点夹子取下。单击图片看大图，单击文字便签进入编辑。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section(L("剪贴板历史")) {
            Toggle(L("记录复制过的内容，挂在绳上的大卡片里"), isOn: Binding(
                get: { settings.clipboardHistoryEnabled },
                set: { settings.setClipboardHistoryEnabled($0) }
            ))
            Text(LF("点卡片里的任意一条即可重新复制（文字、图片、文件）。保留最近 %@ 条；密码管理器等标记为隐私的内容不会记录。", ClipboardHistory.maxEntries))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section(L("窗口")) {
            Toggle(L("便签窗口始终置顶"), isOn: Binding(
                get: { settings.isAlwaysOnTop },
                set: { NotesWindowController.shared.setAlwaysOnTop($0) }
            ))
            HStack {
                Text(L("默认透明度"))
                Slider(value: Binding(
                    get: { settings.defaultOpacity },
                    set: { settings.setDefaultOpacity($0) }
                ), in: 0.35...1)
                Text("\(Int(settings.defaultOpacity * 100))%")
                    .frame(width: 40)
            }
            Toggle(L("登录时打开"), isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.setLaunchAtLogin($0) }
            ))
        }
        Section(L("隐私")) {
            Toggle(L("速藏正文（列表、挂绳与通知不显示内容）"), isOn: Binding(
                get: { settings.privacyHideBodies },
                set: { settings.setPrivacyHideBodies($0) }
            ))
            Text(L("锁定的单条便签始终在通知里隐藏正文。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section(L("快捷键（点击后按下新组合）")) {
            HotKeyRecorderButton(
                title: L("显示/隐藏全部便签"),
                chord: Binding(
                    get: { settings.hotkeyToggle },
                    set: { settings.setHotkeyToggle($0) }
                ),
                onChange: { HotKeyManager.shared.reloadFromSettings() }
            )
            HotKeyRecorderButton(
                title: L("新建挂绳便签"),
                chord: Binding(
                    get: { settings.hotkeyCapture },
                    set: { settings.setHotkeyCapture($0) }
                ),
                onChange: { HotKeyManager.shared.reloadFromSettings() }
            )
            HotKeyRecorderButton(
                title: L("剪贴板 → 挂绳"),
                chord: Binding(
                    get: { settings.hotkeyHang },
                    set: { settings.setHotkeyHang($0) }
                ),
                onChange: { HotKeyManager.shared.reloadFromSettings() }
            )
        }
        Section(L("更新")) {
            Toggle(L("自动检查更新"), isOn: Binding(
                get: { AppDelegate.current?.updater?.updater.automaticallyChecksForUpdates ?? false },
                set: { AppDelegate.current?.updater?.updater.automaticallyChecksForUpdates = $0 }
            ))
            Button(L("检查更新…")) { AppDelegate.current?.updater?.checkForUpdates(nil) }
        }
        Section(L("数据")) {
            HStack {
                Text("~/Library/Application Support/EdgeNotes/")
                    .font(.caption)
                    .textSelection(.enabled)
                Spacer()
                Button(L("在 Finder 中打开")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: AppDelegate.current?.store.dataDirectoryPath ?? NoteStore.defaultDirectory.path))
                }
            }
            Text(LF("离线可用；每天自动备份到 Backups/（保留 %@ 天），回收站 %@ 天后自动清空。「全部便签」窗口的「…」菜单可导出或手动备份。无 iCloud。", NoteStore.dailyBackupsKept, NoteStore.trashRetentionDays))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    .padding(20)
    .frame(width: 500)
        }
        .frame(minHeight: 420, idealHeight: 640)
    }
}

/// 自己管理设置窗口：菜单栏 App 用 showSettingsWindow: 打不开 SwiftUI 的 Settings 场景
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: host)
            w.title = L("设置")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 520, height: 640))
            w.setFrameAutosaveName("EdgeNotes.Settings")
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// 跑单元测试时宿主 App 用临时目录，绝不碰真实数据
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    let store = NoteStore(directory: AppDelegate.isRunningTests
        ? FileManager.default.temporaryDirectory.appendingPathComponent("EdgeNotesTestHost-\(UUID().uuidString)")
        : nil)
    private var statusItem: NSStatusItem?
    /// Sparkle 自动更新（从 GitHub 上的 appcast.xml 检查新版本）
    private(set) var updater: SPUStandardUpdaterController?

    /// 给快捷指令等找到当前的数据
    private(set) static var current: AppDelegate?

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppDelegate.current = self
        guard !Self.isRunningTests else { return }
        // 通知代理要在启动完成前设好，才能处理「点通知把 App 拉起来」
        ReminderManager.shared.start(store: store)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 单元测试宿主：不装窗口、快捷键、剪贴板监听
        guard !Self.isRunningTests else { return }
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        NoteWindowManager.shared.attach(store: store)
        NotesWindowController.shared.install(
            rootView: ContentView().environmentObject(store)
        )

        HotKeyManager.shared.register(
            toggle: { NotesWindowController.shared.toggle() },
            capture: { [weak self] in self?.newLineNote() },
            hang: { ClotheslineController.shared.hangClipboard() }
        )

        ClipboardHistory.shared.start(dataDirectory: URL(fileURLWithPath: store.dataDirectoryPath))
        ClotheslineController.shared.install(store: store)

        setupStatusItem()

        if let failure = store.loadFailure {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = L("便签数据读取失败")
            alert.informativeText = failure + L("\n\n可在数据目录的 Backups/ 中找到每日备份。")
            alert.addButton(withTitle: L("打开数据目录"))
            alert.addButton(withTitle: L("好"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(fileURLWithPath: store.dataDirectoryPath))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
        ClipboardHistory.shared.flush()
        HotKeyManager.shared.unregister()
    }

    /// 新建一张挂在绳上的便签，并在小编辑窗里开始输入
    private func newLineNote() {
        let note = store.addLineNote(body: "")
        ClotheslineController.shared.flash()
        NoteWindowManager.shared.open(noteID: note.id, store: store, focusEditor: true)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: L("贴边便签"))
            button.toolTip = L("贴边便签")
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// 每次打开菜单时重建，勾选状态与快捷键提示始终是最新的
    func menuNeedsUpdate(_ menu: NSMenu) {
        let s = AppSettings.shared
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, on: Bool? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let on { item.state = on ? .on : .off }
            menu.addItem(item)
        }
        add(LF("全部便签\t%@", s.hotkeyToggle.label), #selector(toggleNotesWindow))
        add(LF("新建挂绳便签\t%@", s.hotkeyCapture.label), #selector(newLineNoteAction))
        add(LF("剪贴板 → 挂绳\t%@", s.hotkeyHang.label), #selector(hangClipboard))
        menu.addItem(.separator())
        add(L("挂绳模式"), #selector(toggleLine), on: s.clotheslineEnabled)
        add(L("钉住挂绳"), #selector(togglePinLine), on: s.linePinnedOpen)
        add(L("剪贴板历史"), #selector(toggleClipboardHistory), on: s.clipboardHistoryEnabled)
        let sizeItem = NSMenuItem(title: L("卡片大小"), action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for size in LineCardSize.allCases {
            let it = NSMenuItem(title: size.label, action: #selector(setCardSize(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = size.rawValue
            it.state = s.lineCardSize == size ? .on : .off
            sizeMenu.addItem(it)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        menu.addItem(.separator())
        add(L("便签窗口始终置顶"), #selector(togglePin), on: s.isAlwaysOnTop)
        add(L("速藏正文"), #selector(togglePrivacy), on: s.privacyHideBodies)
        menu.addItem(.separator())
        add(L("设置…"), #selector(openSettings))
        add(L("检查更新…"), #selector(checkForUpdates))
        let quit = NSMenuItem(title: L("退出"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleNotesWindow() { NotesWindowController.shared.toggle() }
    @objc private func newLineNoteAction() { newLineNote() }
    @objc private func hangClipboard() { ClotheslineController.shared.hangClipboard() }
    @objc private func toggleLine() { AppSettings.shared.setClotheslineEnabled(!AppSettings.shared.clotheslineEnabled) }
    @objc private func togglePinLine() { AppSettings.shared.setLinePinnedOpen(!AppSettings.shared.linePinnedOpen) }
    @objc private func toggleClipboardHistory() {
        AppSettings.shared.setClipboardHistoryEnabled(!AppSettings.shared.clipboardHistoryEnabled)
    }
    @objc private func setCardSize(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let size = LineCardSize(rawValue: raw) {
            AppSettings.shared.setLineCardSize(size)
        }
    }
    @objc private func togglePin() { NotesWindowController.shared.setAlwaysOnTop(!AppSettings.shared.isAlwaysOnTop) }
    @objc private func togglePrivacy() { AppSettings.shared.setPrivacyHideBodies(!AppSettings.shared.privacyHideBodies) }
    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updater?.checkForUpdates(nil)
    }
    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }
    @objc private func quit() {
        store.flush()
        NSApp.terminate(nil)
    }
}
