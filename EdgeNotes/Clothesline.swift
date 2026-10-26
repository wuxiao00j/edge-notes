import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

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
    /// 正在拖出挂绳的便签（系统拖拽进行中）
    private(set) var externalDragNoteID: UUID?

    /// 窗口左右离屏幕边缘的距离（不挡右侧贴边条）
    private let sideInset: CGFloat = 48
    private let panelHeight: CGFloat = 250
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
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true

        let root = ClotheslineView(state: state, onAdd: { [weak self] in self?.addBlankNote(store: store) })
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
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) {
            state.expanded = true
        }
    }

    func collapse() {
        hideWork?.cancel(); hideWork = nil
        guard let panel, state.expanded else { return }
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
            state.expanded = false
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        }
    }

    /// 菜单栏所在屏幕
    private var screen: NSScreen? { NSScreen.screens.first ?? NSScreen.main }

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
        let frame = panel.frame
        if state.expanded {
            if frame.insetBy(dx: -4, dy: -4).contains(mouse) || state.isDraggingCard {
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

    @objc private func screenParamsChanged() { layout() }

    // MARK: - 拖出挂绳

    /// 拖动卡片 = 系统拖拽，只用来把内容放进其它 App 的输入框；卡片始终留在绳上。
    func beginExternalDrag(of note: Note, privacy: Bool) {
        guard externalDragNoteID == nil, let host, let event = NSApp.currentEvent,
              event.type == .leftMouseDragged || event.type == .leftMouseDown else { return }
        let image = cardImage(note, privacy: privacy)
        let item = NSDraggingItem(pasteboardWriter: Self.pasteboardItem(for: note))
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

    /// 拖出去的内容：链接给网址，图片给文件和图像数据，其它给纯文本
    private static func pasteboardItem(for note: Note) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if let url = note.webLink {
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
    @EnvironmentObject private var store: NoteStore
    @ObservedObject private var settings = AppSettings.shared
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
            let anchor = state.expanded ? Rope.expandedAnchor : Rope.collapsedAnchor
            let sag = state.expanded ? Rope.expandedSag : Rope.collapsedSag
            ZStack(alignment: .topLeading) {
                // 展开时整片区域可接收拖放；收起时完全透明
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
                        card(note, index: index, width: width, anchor: anchor, sag: sag)
                    }
                    if shown.isEmpty {
                        Text("把图片、文字或文件拖到绳上，或点右侧 ＋ 新建")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(.regularMaterial))
                            .position(x: width / 2, y: Rope.y(at: 0.5, anchor: anchor, sag: sag) + 34)
                            .transition(.opacity)
                    }
                }
            }
            .coordinateSpace(name: "clothesline")
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
            Circle()
                .strokeBorder(Color(red: 0.45, green: 0.36, blue: 0.26), lineWidth: 2)
                .frame(width: 10, height: 10)
                .position(x: Rope.endPadding - 4, y: anchor)
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.regularMaterial))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("新建一张挂在绳上的便签")
            .position(x: width - Rope.endPadding + 6, y: anchor + 2)
        }
        .transition(.opacity)
    }

    private func card(_ note: Note, index: Int, width: CGFloat, anchor: CGFloat, sag: CGFloat) -> some View {
        let t = dragPositions[note.id] ?? CGFloat(note.linePosition ?? 0.5)
        let x = xFor(position: t, width: width)
        let ropeY = Rope.y(at: t, anchor: anchor, sag: sag)
        return ClotheslineCard(
            note: note,
            privacy: settings.privacyHideBodies,
            tilt: tilt(for: note.id),
            isDragging: dragPositions[note.id] != nil,
            onUnpin: { withAnimation(.easeOut(duration: 0.2)) { store.takeOffLine(id: note.id) } }
        )
        .fixedSize()
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
        .frame(width: Self.slotSize.width, height: Self.slotSize.height, alignment: .top)
        .position(x: x, y: ropeY - 6 + Self.slotSize.height / 2)
        .zIndex(dragPositions[note.id] != nil ? 100 : Double(index))
        .transition(.asymmetric(
            insertion: .offset(y: -80).combined(with: .opacity),
            removal: .offset(y: -60).combined(with: .opacity)
        ))
    }

    private static let slotSize = CGSize(width: 170, height: 215)

    @ViewBuilder
    private func menu(for note: Note) -> some View {
        if note.isImageOnly {
            Button("查看大图") { open(note) }
        } else if let url = note.webLink {
            Button("打开网页") { open(note) }
            Button("复制链接") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Button("编辑便签") { NoteWindowManager.shared.open(noteID: note.id, store: store, focusEditor: true) }
        } else {
            Button("编辑") { open(note) }
        }
        if note.isImageOnly, let path = note.attachmentPaths.first, let url = AttachmentStore.absoluteURL(forMarkdownPath: path) {
            Button("用「预览」打开") { NSWorkspace.shared.open(url) }
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } else {
            Menu("颜色") {
                ForEach(NoteColor.palette) { c in
                    Button(c.label) { store.setColor(id: note.id, c) }
                }
            }
        }
        Divider()
        Button("从挂绳取下") { withAnimation { store.takeOffLine(id: note.id) } }
        Button("删除", role: .destructive) { withAnimation { store.softDelete(id: note.id) } }
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
        if let url = note.webLink {
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
                    Task { @MainActor in hang(url: url, at: pos) }
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
                    Task { @MainActor in
                        // 拖的是一段纯网址文本，也按链接处理
                        let probe = Note(body: text)
                        if let url = probe.webLink { store.addLineLink(url, at: pos) }
                        else { store.addLineNote(body: text, at: pos) }
                    }
                }
            }
        }
        return handled
    }

    private func hang(url: URL, at pos: Double) {
        if url.isFileURL {
            let type = UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .image) == true, let md = AttachmentStore.saveImageFile(from: url) {
                store.addLineNote(body: md, at: pos, color: .glass)
            } else {
                // 非图片文件：挂一张带链接的便签，点链接即可打开
                store.addLineNote(body: "**\(url.lastPathComponent)**\n\(url.absoluteString)", at: pos)
            }
        } else if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            store.addLineLink(url, at: pos)
        } else {
            store.addLineNote(body: url.absoluteString, at: pos)
        }
    }
}

struct ClotheslineCard: View {
    let note: Note
    let privacy: Bool
    let tilt: Double
    let isDragging: Bool
    /// 点夹子取下；拖拽预览图里为 nil
    var onUnpin: (() -> Void)? = nil
    @State private var hovering = false
    @State private var pinHovering = false

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if note.isImageOnly, let path = note.attachmentPaths.first {
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
                .help("点夹子取下")
                .offset(y: -7)
        }
        .rotationEffect(.degrees(hovering || isDragging ? 0 : tilt), anchor: .top)
        .scaleEffect(hovering || isDragging ? 1.06 : 1, anchor: .top)
        .shadow(color: .black.opacity(hovering ? 0.28 : 0.18), radius: hovering ? 8 : 4, y: hovering ? 5 : 3)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: hovering)
        .onHover { hovering = $0 }
        .help(note.displayTitle)
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
                Text("点击打开")
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
            in: body, range: NSRange(location: 0, length: (body as NSString).length), withTemplate: "[图片]"
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

/// 木夹子
private struct Clothespin: View {
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
