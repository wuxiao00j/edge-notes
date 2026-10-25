import SwiftUI
import AppKit

@main
struct EdgeNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        Settings {
            Form {
                Section("窗口") {
                    Toggle("始终置顶", isOn: Binding(
                        get: { settings.isAlwaysOnTop },
                        set: { EdgePanelController.shared.setAlwaysOnTop($0) }
                    ))
                    HStack {
                        Text("默认透明度")
                        Slider(value: Binding(
                            get: { settings.defaultOpacity },
                            set: { settings.setDefaultOpacity($0) }
                        ), in: 0.35...1)
                        Text("\(Int(settings.defaultOpacity * 100))%")
                            .frame(width: 40)
                    }
                    Toggle("登录时打开", isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.setLaunchAtLogin($0) }
                    ))
                }
                Section("隐私") {
                    Toggle("速藏正文（列表与通知不显示内容）", isOn: Binding(
                        get: { settings.privacyHideBodies },
                        set: { settings.setPrivacyHideBodies($0) }
                    ))
                    Text("锁定的单条便签始终在通知里隐藏正文。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("快捷键（点击后按下新组合）") {
                    HotKeyRecorderButton(
                        title: "显示/隐藏侧栏",
                        chord: Binding(
                            get: { settings.hotkeyToggle },
                            set: { settings.setHotkeyToggle($0) }
                        ),
                        onChange: { HotKeyManager.shared.reloadFromSettings() }
                    )
                    HotKeyRecorderButton(
                        title: "极速新建",
                        chord: Binding(
                            get: { settings.hotkeyCapture },
                            set: { settings.setHotkeyCapture($0) }
                        ),
                        onChange: { HotKeyManager.shared.reloadFromSettings() }
                    )
                    HotKeyRecorderButton(
                        title: "选区/剪贴板 → 便签",
                        chord: Binding(
                            get: { settings.hotkeyPaste },
                            set: { settings.setHotkeyPaste($0) }
                        ),
                        onChange: { HotKeyManager.shared.reloadFromSettings() }
                    )
                    Text("选区贴入需要「系统设置 → 隐私与安全性 → 辅助功能」允许贴边便签；未授权时自动改用剪贴板。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !SelectionCapture.accessibilityTrusted() {
                        Button("请求辅助功能权限…") {
                            SelectionCapture.promptAccessibilityIfNeeded()
                        }
                    } else {
                        Label("已获得辅助功能权限", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
                Section("数据") {
                    Text("~/Library/Application Support/EdgeNotes/")
                        .font(.caption)
                    Text("离线可用；侧栏「…」可导出或手动备份。无 iCloud。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(width: 480)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = NoteStore()
    private var statusItem: NSStatusItem?
    private var pinItem: NSMenuItem?
    private var privacyItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        NoteWindowManager.shared.attach(store: store)
        ReminderManager.shared.start(store: store)

        EdgePanelController.shared.install(
            rootView: ContentView().environmentObject(store)
        )
        EdgePanelController.shared.applyWindowLevel()

        for note in store.notes where note.pinnedToDesktop && !note.isArchived {
            NoteWindowManager.shared.open(noteID: note.id, store: store, focusEditor: false)
        }

        HotKeyManager.shared.register(
            toggle: { [weak self] in
                EdgePanelController.shared.toggle()
                self?.refreshPanel()
            },
            capture: { [weak self] in self?.instantCapture() },
            paste: { [weak self] in self?.pasteSelectionOrClipboard() }
        )

        setupStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
        HotKeyManager.shared.unregister()
    }

    private func refreshPanel() {
        EdgePanelController.shared.updateRootView(
            ContentView().environmentObject(store)
        )
    }

    private func instantCapture() {
        let note = store.addNote(select: true)
        refreshPanel()
        EdgePanelController.shared.expand(animated: true)
        EdgePanelController.shared.makeKeyForEditing()
        NoteWindowManager.shared.open(noteID: note.id, store: store, focusEditor: true)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func pasteSelectionOrClipboard() {
        let result = SelectionCapture.capturePreferringSelection()
        var body = result.text
        if body.isEmpty {
            body = "（未读到选区或剪贴板。若要用选区，请在设置里授予辅助功能权限。）"
        } else {
            body = "<!-- 来源：\(result.source) -->\n" + body
        }
        let note = store.addNote(title: "", body: body, select: true)
        refreshPanel()
        NoteWindowManager.shared.open(noteID: note.id, store: store, focusEditor: true)
        EdgePanelController.shared.expand(animated: true)
        AppSettings.shared.setMainViewMode(.desktop)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "贴边便签")
            button.toolTip = "贴边便签"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示/隐藏侧栏", action: #selector(togglePanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "极速新建", action: #selector(capture), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "选区/剪贴板 → 新便签", action: #selector(pasteNote), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "新建到侧栏", action: #selector(newSidebar), keyEquivalent: "n"))
        menu.addItem(NSMenuItem(title: "贴回右边缘", action: #selector(redock), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let pin = NSMenuItem(title: "始终置顶", action: #selector(togglePin), keyEquivalent: "")
        pin.state = AppSettings.shared.isAlwaysOnTop ? .on : .off
        pinItem = pin
        menu.addItem(pin)
        let priv = NSMenuItem(title: "速藏正文", action: #selector(togglePrivacy), keyEquivalent: "")
        priv.state = AppSettings.shared.privacyHideBodies ? .on : .off
        privacyItem = priv
        menu.addItem(priv)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() { EdgePanelController.shared.toggle() }
    @objc private func capture() { instantCapture() }
    @objc private func pasteNote() { pasteSelectionOrClipboard() }
    @objc private func newSidebar() {
        store.addNote(select: true)
        refreshPanel()
        EdgePanelController.shared.expand(animated: true)
        EdgePanelController.shared.makeKeyForEditing()
    }
    @objc private func redock() { EdgePanelController.shared.redockExpanded(animated: true) }
    @objc private func togglePin() {
        let next = !AppSettings.shared.isAlwaysOnTop
        EdgePanelController.shared.setAlwaysOnTop(next)
        pinItem?.state = next ? .on : .off
        refreshPanel()
    }
    @objc private func togglePrivacy() {
        let next = !AppSettings.shared.privacyHideBodies
        AppSettings.shared.setPrivacyHideBodies(next)
        privacyItem?.state = next ? .on : .off
        refreshPanel()
    }
    @objc private func quit() {
        store.flush()
        NSApp.terminate(nil)
    }
}
