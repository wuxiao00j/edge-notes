import AppKit
import SwiftUI
import Combine

@MainActor
final class EdgePanelController: NSObject {
    static let shared = EdgePanelController()

    enum Mode { case docked, pinned }

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var hideWorkItem: DispatchWorkItem?
    private var settingsCancellable: AnyCancellable?
    private var edgeDockCancellable: AnyCancellable?

    private var edgeDock: Bool { AppSettings.shared.edgeDockEnabled }

    private let panelWidth: CGFloat = 380
    private let panelHeight: CGFloat = 560
    private let stripWidth: CGFloat = 8
    private let hideDelay: TimeInterval = 0.4
    private let animationDuration: TimeInterval = 0.22
    private let snapEdgeDistance: CGFloat = 48

    private(set) var isExpanded = false
    private(set) var mode: Mode = .docked
    private var isDragging = false
    private var pinnedOrigin: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var dragStartMouse: NSPoint?

    private override init() { super.init() }

    func install(rootView: some View) {
        if panel != nil {
            hostingView?.rootView = AnyView(rootView)
            applyWindowLevel()
            return
        }

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = NSSize(width: 300, height: 360)

        let host = NSHostingView(rootView: AnyView(rootView))
        host.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        panel.contentView = host

        self.panel = panel
        self.hostingView = host
        applyWindowLevel()
        collapse(animated: false)
        // 贴边呼出关闭时，侧栏平时完全隐藏，只在菜单栏/快捷键打开时出现
        if edgeDock { panel.orderFrontRegardless() }
        startMouseMonitoring()

        settingsCancellable = AppSettings.shared.$isAlwaysOnTop
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyWindowLevel() }
        edgeDockCancellable = AppSettings.shared.$edgeDockEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.applyEdgeDock(on) }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParamsChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func updateRootView(_ rootView: some View) {
        hostingView?.rootView = AnyView(rootView)
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

    func toggle() {
        guard let panel else { return }
        if !edgeDock && mode == .docked {
            if panel.isVisible && isExpanded { collapse(animated: true) }
            else {
                expand(animated: false)
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        if mode == .pinned {
            if panel.isVisible { panel.orderOut(nil) }
            else {
                if let origin = pinnedOrigin {
                    var frame = panel.frame
                    frame.origin = origin
                    panel.setFrame(clampOnScreen(frame), display: true)
                }
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        if isExpanded { collapse(animated: true) }
        else {
            expand(animated: true)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func expand(animated: Bool) {
        hideWorkItem?.cancel(); hideWorkItem = nil
        guard let panel, let screen = dockingScreen() else { return }
        if mode == .pinned, let origin = pinnedOrigin {
            var frame = panel.frame
            frame.origin = origin
            setFrame(clampOnScreen(frame), animated: animated)
            isExpanded = true
            panel.orderFrontRegardless()
            return
        }
        mode = .docked
        let visible = visibleFrame(on: screen)
        let target = NSRect(
            x: visible.maxX - panel.frame.width,
            y: clampedY(panel.frame.minY, height: panel.frame.height, in: visible),
            width: panel.frame.width,
            height: panel.frame.height
        )
        setFrame(target, animated: animated)
        isExpanded = true
        panel.orderFrontRegardless()
    }

    func collapse(animated: Bool) {
        hideWorkItem?.cancel(); hideWorkItem = nil
        guard let panel, let screen = dockingScreen() else { return }
        mode = .docked
        pinnedOrigin = nil
        if !edgeDock {
            // 不贴边：收起即隐藏，不留右边缘细条
            panel.orderOut(nil)
            isExpanded = false
            let visible = visibleFrame(on: screen)
            panel.setFrame(NSRect(
                x: visible.maxX - panel.frame.width,
                y: clampedY(panel.frame.minY, height: panel.frame.height, in: visible),
                width: panel.frame.width,
                height: panel.frame.height
            ), display: false)
            return
        }
        let visible = visibleFrame(on: screen)
        let target = NSRect(
            x: visible.maxX - stripWidth,
            y: clampedY(panel.frame.minY, height: panel.frame.height, in: visible),
            width: panel.frame.width,
            height: panel.frame.height
        )
        setFrame(target, animated: animated)
        isExpanded = false
    }

    func redockExpanded(animated: Bool) {
        mode = .docked
        pinnedOrigin = nil
        expand(animated: animated)
    }

    func isEdgePanel(_ window: NSWindow?) -> Bool {
        guard let window, let panel else { return false }
        return window === panel
    }

    // MARK: Drag

    func beginDrag(with event: NSEvent) {
        guard let panel else { return }
        isDragging = true
        hideWorkItem?.cancel(); hideWorkItem = nil
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = panel.frame.origin
        if mode == .docked && !isExpanded { expand(animated: false) }
    }

    func continueDrag() {
        guard isDragging, let panel, let startOrigin = dragStartOrigin, let startMouse = dragStartMouse else { return }
        let mouse = NSEvent.mouseLocation
        var frame = panel.frame
        frame.origin = NSPoint(x: startOrigin.x + mouse.x - startMouse.x, y: startOrigin.y + mouse.y - startMouse.y)
        panel.setFrame(clampOnScreen(frame), display: true)
    }

    func endDrag() {
        guard isDragging, let panel else { isDragging = false; return }
        isDragging = false
        dragStartOrigin = nil
        dragStartMouse = nil
        guard let screen = panel.screen ?? dockingScreen() else { return }
        let visible = visibleFrame(on: screen)
        if visible.maxX - panel.frame.maxX <= snapEdgeDistance {
            mode = .docked
            pinnedOrigin = nil
            let target = NSRect(
                x: visible.maxX - panel.frame.width,
                y: clampedY(panel.frame.minY, height: panel.frame.height, in: visible),
                width: panel.frame.width,
                height: panel.frame.height
            )
            setFrame(target, animated: true)
            isExpanded = true
        } else {
            mode = .pinned
            pinnedOrigin = panel.frame.origin
            isExpanded = true
        }
    }

    private func setFrame(_ frame: NSRect, animated: Bool) {
        guard let panel else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = animationDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func dockingScreen() -> NSScreen? { panel?.screen ?? NSScreen.main ?? NSScreen.screens.first }
    private func visibleFrame(on screen: NSScreen) -> NSRect { screen.visibleFrame }

    private func clampedY(_ y: CGFloat, height: CGFloat, in visible: NSRect) -> CGFloat {
        min(max(y, visible.minY), max(visible.minY, visible.maxY - height))
    }

    private func clampOnScreen(_ frame: NSRect) -> NSRect {
        var f = frame
        let screens = NSScreen.screens
        // Prefer intersecting screen; else main
        let screen = screens.first { $0.frame.intersects(f) } ?? NSScreen.main ?? screens.first
        guard let screen else { return f }
        let visible = visibleFrame(on: screen)
        // Keep at least stripWidth visible
        f.origin.x = min(max(f.origin.x, visible.minX - f.width + stripWidth), visible.maxX - stripWidth)
        f.origin.y = clampedY(f.origin.y, height: f.height, in: visible)
        return f
    }

    private func startMouseMonitoring() {
        stopMouseMonitoring()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if self.isDragging {
                if event.type == .leftMouseDragged { self.continueDrag() }
                if event.type == .leftMouseUp { self.endDrag() }
            } else {
                self.handleMouseMoved()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return }
            if self.isDragging {
                if event.type == .leftMouseDragged { self.continueDrag() }
                if event.type == .leftMouseUp { self.endDrag() }
            } else {
                self.handleMouseMoved()
            }
        }
    }

    private func stopMouseMonitoring() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
    }

    private func handleMouseMoved() {
        // 不贴边时侧栏像普通窗口：不靠边缘呼出，也不在鼠标离开时自动收起
        guard edgeDock, !isDragging, mode == .docked, let panel, let screen = dockingScreen() else { return }
        let mouse = NSEvent.mouseLocation
        let visible = visibleFrame(on: screen)
        let frame = panel.frame
        let hotZone = NSRect(x: visible.maxX - max(stripWidth + 4, 12), y: frame.minY, width: max(stripWidth + 4, 12), height: frame.height)
        let inside = frame.contains(mouse) || hotZone.contains(mouse)
        if isExpanded {
            if inside { hideWorkItem?.cancel(); hideWorkItem = nil }
            else { scheduleHide() }
        } else if inside {
            expand(animated: true)
        }
    }

    private func scheduleHide() {
        guard mode == .docked, !isDragging, hideWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .docked, !self.isDragging else { self?.hideWorkItem = nil; return }
            self.collapse(animated: true)
            self.hideWorkItem = nil
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: work)
    }

    private func applyEdgeDock(_ on: Bool) {
        guard let panel else { return }
        if on {
            if !panel.isVisible { collapse(animated: false); panel.orderFrontRegardless() }
        } else if !isExpanded {
            panel.orderOut(nil)
        }
    }

    @objc private func screenParamsChanged() {
        guard !isDragging else { return }
        if mode == .pinned, let panel {
            let clamped = clampOnScreen(panel.frame)
            panel.setFrame(clamped, display: true)
            pinnedOrigin = clamped.origin
        } else if isExpanded {
            expand(animated: false)
        } else {
            collapse(animated: false)
        }
        NoteWindowManager.shared.clampAllOnScreen()
    }
}

struct PanelDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleNSView { DragHandleNSView() }
    func updateNSView(_ nsView: DragHandleNSView, context: Context) {}
}

/// 顶栏拖动：侧栏走贴边吸附逻辑；独立弹窗拖动自身窗口。
final class DragHandleNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if EdgePanelController.shared.isEdgePanel(window) {
            EdgePanelController.shared.beginDrag(with: event)
            var keep = true
            while keep {
                guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
                switch next.type {
                case .leftMouseDragged:
                    EdgePanelController.shared.continueDrag()
                case .leftMouseUp:
                    EdgePanelController.shared.endDrag()
                    keep = false
                default:
                    break
                }
            }
        } else {
            // 独立贴纸窗：整窗跟随拖动
            window.performDrag(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
