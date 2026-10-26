import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import QuickLookThumbnailing

/// 挂绳模式：屏幕顶端（菜单栏下方）一根晾衣绳。
/// 平时只露出一道细绳、不拦截点击；鼠标在绳上停一下就放下来并置顶，夹着的便签/图片垂下；离开后收回。
@MainActor
final class ClotheslineController: NSObject, NSDraggingSource {
    static let shared = ClotheslineController()

    private var panel: KeyablePanel?
    private var host: NSHostingView<AnyView>?
    private let state = ClotheslineState()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private weak var store: NoteStore?
    /// 挂绳当前所在的屏幕：跟着鼠标走（收起时鼠标进入哪块屏幕顶部，就搬到哪块）
    private var activeScreen: NSScreen?
    private var expiryTimer: Timer?
    /// 正在拖出挂绳的便签（系统拖拽进行中）
    private(set) var externalDragNoteID: UUID?

    /// 窗口左右离屏幕边缘的距离（不挡右侧贴边条）
    private let sideInset: CGFloat = 48
    /// 窗口高度随卡片大小变化
    private var panelHeight: CGFloat { ClotheslineView.panelHeight(for: AppSettings.shared.lineCardSize) }
    /// 收起时，菜单栏下方这么高的一条是热区
    private let hotZoneHeight: CGFloat = 6
    private let showDelay: TimeInterval = 0.22
    private let hideDelay: TimeInterval = 0.45

    private override init() { super.init() }

    func install(store: NoteStore) {
        guard panel == nil else { return }
        self.store = store
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = Self.collectionBehavior(fullScreen: AppSettings.shared.lineShowInFullScreen)
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true

        let root = ClotheslineView(
            state: state,
            onAdd: { [weak self] in self?.addBlankNote(store: store) },
            onTogglePin: { AppSettings.shared.setLinePinnedOpen(!AppSettings.shared.linePinnedOpen) }
        )
            .environmentObject(store)
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = []
        panel.contentView = host

        self.panel = panel
        self.host = host
        layout()

        AppSettings.shared.$clotheslineEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.apply(enabled: on) }
            .store(in: &cancellables)
        AppSettings.shared.$lineShowInFullScreen
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.panel?.collectionBehavior = Self.collectionBehavior(fullScreen: on) }
            .store(in: &cancellables)
        AppSettings.shared.$linePinnedOpen
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] pinned in
                guard let self else { return }
                if pinned { self.expand() } else { self.handleMouse() }
            }
            .store(in: &cancellables)
        AppSettings.shared.$lineCardSize
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.layout() } }
            .store(in: &cancellables)
        AppSettings.shared.$lineAutoRemoveDays
            .receive(on: RunLoop.main)
            .sink { [weak store] days in store?.expireLineNotes(afterDays: days) }
            .store(in: &cancellables)
        // 每小时检查一次「挂满 N 天自动取下」
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak store] _ in
            Task { @MainActor in store?.expireLineNotes(afterDays: AppSettings.shared.lineAutoRemoveDays) }
        }
        if AppSettings.shared.linePinnedOpen {
            DispatchQueue.main.async { [weak self] in self?.expand() }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParamsChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func toggleExpanded() {
        state.expanded ? collapse() : expand()
    }

    func expand() {
        guard let panel, AppSettings.shared.clotheslineEnabled else { return }
        hideWork?.cancel(); hideWork = nil
        showWork?.cancel(); showWork = nil
        guard !state.expanded else { return }
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) {
            state.expanded = true
        }
        updateClickThrough()
    }

    /// - Parameter force: 钉住时默认不收起；关闭挂绳等场景强制收起
    func collapse(force: Bool = false) {
        hideWork?.cancel(); hideWork = nil
        guard let panel, state.expanded else { return }
        if AppSettings.shared.linePinnedOpen && !force { return }
        panel.ignoresMouseEvents = true
        withAnimation(.easeIn(duration: 0.2)) {
            state.expanded = false
        }
    }

    // MARK: - Private

    private func apply(enabled: Bool) {
        guard let panel else { return }
        if enabled {
            layout()
            panel.orderFrontRegardless()
            startMouseMonitoring()
        } else {
            stopMouseMonitoring()
            collapse(force: true)
            state.expanded = false
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        }
    }

    private var screen: NSScreen? {
        if let activeScreen, NSScreen.screens.contains(activeScreen) { return activeScreen }
        return NSScreen.screens.first ?? NSScreen.main
    }

    private static func collectionBehavior(fullScreen: Bool) -> NSWindow.CollectionBehavior {
        fullScreen ? [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
                   : [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    /// 把剪贴板内容挂到绳上（文件只存引用，网址抓标题，图片存为附件，其它当文字），并短暂放下挂绳给个反馈
    func hangClipboard() {
        guard let store else { return }
        let pb = NSPasteboard.general
        let pos = store.nextLineSlot()
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            for (i, url) in files.enumerated() { store.hangURL(url, at: min(1, pos + Double(i) * 0.08)) }
        } else if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.hangText(text, at: pos)
        } else if let url = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first {
            store.hangURL(url, at: pos)
        } else if let image = (pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first,
                  let md = AttachmentStore.saveImage(image, preferredName: "line") {
            store.addLineNote(body: md, at: pos, color: .glass)
        } else {
            NSSound.beep()
            return
        }
        flash()
    }

    /// 放下挂绳给个反馈；没钉住、鼠标也不在绳附近时，过一会儿自己收回去
    func flash() {
        guard AppSettings.shared.clotheslineEnabled else { return }
        expand()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in self?.handleMouse() }
    }

    /// 剪贴板历史里的一条挂到绳上（文件只存引用）
    func hang(_ entry: ClipboardHistory.Entry) {
        guard let store else { return }
        switch entry.kind {
        case .text: store.hangText(entry.text ?? "")
        case .files:
            for (i, path) in (entry.files ?? []).enumerated() {
                store.hangURL(URL(fileURLWithPath: path), at: min(1, store.nextLineSlot() + Double(i) * 0.02))
            }
        case .image:
            if let url = ClipboardHistory.shared.imageURL(for: entry), let image = NSImage(contentsOf: url),
               let md = AttachmentStore.saveImage(image, preferredName: "line") {
                store.addLineNote(body: md, color: .glass)
            }
        }
    }

    private func layout() {
        guard let panel, let screen else { return }
        let v = screen.visibleFrame
        let frame = NSRect(
            x: v.minX + sideInset,
            y: v.maxY - panelHeight,
            width: max(320, v.width - sideInset * 2),
            height: panelHeight
        )
        panel.setFrame(frame, display: true)
    }

    private func addBlankNote(store: NoteStore) {
        let note = store.addLineNote(body: "")
        NoteWindowManager.shared.open(noteID: note.id, store: store, focusEditor: true)
    }

    private func startMouseMonitoring() {
        stopMouseMonitoring()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouse()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in self?.handleMouse() }
        }
    }

    private func stopMouseMonitoring() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        showWork?.cancel(); showWork = nil
        hideWork?.cancel(); hideWork = nil
    }

    private func handleMouse() {
        guard let panel, panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        // 多显示器：收起时鼠标到了另一块屏幕，把挂绳搬过去
        if !state.expanded, let s = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }), s != screen {
            activeScreen = s
            layout()
        }
        let frame = panel.frame
        if state.expanded {
            updateClickThrough()
            // 鼠标还在卡片/绳子附近、或正在拖东西过来时保持放下；移到空白处就收起
            let dragging = NSEvent.pressedMouseButtons != 0 && frame.contains(mouse)
            let near = interactiveRects().contains { $0.insetBy(dx: -28, dy: -28).contains(mouse) }
            if near || dragging || state.isDraggingCard || AppSettings.shared.linePinnedOpen {
                hideWork?.cancel(); hideWork = nil
            } else if hideWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.hideWork = nil
                    if !self.state.isDraggingCard { self.collapse() }
                }
                hideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: work)
            }
        } else {
            let hot = NSRect(x: frame.minX, y: frame.maxY - hotZoneHeight, width: frame.width, height: hotZoneHeight + 1)
            if hot.contains(mouse) {
                // 停留一小会儿才放下，避免去点菜单栏时路过就弹出
                guard showWork == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.showWork = nil
                    let now = NSEvent.mouseLocation
                    let f = self.panel?.frame ?? .zero
                    let stillHot = NSRect(x: f.minX, y: f.maxY - self.hotZoneHeight - 4, width: f.width, height: self.hotZoneHeight + 5)
                    if stillHot.contains(now) { self.expand() }
                }
                showWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
            } else {
                showWork?.cancel(); showWork = nil
            }
        }
    }

    /// 挂绳窗口铺满屏幕宽度，但只有卡片、绳子、＋ 按钮要拦截点击；其余空白处让点击穿透到下面的窗口。
    /// 拖着文件/文字过来时（按着鼠标键）整片都接收，方便放到绳上。
    private func updateClickThrough() {
        guard let panel else { return }
        // 自己的卡片正被拖向别的 App：整片放行，下面的输入框才能接住
        guard state.expanded, externalDragNoteID == nil else { panel.ignoresMouseEvents = true; return }
        let mouse = NSEvent.mouseLocation
        let dragging = NSEvent.pressedMouseButtons != 0 && panel.frame.contains(mouse)
        let over = interactiveRects().contains { $0.contains(mouse) }
        let ignore = !(over || dragging || state.isDraggingCard)
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    /// 可交互区域（屏幕坐标）：每张卡片、沿绳子的一串小矩形、右端 ＋ 按钮
    private func interactiveRects() -> [NSRect] {
        guard let panel else { return [] }
        let f = panel.frame
        // 视图坐标 y 朝下、原点在左上 → 屏幕坐标
        func toScreen(_ r: CGRect) -> NSRect {
            NSRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
        }
        var rects = state.cardRects.values.map { toScreen($0.insetBy(dx: -8, dy: -8)) }
        let x0 = Rope.endPadding, x1 = f.width - Rope.endPadding
        let segments = 24
        for i in 0..<segments {
            let ta = CGFloat(i) / CGFloat(segments), tb = CGFloat(i + 1) / CGFloat(segments)
            let ya = Rope.y(at: ta, anchor: Rope.expandedAnchor, sag: Rope.expandedSag)
            let yb = Rope.y(at: tb, anchor: Rope.expandedAnchor, sag: Rope.expandedSag)
            let xa = x0 + (x1 - x0) * ta, xb = x0 + (x1 - x0) * tb
            rects.append(toScreen(CGRect(x: xa - 12, y: min(ya, yb) - 12, width: xb - xa + 24, height: abs(yb - ya) + 24)))
        }
        rects.append(toScreen(CGRect(x: f.width - Rope.endPadding - 14, y: Rope.expandedAnchor - 16, width: 40, height: 36)))
        rects.append(toScreen(CGRect(x: Rope.endPadding - 24, y: Rope.expandedAnchor - 16, width: 40, height: 36)))
        return rects
    }

    @objc private func screenParamsChanged() { layout() }

    // MARK: - 拖出挂绳

    /// 拖动卡片 = 系统拖拽，只用来把内容放进其它 App 的输入框；卡片始终留在绳上。
    func beginExternalDrag(of note: Note, privacy: Bool) {
        guard externalDragNoteID == nil, let host, let event = NSApp.currentEvent,
              event.type == .leftMouseDragged || event.type == .leftMouseDown else { return }
        let image = cardImage(note, privacy: privacy)
        let file = note.fileLink != nil ? store?.resolveFile(for: note.id) : nil
        let item = NSDraggingItem(pasteboardWriter: Self.pasteboardItem(for: note, file: file))
        let p = host.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(x: p.x - image.size.width / 2, y: p.y - image.size.height / 2, width: image.size.width, height: image.size.height),
            contents: image
        )
        externalDragNoteID = note.id
        state.isDraggingCard = true
        let session = host.beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        // 收起挂绳并放行鼠标，下面的输入框才能接住
        DispatchQueue.main.async { [weak self] in self?.collapse() }
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated {
            externalDragNoteID = nil
            state.isDraggingCard = false
        }
    }

    private func cardImage(_ note: Note, privacy: Bool) -> NSImage {
        let view = ClotheslineCard(note: note, privacy: privacy, tilt: 0, isDragging: false)
            .padding(14)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage ?? NSImage(size: NSSize(width: 120, height: 100))
    }

    /// 拖出去的内容：文件给原文件，链接给网址，图片给文件和图像数据，其它给纯文本
    private static func pasteboardItem(for note: Note, file: URL?) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if let file {
            item.setString(file.absoluteString, forType: .fileURL)
            item.setString(file.path, forType: .string)
        } else if let url = note.webLink {
            item.setString(url.absoluteString, forType: .URL)
            item.setString(url.absoluteString, forType: .string)
        } else if note.isImageOnly, let path = note.attachmentPaths.first,
                  let file = AttachmentStore.absoluteURL(forMarkdownPath: path) {
            item.setString(file.absoluteString, forType: .fileURL)
            if let image = NSImage(contentsOf: file), let tiff = image.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
                if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    item.setData(png, forType: .png)
                }
            }
        } else {
            let body = Note.imageRegex.stringByReplacingMatches(
                in: note.body, range: NSRange(location: 0, length: (note.body as NSString).length), withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
            item.setString(title.isEmpty ? body : (body.isEmpty ? title : title + "\n" + body), forType: .string)
        }
        return item
    }
}

@MainActor
final class ClotheslineState: ObservableObject {
    @Published var expanded = false
    @Published var isDraggingCard = false
    /// 各卡片在挂绳视图里的位置（y 朝下），用来决定哪里拦截点击；不需要触发重绘
    var cardRects: [UUID: CGRect] = [:]
    /// 鼠标所在的卡片：叠放时提到最前并恢复原大小
    @Published var hoveredID: UUID?
}

/// 把卡片摆上绳：按各自位置排，互不重叠；放不下先整体缩小，缩到下限后叠放（悬停的那张会提到最前）。
enum RopeLayout {
    struct Item {
        var id: UUID
        var position: CGFloat
        /// 卡片宽度（未缩放）
        var width: CGFloat = RopeLayout.cardWidth
    }

    struct Result: Equatable {
        var centers: [UUID: CGFloat]
        var scale: CGFloat
    }

    static let cardWidth: CGFloat = 140
    static let minScale: CGFloat = 0.72

    /// lo/hi：位置 0…1 映射到的中心范围；edges：卡片外沿（按实际宽度）不能越过的左右边界
    static func layout(_ items: [Item], lo: CGFloat, hi: CGFloat, edges: ClosedRange<CGFloat>? = nil) -> Result {
        let n = items.count
        guard n > 0, hi > lo else { return Result(centers: [:], scale: 1) }
        let span = hi - lo
        let sorted = items.sorted { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }
        guard n > 1 else {
            let item = sorted[0]
            var x = lo + span * min(1, max(0, item.position))
            if let edges { x = min(max(x, edges.lowerBound + item.width / 2), edges.upperBound - item.width / 2) }
            return Result(centers: [item.id: x], scale: 1)
        }

        // 相邻两张卡中心的最小距离 = 两者半宽之和
        let baseGaps = (0..<(n - 1)).map { (sorted[$0].width + sorted[$0 + 1].width) / 2 }
        let total = baseGaps.reduce(0, +)
        let scale = min(1, max(minScale, span / total))
        // 缩到下限仍放不下：按比例压缩间距，卡片叠在一起
        let squeeze = min(1, span / (total * scale))
        let gaps = baseGaps.map { $0 * scale * squeeze }

        // 两端的卡按实际半宽收进边界（剪贴板这类宽卡尤其需要）
        let first = max(lo, (edges?.lowerBound ?? -.infinity) + sorted[0].width * scale / 2)
        let last = min(hi, (edges?.upperBound ?? .infinity) - sorted[n - 1].width * scale / 2)
        var xs = sorted.map { lo + span * min(1, max(0, $0.position)) }
        xs[0] = max(xs[0], first)
        for i in 1..<n { xs[i] = max(xs[i], xs[i - 1] + gaps[i - 1]) }
        if xs[n - 1] > last {
            xs[n - 1] = last
            for i in stride(from: n - 2, through: 0, by: -1) { xs[i] = min(xs[i], xs[i + 1] - gaps[i]) }
        }
        if xs[0] < first - 0.5 {
            // 压缩后仍放不下：从左端起等距叠放，并把间距压到刚好收进右端
            let need = gaps.reduce(0, +)
            let k = need > 0 ? min(1, max(0, last - first) / need) : 1
            xs[0] = first
            for i in 1..<n { xs[i] = xs[i - 1] + gaps[i - 1] * k }
        }
        var centers: [UUID: CGFloat] = [:]
        for (i, item) in sorted.enumerated() { centers[item.id] = xs[i] }
        return Result(centers: centers, scale: scale)
    }
}

// MARK: - Views

private enum Rope {
    static let collapsedAnchor: CGFloat = 2
    static let expandedAnchor: CGFloat = 14
    static let collapsedSag: CGFloat = 1.5
    static let expandedSag: CGFloat = 26
    static let endPadding: CGFloat = 26

    static func y(at t: CGFloat, anchor: CGFloat, sag: CGFloat) -> CGFloat {
        anchor + sag * 4 * t * (1 - t)
    }
}

/// 下垂的绳子（抛物线），锚点与下垂量可动画
private struct RopeShape: Shape {
    var anchor: CGFloat
    var sag: CGFloat
    var padding: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(anchor, sag) }
        set { anchor = newValue.first; sag = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let x0 = rect.minX + padding, x1 = rect.maxX - padding
        p.move(to: CGPoint(x: x0, y: anchor))
        // 二次贝塞尔控制点取 2×sag，曲线中点下垂量正好是 sag
        p.addQuadCurve(to: CGPoint(x: x1, y: anchor), control: CGPoint(x: (x0 + x1) / 2, y: anchor + sag * 2))
        return p
    }
}

struct ClotheslineView: View {
    @ObservedObject var state: ClotheslineState
    var onAdd: () -> Void
    var onTogglePin: () -> Void
    @EnvironmentObject private var store: NoteStore
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var clipboard = ClipboardHistory.shared
    @State private var dropTargeted = false
    /// 正在沿绳子左右拖的卡片的临时位置
    @State private var dragPositions: [UUID: CGFloat] = [:]
    /// 上下拖超过这个距离才算「拖出来」，交给系统拖拽
    private static let pullOutThreshold: CGFloat = 70
    /// 本次拖动是否已转交系统拖拽（手势结束自动复位）
    @GestureState private var handedOff = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let shown = store.lineNotes
            let k = settings.lineCardSize.scale
            let showClipboard = settings.clipboardHistoryEnabled
            let layout = RopeLayout.layout(
                shown.filter { dragPositions[$0.id] == nil }.map { RopeLayout.Item(id: $0.id, position: CGFloat($0.linePosition ?? 0.5), width: RopeLayout.cardWidth * k) }
                    + (showClipboard ? [RopeLayout.Item(id: ClipboardHistory.cardID, position: 1, width: (ClipboardCard.size.width + 16) * k)] : []),
                lo: Self.cardLo, hi: width - Self.cardLo,
                // 左端留给钉住按钮，右端留给 ＋
                edges: (Rope.endPadding + 14)...(width - Rope.endPadding - 22)
            )
            let anchor = state.expanded ? Rope.expandedAnchor : Rope.collapsedAnchor
            let sag = state.expanded ? Rope.expandedSag : Rope.collapsedSag
            ZStack(alignment: .topLeading) {
                // 拖放目标：整片区域（只有按着鼠标拖东西过来时窗口才接收鼠标，平时点击会穿透）
                Color.clear.contentShape(Rectangle())

                RopeShape(anchor: anchor, sag: sag, padding: Rope.endPadding)
                    .stroke(
                        LinearGradient(
                            colors: [Color(red: 0.62, green: 0.50, blue: 0.36), Color(red: 0.48, green: 0.38, blue: 0.27)],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: state.expanded ? 2.4 : 2, lineCap: .round)
                    )
                    .shadow(color: .black.opacity(state.expanded ? 0.25 : 0.12), radius: 1.5, y: 1)
                    .opacity(dropTargeted ? 1 : (state.expanded ? 0.95 : 0.55))

                if state.expanded {
                    hooks(width: width, anchor: anchor)
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, note in
                        card(note, index: index, layout: layout, width: width, anchor: anchor, sag: sag)
                    }
                    if showClipboard {
                        clipboardCard(layout: layout, width: width, anchor: anchor, sag: sag)
                    }
                    if shown.isEmpty {
                        Text(L("把图片、文字或文件拖到绳上，或点右侧 ＋ 新建"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(.regularMaterial))
                            .position(x: showClipboard ? width * 0.4 : width / 2, y: Rope.y(at: 0.5, anchor: anchor, sag: sag) + 34)
                            .transition(.opacity)
                    }
                }
            }
            .coordinateSpace(name: "clothesline")
            .onPreferenceChange(CardFrameKey.self) { frames in
                MainActor.assumeIsolated { state.cardRects = frames }
            }
            .onChange(of: state.expanded) { _, expanded in
                if !expanded { state.cardRects = [:] }
            }
            .onDrop(of: [.fileURL, .image, .url, .plainText], isTargeted: $dropTargeted) { providers, location in
                // 自己的卡片拖回绳上不新建
                guard ClotheslineController.shared.externalDragNoteID == nil else { return false }
                return handleDrop(providers, at: position(forX: location.x, width: width))
            }
        }
    }

    // MARK: Pieces

    /// 两端的小钩子 + 右端的 ＋
    private func hooks(width: CGFloat, anchor: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // 左端：钉住（一直放下）
            Button(action: onTogglePin) {
                Image(systemName: settings.linePinnedOpen ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(settings.linePinnedOpen ? Color.orange : Color.primary.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.regularMaterial))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help(settings.linePinnedOpen ? L("取消钉住（鼠标离开后自动收起）") : L("钉住挂绳（一直放下）"))
            .position(x: Rope.endPadding - 6, y: anchor + 2)
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.regularMaterial))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help(L("新建一张挂在绳上的便签"))
            .position(x: width - Rope.endPadding + 6, y: anchor + 2)
        }
        .transition(.opacity)
    }

    private func card(_ note: Note, index: Int, layout: RopeLayout.Result, width: CGFloat, anchor: CGFloat, sag: CGFloat) -> some View {
        let dragging = dragPositions[note.id] != nil
        let x = dragging ? xFor(position: dragPositions[note.id]!, width: width)
                         : (layout.centers[note.id] ?? xFor(position: CGFloat(note.linePosition ?? 0.5), width: width))
        let t = width > 2 * Rope.endPadding ? (x - Rope.endPadding) / (width - 2 * Rope.endPadding) : 0.5
        let ropeY = Rope.y(at: min(1, max(0, t)), anchor: anchor, sag: sag)
        let hovered = state.hoveredID == note.id
        let scale = settings.lineCardSize.scale * (dragging || hovered ? 1 : layout.scale)
        return ClotheslineCard(
            note: note,
            privacy: settings.privacyHideBodies,
            tilt: tilt(for: note.id),
            isDragging: dragging,
            onUnpin: { withAnimation(.easeOut(duration: 0.2)) { store.takeOffLine(id: note.id) } },
            onHoverChange: { inside in
                if inside { state.hoveredID = note.id }
                else if state.hoveredID == note.id { state.hoveredID = nil }
            }
        )
        .fixedSize()
        .background(GeometryReader { g in
            Color.clear.preference(key: CardFrameKey.self, value: [note.id: Self.scaled(g.frame(in: .named("clothesline")), by: scale)])
        })
        .scaleEffect(scale, anchor: .top)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: scale)
        .task(id: note.fileLink) {
            // 文件被移动/改名时按书签更新地址
            if note.fileLink != nil { _ = store.resolveFile(for: note.id) }
        }
        .gesture(
            // 左右拖：沿绳子换位置；上下拖超过阈值：拖出来放进其它 App 的输入框
            DragGesture(minimumDistance: 4, coordinateSpace: .named("clothesline"))
                .updating($handedOff) { value, handed, _ in
                    guard !handed else { return }
                    if abs(value.translation.height) > Self.pullOutThreshold {
                        handed = true
                        dragPositions[note.id] = nil
                        ClotheslineController.shared.beginExternalDrag(of: note, privacy: settings.privacyHideBodies)
                    } else {
                        state.isDraggingCard = true
                        dragPositions[note.id] = position(forX: value.location.x, width: width)
                    }
                }
                .onEnded { _ in
                    guard let t = dragPositions.removeValue(forKey: note.id) else { return }
                    state.isDraggingCard = false
                    store.setLinePosition(id: note.id, Double(t))
                }
        )
        .onTapGesture { open(note) }
        .contextMenu { menu(for: note) }
        // 固定高的顶对齐框：卡片顶端（夹子）正好压在绳子上
        .frame(width: Self.slotSize.width * 1.7, height: Self.slotSize.height * 1.7, alignment: .top)
        .position(x: x, y: ropeY - 6 + Self.slotSize.height * 1.7 / 2)
        .zIndex(dragging ? 100 : (hovered ? 50 : Double(index)))
        .transition(.asymmetric(
            insertion: .offset(y: -80).combined(with: .opacity),
            removal: .offset(y: -60).combined(with: .opacity)
        ))
    }

    private static let slotSize = CGSize(width: 170, height: 215)

    /// 窗口高度：绳子 + 最高的卡片
    static func panelHeight(for size: LineCardSize) -> CGFloat {
        Rope.expandedAnchor + Rope.expandedSag + 6 + max(slotSize.height, ClipboardCard.size.height + 16) * size.scale
    }

    /// scaleEffect(anchor: .top) 之后的实际占位
    static func scaled(_ r: CGRect, by s: CGFloat) -> CGRect {
        CGRect(x: r.midX - r.width * s / 2, y: r.minY, width: r.width * s, height: r.height * s)
    }

    private func clipboardCard(layout: RopeLayout.Result, width: CGFloat, anchor: CGFloat, sag: CGFloat) -> some View {
        let x = layout.centers[ClipboardHistory.cardID] ?? width - Self.cardLo
        let t = width > 2 * Rope.endPadding ? (x - Rope.endPadding) / (width - 2 * Rope.endPadding) : 0.5
        let ropeY = Rope.y(at: min(1, max(0, t)), anchor: anchor, sag: sag)
        let hovered = state.hoveredID == ClipboardHistory.cardID
        let scale = settings.lineCardSize.scale * (hovered ? 1 : layout.scale)
        let box = CGSize(width: ClipboardCard.size.width + 16, height: ClipboardCard.size.height + 16)
        return ClipboardCard(history: clipboard, privacy: settings.privacyHideBodies)
            .fixedSize()
            .background(GeometryReader { g in
                Color.clear.preference(key: CardFrameKey.self, value: [ClipboardHistory.cardID: Self.scaled(g.frame(in: .named("clothesline")), by: scale)])
            })
            .onHover { inside in
                if inside { state.hoveredID = ClipboardHistory.cardID }
                else if state.hoveredID == ClipboardHistory.cardID { state.hoveredID = nil }
            }
            .scaleEffect(scale, anchor: .top)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: scale)
            .frame(width: box.width * 1.7, height: box.height * 1.7, alignment: .top)
            .position(x: x, y: ropeY - 6 + box.height * 1.7 / 2)
            .zIndex(hovered ? 50 : 40)
            .transition(.asymmetric(
                insertion: .offset(y: -80).combined(with: .opacity),
                removal: .offset(y: -60).combined(with: .opacity)
            ))
    }
    /// 卡片中心离窗口两端的最小距离
    private static let cardLo: CGFloat = Rope.endPadding + 70

    @ViewBuilder
    private func menu(for note: Note) -> some View {
        if note.fileLink != nil {
            Button(L("打开")) { open(note) }
            Button(L("在 Finder 中显示")) {
                if let url = store.resolveFile(for: note.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                else { NSSound.beep() }
            }
            Button(L("复制路径")) {
                if let url = store.resolveFile(for: note.id) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
            }
        } else if note.isImageOnly {
            Button(L("查看大图")) { open(note) }
        } else if let url = note.webLink {
            Button(L("打开网页")) { open(note) }
            Button(L("复制链接")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Button(L("编辑便签")) { NoteWindowManager.shared.open(noteID: note.id, store: store, focusEditor: true) }
        } else {
            Button(L("编辑")) { open(note) }
        }
        if note.isImageOnly, let path = note.attachmentPaths.first, let url = AttachmentStore.absoluteURL(forMarkdownPath: path) {
            Button(L("用「预览」打开")) { NSWorkspace.shared.open(url) }
            Button(L("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } else if note.fileLink == nil {
            Menu(L("颜色")) {
                ForEach(NoteColor.palette) { c in
                    Button(c.label) { store.setColor(id: note.id, c) }
                }
            }
        }
        Divider()
        Button(L("从挂绳取下")) { withAnimation { store.takeOffLine(id: note.id) } }
        Button(L("删除"), role: .destructive) { withAnimation { store.softDelete(id: note.id) } }
    }

    // MARK: Geometry

    private func xFor(position t: CGFloat, width: CGFloat) -> CGFloat {
        let lo = Rope.endPadding + 70, hi = width - Rope.endPadding - 70
        return lo + (hi - lo) * t
    }

    private func position(forX x: CGFloat, width: CGFloat) -> CGFloat {
        let lo = Rope.endPadding + 70, hi = width - Rope.endPadding - 70
        guard hi > lo else { return 0.5 }
        return min(1, max(0, (x - lo) / (hi - lo)))
    }

    /// 每张卡固定的小角度，看起来像随手夹上去的
    private func tilt(for id: UUID) -> Double {
        let v = id.uuid
        let seed = Int(v.0) ^ Int(v.5) ^ Int(v.11)
        return Double(seed % 9) - 4
    }

    // MARK: Actions

    /// 单击：链接打开网页，图片看大图，文字进入编辑
    private func open(_ note: Note) {
        if note.fileLink != nil {
            guard let url = store.resolveFile(for: note.id) else { NSSound.beep(); return }
            ClotheslineController.shared.collapse()
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                ImageViewer.shared.show(url)
            } else {
                NSWorkspace.shared.open(url)
            }
        } else if let url = note.webLink {
            NSWorkspace.shared.open(url)
            ClotheslineController.shared.collapse()
        } else if note.isImageOnly, let path = note.attachmentPaths.first,
                  let url = AttachmentStore.absoluteURL(forMarkdownPath: path) {
            ClotheslineController.shared.collapse()
            ImageViewer.shared.show(url)
        } else {
            ClotheslineController.shared.collapse()
            NoteWindowManager.shared.open(noteID: note.id, store: store, focusEditor: true)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], at position: CGFloat) -> Bool {
        var handled = false
        for (i, provider) in providers.enumerated() {
            // 一次拖多个时沿绳子错开
            let pos = Double(min(1, position + CGFloat(i) * 0.08))
            if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in store.hangURL(url, at: pos) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    Task { @MainActor in
                        if let md = AttachmentStore.saveImage(image, preferredName: "line") {
                            store.addLineNote(body: md, at: pos, color: .glass)
                        }
                    }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    Task { @MainActor in store.hangText(text, at: pos) }
                }
            }
        }
        return handled
    }

}

struct ClotheslineCard: View {
    let note: Note
    let privacy: Bool
    let tilt: Double
    let isDragging: Bool
    /// 点夹子取下；拖拽预览图里为 nil
    var onUnpin: (() -> Void)? = nil
    var onHoverChange: ((Bool) -> Void)? = nil
    @State private var hovering = false
    @State private var pinHovering = false

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if let url = note.fileLink {
                    FileCardBody(url: url, privacy: privacy)
                } else if note.isImageOnly, let path = note.attachmentPaths.first {
                    photo(path)
                } else if let url = note.webLink {
                    link(url)
                } else {
                    paper
                }
            }
            .padding(.top, 8)

            Clothespin(highlighted: pinHovering)
                .frame(width: 22, height: 30)
                .contentShape(Rectangle())
                .onHover { pinHovering = $0 && onUnpin != nil }
                .onTapGesture { onUnpin?() }
                .help(L("点夹子取下"))
                .offset(y: -7)
        }
        .rotationEffect(.degrees(hovering || isDragging ? 0 : tilt), anchor: .top)
        .scaleEffect(hovering || isDragging ? 1.06 : 1, anchor: .top)
        .shadow(color: .black.opacity(hovering ? 0.28 : 0.18), radius: hovering ? 8 : 4, y: hovering ? 5 : 3)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: hovering)
        .onHover { hovering = $0; onHoverChange?($0) }
        .help(note.fileLink?.path ?? note.displayTitle)
    }

    private func photo(_ path: String) -> some View {
        let image = ThumbnailCache.image(for: path)
        let size = photoSize(image)
        return VStack(spacing: 0) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").font(.system(size: 26)).foregroundStyle(.secondary)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            Color.clear.frame(height: 14)
        }
        .padding([.top, .horizontal], 6)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.98)))
        .blur(radius: privacy ? 8 : 0)
    }

    private func photoSize(_ image: NSImage?) -> CGSize {
        guard let image, image.size.width > 0, image.size.height > 0 else { return CGSize(width: 120, height: 90) }
        let w: CGFloat = 124
        let h = min(160, max(70, w * image.size.height / image.size.width))
        return CGSize(width: w, height: h)
    }

    private func link(_ url: URL) -> some View {
        let host = url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url.absoluteString
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                FaviconView(host: url.host ?? "")
                Text(host)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.black.opacity(0.55))
                    .lineLimit(1)
            }
            Text(note.displayTitle)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.black.opacity(0.85))
                .lineLimit(4)
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.right.square")
                Text(L("点击打开"))
            }
            .font(.system(size: 9))
            .foregroundStyle(note.color.accent)
        }
        .padding(.horizontal, 9)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(width: 128, height: 112, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 4).fill(note.color.normalized == .glass ? Color.white : note.color.fill))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.06)))
        .help(url.absoluteString)
    }

    private var paper: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if note.isLocked { Image(systemName: "lock.fill").font(.system(size: 8)) }
                if note.reminderAt != nil { Image(systemName: "bell.fill").font(.system(size: 8)) }
                Text(note.displayTitle)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(2)
            }
            if privacy || note.isLocked {
                Text("•••").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text(previewText)
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.75))
                    .lineLimit(5)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(note.color.normalized == .glass ? Color.primary : Color.black.opacity(0.82))
        .padding(.horizontal, 9)
        .padding(.top, 12)
        .padding(.bottom, 9)
        .frame(width: 128, alignment: .leading)
        .frame(minHeight: 96, maxHeight: 150, alignment: .top)
        .background {
            if note.color.normalized == .glass {
                RoundedRectangle(cornerRadius: 4).fill(.regularMaterial)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(note.color.fill)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.06)))
    }

    private var previewText: String {
        var body = note.body
        body = Note.imageRegex.stringByReplacingMatches(
            in: body, range: NSRange(location: 0, length: (body as NSString).length), withTemplate: L("[图片]")
        )
        // 标题取自首行时，预览从第二行开始
        if note.title.trimmingCharacters(in: .whitespaces).isEmpty {
            body = body.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().joined(separator: "\n")
        }
        // 待办行显示成勾选框
        body = body.components(separatedBy: "\n").map { line in
            guard let item = Checklist.parse(line) else { return line }
            return (item.done ? "☑ " : "☐ ") + item.text
        }.joined(separator: "\n")
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct CardFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 网站图标：取站点根目录的 favicon.ico，失败显示地球
private struct FaviconView: View {
    let host: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "globe").resizable().foregroundStyle(.black.opacity(0.45))
            }
        }
        .frame(width: 14, height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .task(id: host) { image = await FaviconCache.image(for: host) }
    }
}

@MainActor
enum FaviconCache {
    private static var cache: [String: NSImage] = [:]
    private static var failed: Set<String> = []

    static func image(for host: String) async -> NSImage? {
        guard !host.isEmpty else { return nil }
        if let hit = cache[host] { return hit }
        if failed.contains(host) { return nil }
        guard let url = URL(string: "https://\(host)/favicon.ico"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data), image.isValid else {
            failed.insert(host)
            return nil
        }
        cache[host] = image
        return image
    }
}

/// 文件卡片：图片文件显示成照片，其它文件显示缩略图/图标 + 文件名；文件不在了给出提示
private struct FileCardBody: View {
    let url: URL
    let privacy: Bool
    @State private var thumb: NSImage?

    private var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    private var isImage: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true }

    var body: some View {
        Group {
            if isImage && exists {
                photo
            } else {
                document
            }
        }
        .task(id: url) { thumb = await FileThumbnailCache.thumbnail(for: url) }
    }

    private var photo: some View {
        let size: CGSize = {
            guard let thumb, thumb.size.width > 0 else { return CGSize(width: 124, height: 90) }
            return CGSize(width: 124, height: min(160, max(70, 124 * thumb.size.height / thumb.size.width)))
        }()
        return VStack(spacing: 0) {
            Group {
                if let thumb { Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill) }
                else { ProgressView().controlSize(.small) }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            Text(url.lastPathComponent)
                .font(.system(size: 8.5))
                .foregroundStyle(.black.opacity(0.5))
                .lineLimit(1)
                .frame(width: size.width, height: 16)
        }
        .padding([.top, .horizontal], 6)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.98)))
        .blur(radius: privacy ? 8 : 0)
    }

    private var document: some View {
        VStack(spacing: 6) {
            Group {
                if exists, let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else if exists {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "questionmark.folder").font(.system(size: 34)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            Text(url.lastPathComponent)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.black.opacity(0.82))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(exists ? detail : L("文件已移动或删除"))
                .font(.system(size: 9))
                .foregroundStyle(exists ? Color.black.opacity(0.45) : Color.red.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .padding(.bottom, 9)
        .frame(width: 128)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.06)))
    }

    private var detail: String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { return L("文件夹") }
        let size = ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? size : "\(ext) · \(size)"
    }
}

/// 文件缩略图（Quick Look），内存缓存
@MainActor
enum FileThumbnailCache {
    private static var cache: [URL: NSImage] = [:]

    static func thumbnail(for url: URL) async -> NSImage? {
        if let hit = cache[url] { return hit }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 260, height: 260),
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .all
        )
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        cache[url] = image
        return image
    }
}

/// 木夹子
struct Clothespin: View {
    var highlighted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(LinearGradient(
                    colors: [Color(red: 0.86, green: 0.70, blue: 0.48), Color(red: 0.72, green: 0.55, blue: 0.34)],
                    startPoint: .leading, endPoint: .trailing
                ))
                .frame(width: 9, height: 24)
                .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(Color.red.opacity(highlighted ? 0.8 : 0), lineWidth: 1.5))
            Rectangle()
                .fill(Color.black.opacity(0.18))
                .frame(width: 9, height: 1)
                .offset(y: -3)
            Circle()
                .fill(Color(white: 0.55))
                .frame(width: 4, height: 4)
                .offset(y: -3)
        }
        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
        .scaleEffect(highlighted ? 1.18 : 1)
        .animation(.easeOut(duration: 0.12), value: highlighted)
    }
}

/// 看大图：浮动窗口，按 Esc / 点关闭 / 点图片关闭
@MainActor
final class ImageViewer: NSObject, NSWindowDelegate {
    static let shared = ImageViewer()
    private var panel: NSPanel?

    func show(_ url: URL) {
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else {
            NSWorkspace.shared.open(url)
            return
        }
        panel?.close()
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let scale = min(1, visible.width * 0.8 / image.size.width, visible.height * 0.8 / image.size.height)
        let size = NSSize(width: max(240, image.size.width * scale), height: max(160, image.size.height * scale))

        let panel = ImageViewerPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = url.lastPathComponent
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .black
        panel.contentAspectRatio = size
        panel.delegate = self
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        panel.contentView = view
        panel.center()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}

private final class ImageViewerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    private var downAt: NSPoint?
    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation
        super.mouseDown(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        // 单击关闭；拖动窗口后松手不关
        let now = NSEvent.mouseLocation
        if let downAt, hypot(now.x - downAt.x, now.y - downAt.y) < 4 { close() }
        else { super.mouseUp(with: event) }
        downAt = nil
    }
}

/// 挂绳上的图片缩略图缓存，避免每次重绘都从磁盘解码原图
@MainActor
enum ThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for markdownPath: String) -> NSImage? {
        if let hit = cache.object(forKey: markdownPath as NSString) { return hit }
        guard let url = AttachmentStore.absoluteURL(forMarkdownPath: markdownPath),
              let image = NSImage(contentsOf: url) else { return nil }
        let thumb = NoteBodyRendering.scale(image, maxWidth: 260)
        cache.setObject(thumb, forKey: markdownPath as NSString)
        return thumb
    }
}
