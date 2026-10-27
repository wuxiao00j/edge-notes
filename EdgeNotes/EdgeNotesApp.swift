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
    @ObservedObject private var sync = CloudSync.shared

    private var syncStatusText: String {
        switch sync.status {
        case .off: return L("未开启。本机数据和每日备份不受影响。")
        case .unavailable: return L("这个版本没有启用 iCloud（开发版或旧版）。请安装 GitHub 上的正式版。")
        case .syncing: return L("正在同步…")
        case .synced(let date): return LF("上次同步：%@", date.formatted(date: .abbreviated, time: .shortened))
        case .error(let message): return LF("同步出错：%@", message)
        }
    }

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
        Section(L("iCloud 同步（测试版）")) {
            Toggle(L("通过 iCloud 在你的多台 Mac 间同步便签"), isOn: Binding(
                get: { settings.iCloudSyncEnabled },
                set: { settings.setICloudSyncEnabled($0) }
            ))
            .disabled(!CloudSync.isAvailable)
            HStack {
                Text(syncStatusText)
                    .font(.caption)
                    .foregroundStyle({ if case .error = sync.status { return Color.red } else { return Color.secondary } }())
                Spacer()
                if settings.iCloudSyncEnabled && CloudSync.isAvailable {
                    Button(L("立即同步")) { sync.syncNow() }
                        .disabled(sync.status == .syncing)
                }
            }
            Text(L("同步便签、回收站和图片；标题和正文端到端加密。不同步历史版本、剪贴板历史和设置。挂绳上的文件只同步卡片，文件本身不上传。两台 Mac 同时改同一条时会保留一份「冲突副本」，不会丢字。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section(L("剪贴板历史")) {
            Toggle(L("记录复制过的内容，挂在绳上的大卡片里"), isOn: Binding(
                get: { settings.clipboardHistoryEnabled },
                set: { settings.setClipboardHistoryEnabled($0) }
            ))
            Picker(L("保留条数"), selection: Binding(
                get: { settings.clipboardMaxEntries },
                set: { settings.setClipboardMaxEntries($0) }
            )) {
                ForEach(AppSettings.clipboardEntryOptions, id: \.self) { Text(LF("%@ 条", $0)).tag($0) }
            }
            Picker(L("自动清理"), selection: Binding(
                get: { settings.clipboardRetentionDays },
                set: { settings.setClipboardRetentionDays($0) }
            )) {
                ForEach(AppSettings.clipboardRetentionOptions, id: \.self) { days in
                    Text(days == 0 ? L("不清理") : LF("%@ 天后", days)).tag(days)
                }
            }
            Text(L("点卡片里的任意一条即可重新复制（文字、图片、文件）。超出条数时最旧的会被挤掉；密码管理器等标记为隐私的内容不会记录。记录只保存在本机。"))
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
        Section(L("支持作者")) {
            HStack {
                Text(L("贴边便签免费开源。觉得好用的话，可以请作者喝杯咖啡。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("☕ 支持作者…")) { SponsorWindowController.shared.show() }
            }
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

/// 支持作者：微信扫码打赏
struct SponsorView: View {
    var body: some View {
        VStack(spacing: 14) {
            Text(L("请作者喝杯咖啡 ☕"))
                .font(.system(size: 18, weight: .semibold))
            Text(L("如果贴边便签帮到了你，欢迎用微信扫码随意打赏。你的支持是持续更新的动力。"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Image("SponsorQR")
                .resizable()
                .interpolation(.high)
                .frame(width: 240, height: 240)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .padding(.vertical, 4)
            Label(L("微信扫一扫"), systemImage: "qrcode.viewfinder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(red: 0.03, green: 0.76, blue: 0.38))
            Text(L("贴边便签永久免费、开源，打赏完全自愿。"))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(width: 340)
    }
}

@MainActor
final class SponsorWindowController {
    static let shared = SponsorWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SponsorView()))
            w.title = L("支持作者")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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
        CloudSync.shared.configure(store: store, dataDirectory: URL(fileURLWithPath: store.dataDirectoryPath))
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
        add(L("☕ 支持作者…"), #selector(openSponsor))
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
    @objc private func openSponsor() { SponsorWindowController.shared.show() }
    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }
    @objc private func quit() {
        store.flush()
        NSApp.terminate(nil)
    }
}
