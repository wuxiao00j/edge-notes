import AppKit
import SwiftUI
import Combine

/// 「全部便签」窗口：查看、搜索、编辑所有便签。平时隐藏，从菜单栏图标或快捷键打开。
@MainActor
final class NotesWindowController: NSObject {
    static let shared = NotesWindowController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var settingsCancellable: AnyCancellable?

    private override init() { super.init() }

    func install(rootView: some View) {
        if panel != nil {
            hostingView?.rootView = AnyView(rootView)
            return
        }
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = NSSize(width: 520, height: 380)

        let host = NSHostingView(rootView: AnyView(rootView))
        panel.contentView = host
        panel.setFrameAutosaveName("EdgeNotes.AllNotes")
        if !panel.setFrameUsingName("EdgeNotes.AllNotes") { panel.center() }

        self.panel = panel
        self.hostingView = host
        applyWindowLevel()

        settingsCancellable = AppSettings.shared.$isAlwaysOnTop
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyWindowLevel() }
    }

    func updateRootView(_ rootView: some View) {
        hostingView?.rootView = AnyView(rootView)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle() {
        guard let panel else { return }
        if panel.isVisible && panel.isKeyWindow { hide() } else { show() }
    }

    func makeKeyForEditing() {
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // 下一拍把焦点交给正文编辑器（若已挂接）
        DispatchQueue.main.async {
            if let tv = panel.contentView?.findSubview(ofType: NSTextView.self), tv.isEditable {
                panel.makeFirstResponder(tv)
            } else if let field = panel.contentView?.findSubview(ofType: NSTextField.self) {
                panel.makeFirstResponder(field)
            }
        }
    }

    func setAlwaysOnTop(_ on: Bool) {
        AppSettings.shared.setAlwaysOnTop(on)
        applyWindowLevel()
        NoteWindowManager.shared.applyAlwaysOnTop(on)
    }

    func applyWindowLevel() {
        panel?.level = AppSettings.shared.isAlwaysOnTop ? .floating : .normal
    }
}

struct PanelDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleNSView { DragHandleNSView() }
    func updateNSView(_ nsView: DragHandleNSView, context: Context) {}
}

/// 顶栏拖动：整窗跟随
final class DragHandleNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
