import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 全局防抖：无论 mouseUp / delegate / clickedOnLink 谁先到，同一 URL 在窗口内只打开一次。
enum EdgeNotesLinkOpener {
    private static var lastURL: URL?
    private static var lastTime: CFAbsoluteTime = 0
    private static let debounce: CFAbsoluteTime = 0.85

    private static func key(_ url: URL) -> String {
        var s = url.absoluteString
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }

    @discardableResult
    static func open(_ url: URL) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        let k = key(url)
        if let lastURL, key(lastURL) == k, now - lastTime < debounce {
            return false
        }
        lastURL = url
        lastTime = now
        NSWorkspace.shared.open(url)
        return true
    }

    static func resolve(_ link: Any) -> URL? {
        if let u = link as? URL { return u }
        if let s = link as? String { return URL(string: s) }
        return nil
    }
}

/// 可获焦的正文编辑器（WYSIWYG：粗体 / 列表 / 待办勾选 / 图片）。
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var onChange: () -> Void
    var bridge: EditorBridge
    var focusToken: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.focusRingType = .none

        let tv = TypingTextView()
        tv.delegate = context.coordinator
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = NSFont.systemFont(ofSize: 13)
        tv.textColor = NSColor.labelColor
        tv.insertionPointColor = NSColor.labelColor
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 4, height: 6)
        let width = max(240, scroll.contentSize.width - 24)
        tv.textStorage?.setAttributedString(
            NoteBodyRendering.attributed(from: text, maxImageWidth: width)
        )
        tv.isEditable = isEditable
        tv.isSelectable = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        // 链接样式自管；打开只走 openLinkOnce，避免与系统默认双开
        tv.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        tv.registerForDraggedTypes([.fileURL])
        tv.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: tv, userInfo: nil))

        scroll.documentView = tv
        context.coordinator.textView = tv
        bridge.textView = tv
        tv.bridge = bridge
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        bridge.textView = tv
        if let typing = tv as? TypingTextView {
            typing.bridge = bridge
        }
        if tv.isEditable != isEditable {
            tv.isEditable = isEditable
        }
        let currentMD = NoteBodyRendering.markdown(from: tv.attributedString())
        if !context.coordinator.isTyping, currentMD != text {
            let selected = tv.selectedRange()
            let width = max(240, (tv.bounds.width > 1 ? tv.bounds.width : 280) - 24)
            tv.textStorage?.setAttributedString(
                NoteBodyRendering.attributed(from: text, maxImageWidth: width)
            )
            let maxLen = (tv.string as NSString).length
            let loc = min(selected.location, maxLen)
            tv.setSelectedRange(NSRange(location: loc, length: 0))
        }
        if focusToken != context.coordinator.lastFocusToken, isEditable {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                tv.window?.makeKeyAndOrderFront(nil)
                tv.window?.makeFirstResponder(tv)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: NSTextView?
        var isTyping = false
        var lastFocusToken = -1

        init(_ parent: MarkdownTextView) { self.parent = parent }

        /// 吞掉系统默认打开。鼠标路径由 TypingTextView 严格命中后自行 open；
        /// 此处仅处理 AXPress 等非鼠标激活（避免空白处经 AppKit 误触打开）。
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let tv = textView as? TypingTextView,
               tv.shouldOpenFromClickedOnLink(atCharacterIndex: charIndex),
               let url = EdgeNotesLinkOpener.resolve(link) {
                EdgeNotesLinkOpener.open(url)
            }
            return true // 始终阻止 NSTextView 再 open
        }

        func textDidBeginEditing(_ notification: Notification) {
            isTyping = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isTyping = false
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            isTyping = true
            let md = NoteBodyRendering.markdown(from: tv.attributedString())
            if parent.text != md {
                parent.text = md
                parent.onChange()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                if self?.textView?.window?.firstResponder !== self?.textView {
                    self?.isTyping = false
                }
            }
        }
    }
}

/// 确保能成为 firstResponder；拦截粘贴 / 拖放图片；中文系统菜单；待办勾选。
final class TypingTextView: NSTextView {
    weak var bridge: EditorBridge?
    private var pendingLinkURL: URL?
    private var pendingLinkDown: NSPoint?
    /// Set for the duration of a real mouse click so `clickedOnLink` does not also open
    /// (blank clicks must not open; AXPress leaves this false and may open via delegate).
    private var mouseClickOwnsLinkOpen = false

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        super.becomeFirstResponder()
    }

    // MARK: - Chinese context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        Self.localizeMenuTree(menu)
        return menu
    }

    private static let menuZH: [String: String] = [
        "Cut": L("剪切"),
        "Copy": L("拷贝"),
        "Paste": L("粘贴"),
        "Paste and Match Style": L("粘贴并匹配样式"),
        "Delete": L("删除"),
        "Select All": L("全选"),
        "Font": L("字体"),
        "Show Fonts": L("显示字体"),
        "Bold": L("粗体"),
        "Italic": L("斜体"),
        "Underline": L("下划线"),
        "Outline": L("轮廓"),
        "Styles…": L("样式…"),
        "Styles...": L("样式…"),
        "Bigger": L("加大"),
        "Smaller": L("减小"),
        "Kern": L("字距"),
        "Ligature": L("连字"),
        "Baseline": L("基线"),
        "Spelling and Grammar": L("拼写和语法"),
        "Show Spelling and Grammar": L("显示拼写和语法"),
        "Check Document Now": L("立即检查文稿"),
        "Check Spelling While Typing": L("键入时检查拼写"),
        "Check Grammar With Spelling": L("检查拼写和语法"),
        "Correct Spelling Automatically": L("自动纠正拼写"),
        "Substitutions": L("替换"),
        "Show Substitutions": L("显示替换"),
        "Smart Copy/Paste": L("智能拷贝/粘贴"),
        "Smart Quotes": L("智能引号"),
        "Smart Dashes": L("智能破折号"),
        "Smart Links": L("智能链接"),
        "Data Detectors": L("数据检测器"),
        "Text Replacement": L("文本替换"),
        "Transformations": L("转换"),
        "Make Upper Case": L("大写"),
        "Make Lower Case": L("小写"),
        "Capitalize": L("字首大写"),
        "Speech": L("朗读"),
        "Start Speaking": L("开始朗读"),
        "Stop Speaking": L("停止朗读"),
        "Layout Orientation": L("布局方向"),
        "Horizontal": L("水平"),
        "Vertical": L("竖直"),
        "AutoFill": L("自动填充"),
        "Share…": L("共享…"),
        "Share...": L("共享…"),
        "Look Up": L("查询"),
        "Search with Google": L("使用 Google 搜索"),
        "Translate": L("翻译")
    ]

    private static func localizeMenuTree(_ menu: NSMenu) {
        for item in menu.items {
            if let zh = menuZH[item.title] {
                item.title = zh
            }
            if let sub = item.submenu {
                localizeMenuTree(sub)
            }
        }
    }

    // MARK: - Checkbox / link click
    // 策略：链接点击一律自己打开（EdgeNotesLinkOpener 防抖），且尽量不把事件交给
    // NSTextView 默认逻辑；delegate clickedOnLink 再吞一次兜底。

    override func mouseDown(with event: NSEvent) {
        mouseClickOwnsLinkOpen = true
        if isEditable, toggleCheckbox(at: event) {
            pendingLinkURL = nil
            return
        }
        if let url = linkURL(at: event), !event.modifierFlags.contains(.shift) {
            pendingLinkURL = url
            pendingLinkDown = event.locationInWindow
            // 链接触摸：不调用 super.mouseDown，避免 AppKit 武装默认「打开链接」手势
            // （非编辑 / ⌘-点 时尤其会与我们的 mouseUp 叠成双开）
            return
        }
        pendingLinkURL = nil
        pendingLinkDown = nil
        // 空白处：仍走 super 以便选区，但 mouseClickOwnsLinkOpen 让 clickedOnLink 不再打开
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pendingLinkURL = nil
            pendingLinkDown = nil
            // Keep ownership through any nested clickedOnLink from super.mouseUp, then clear.
            DispatchQueue.main.async { [weak self] in
                self?.mouseClickOwnsLinkOpen = false
            }
        }
        if let url = pendingLinkURL, let start = pendingLinkDown {
            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y
            if (dx * dx + dy * dy) < 36 { // ~6pt，触控板微抖仍算点击
                // 抬起时再严格命中一次：滑到空白/字距外不打开
                if linkURL(at: event) != nil {
                    EdgeNotesLinkOpener.open(url)
                    return // 绝不 super：防止默认再开
                }
            }
            // 拖选 / 未命中字形：交给系统（clickedOnLink 被 mouseClickOwnsLinkOpen 抑制）
        }
        super.mouseUp(with: event)
    }


    override func mouseMoved(with event: NSEvent) {
        if linkURL(at: event) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
        super.mouseMoved(with: event)
    }

    /// True only when the event lands on a non-whitespace glyph that has `.link`.
    /// `characterIndex(for:)` snaps to the nearest char — blank/padding clicks must not count.
    private func linkURL(at event: NSEvent) -> URL? {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage else { return nil }
        let pointInView = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let pointInContainer = NSPoint(x: pointInView.x - origin.x, y: pointInView.y - origin.y)
        var fraction: CGFloat = 0
        let idx = lm.characterIndex(
            for: pointInContainer,
            in: tc,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        guard idx < ts.length else { return nil }
        guard isExactLinkGlyphHit(atCharacterIndex: idx, pointInView: pointInView) else { return nil }
        let raw = ts.attribute(.link, at: idx, effectiveRange: nil)
        if let u = raw as? URL { return u }
        if let s = raw as? String { return URL(string: s) }
        return nil
    }

    /// Character at idx has `.link` and is not whitespace/newline.
    private func isLinkCharacter(_ idx: Int) -> Bool {
        guard let ts = textStorage, idx >= 0, idx < ts.length else { return false }
        guard ts.attribute(.link, at: idx, effectiveRange: nil) != nil else { return false }
        let ch = (ts.string as NSString).character(at: idx)
        if let scalar = Unicode.Scalar(ch), CharacterSet.whitespacesAndNewlines.contains(scalar) {
            return false
        }
        return true
    }

    /// Glyph-bounds hit test in view coordinates.
    func isExactLinkGlyphHit(atCharacterIndex idx: Int, pointInView: NSPoint) -> Bool {
        guard let lm = layoutManager, let tc = textContainer else { return false }
        guard isLinkCharacter(idx) else { return false }
        let glyphRange = lm.glyphRange(
            forCharacterRange: NSRange(location: idx, length: 1),
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return false }
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        let origin = textContainerOrigin
        rect = rect.offsetBy(dx: origin.x, dy: origin.y)
        // Tiny slack for trackpad jitter; not enough to reach empty margin past the glyph.
        return rect.insetBy(dx: -2, dy: -2).contains(pointInView)
    }

    /// Delegate path: mouse clicks are owned by mouseUp (blank must not open).
    /// AXPress / non-mouse activation opens when `charIndex` is a real link glyph.
    func shouldOpenFromClickedOnLink(atCharacterIndex idx: Int) -> Bool {
        guard isLinkCharacter(idx) else { return false }
        if mouseClickOwnsLinkOpen {
            return false // mouseUp already opened, or blank click — do not open
        }
        return true
    }

    @discardableResult
    private func toggleCheckbox(at event: NSEvent) -> Bool {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage else { return false }
        let point = convert(event.locationInWindow, from: nil)
        var fraction: CGFloat = 0
        let idx = lm.characterIndex(for: point, in: tc, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard idx < ts.length,
              let box = ts.attribute(.attachment, at: idx, effectiveRange: nil) as? EdgeNotesCheckboxAttachment else {
            return false
        }
        // 只在勾选框附近命中
        let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: idx, length: 1), actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        let hit = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y).insetBy(dx: -6, dy: -6)
        guard hit.contains(point) else { return false }
        let para = (string as NSString).paragraphRange(for: NSRange(location: idx, length: 0))
        let info = NoteBodyRendering.paragraphInfo(in: ts, paragraph: para)
        rewriteParagraphs([para]) { _ in (.todo(!box.isChecked), info.level) }
        return true
    }

    // MARK: - 列表编辑（段落模型）

    /// 选区覆盖到的所有段落
    func selectedParagraphs() -> [NSRange] {
        let ns = string as NSString
        let sel = selectedRange()
        var out: [NSRange] = []
        var loc = sel.location
        repeat {
            let para = ns.paragraphRange(for: NSRange(location: min(loc, ns.length), length: 0))
            out.append(para)
            loc = NSMaxRange(para)
        } while loc < NSMaxRange(sel) && loc < ns.length
        return out
    }

    func info(_ para: NSRange) -> NoteBodyRendering.ParagraphInfo {
        NoteBodyRendering.paragraphInfo(in: textStorage ?? NSTextStorage(), paragraph: para)
    }

    private var bodyFont: NSFont { font ?? .systemFont(ofSize: 13) }

    /// 把若干段落改成新的列表格式（nil = 普通段落），作为一次可撤销的编辑；保持光标在正文中的相对位置
    func rewriteParagraphs(_ paragraphs: [NSRange], to format: (NoteBodyRendering.ParagraphInfo) -> (ListKind?, Int)) {
        guard let ts = textStorage, let first = paragraphs.first, let last = paragraphs.last else { return }
        let block = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let sel = selectedRange()
        let rebuilt = NSMutableAttributedString()
        var newSel = sel
        var shift = 0
        for para in paragraphs {
            let old = info(para)
            let (kind, level) = format(old)
            let start = rebuilt.length
            if let kind { rebuilt.append(NoteBodyRendering.marker(kind, level: level, font: bodyFont)) }
            let content = NSMutableAttributedString(attributedString: ts.attributedSubstring(from: old.content))
            let full = NSRange(location: 0, length: content.length)
            content.removeAttribute(EdgeNotesAttrs.listMarker, range: full)
            content.removeAttribute(EdgeNotesAttrs.listLevel, range: full)
            var checked = false
            if case .todo(let c)? = kind { checked = c }
            if checked {
                content.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: full)
                content.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: full)
            } else {
                content.removeAttribute(.strikethroughStyle, range: full)
                content.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
            }
            rebuilt.append(content)
            if NSMaxRange(para) > NSMaxRange(old.content) {
                rebuilt.append(ts.attributedSubstring(from: NSRange(location: NSMaxRange(old.content), length: NSMaxRange(para) - NSMaxRange(old.content))))
            }
            let style = kind != nil ? NoteBodyRendering.listParagraphStyle(level: level) : NoteBodyRendering.plainParagraphStyle
            rebuilt.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: rebuilt.length - start))
            // 光标跟着正文走：在正文里就按标记长度变化平移；在旧标记里就落到新正文开头
            let newMarkerLen = kind.map { NoteBodyRendering.marker($0, level: level, font: bodyFont).length } ?? 0
            let delta = (rebuilt.length - start) - para.length
            if sel.location >= old.content.location && sel.location <= NSMaxRange(para) {
                newSel.location = sel.location + shift + (newMarkerLen - old.marker.length)
            } else if sel.location >= para.location && sel.location < old.content.location {
                newSel.location = para.location + shift + newMarkerLen
            }
            shift += delta
        }
        guard shouldChangeText(in: block, replacementString: rebuilt.string) else { return }
        ts.replaceCharacters(in: block, with: rebuilt)
        didChangeText()
        let maxLen = (string as NSString).length
        newSel.location = min(max(0, newSel.location), maxLen)
        newSel.length = sel.length > 0 ? min(rebuilt.length, maxLen - newSel.location) : 0
        if sel.length > 0 { newSel = NSRange(location: block.location, length: rebuilt.length) }
        setSelectedRange(newSel)
        renumberLists()
    }

    /// 切换选中各行的列表格式：全都是这种就取消，否则统一改成这种
    func toggleList(_ kind: ListKind) {
        let paras = selectedParagraphs()
        let allSame = paras.allSatisfy { info($0).kind.map { $0.sameFamily(kind) } ?? false }
        rewriteParagraphs(paras) { old in
            allSame ? (nil, 0) : (kind, old.kind == nil ? 0 : old.level)
        }
    }

    /// 编号列表按层级重新连续编号（只改有变化的标记）
    func renumberLists() {
        guard let ts = textStorage else { return }
        let ns = string as NSString
        var counters = [Int](repeating: 0, count: NoteBodyRendering.maxListLevel + 1)
        var fixes: [(NSRange, Int, Int)] = []
        var loc = 0
        while loc < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            let i = info(para)
            if let kind = i.kind {
                for l in (i.level + 1)..<counters.count { counters[l] = 0 }
                if case .number(let n) = kind {
                    counters[i.level] += 1
                    if n != counters[i.level] { fixes.append((i.marker, counters[i.level], i.level)) }
                } else {
                    counters[i.level] = 0
                }
            } else if i.content.length > 0 {
                counters = counters.map { _ in 0 }
            }
            loc = NSMaxRange(para)
        }
        guard !fixes.isEmpty else { return }
        let sel = selectedRange()
        var offset = 0
        for (range, n, level) in fixes {
            let r = NSRange(location: range.location + offset, length: range.length)
            let marker = NoteBodyRendering.marker(.number(n), level: level, font: bodyFont)
            guard shouldChangeText(in: r, replacementString: marker.string) else { continue }
            ts.replaceCharacters(in: r, with: marker)
            didChangeText()
            offset += marker.length - range.length
        }
        setSelectedRange(NSRange(location: min(sel.location + offset, (string as NSString).length), length: 0))
    }

    override func insertNewline(_ sender: Any?) {
        guard isEditable, selectedRange().length == 0 else { super.insertNewline(sender); return }
        let caret = selectedRange().location
        let para = (string as NSString).paragraphRange(for: NSRange(location: caret, length: 0))
        let i = info(para)
        guard let kind = i.kind, caret >= i.content.location else { super.insertNewline(sender); return }
        // 空的列表项：有缩进先退一级，否则结束列表
        if i.content.length == 0 {
            rewriteParagraphs([para]) { _ in i.level > 0 ? (kind, i.level - 1) : (nil, 0) }
            return
        }
        let next: ListKind
        switch kind {
        case .bullet: next = .bullet
        case .number(let n): next = .number(n + 1)
        case .todo: next = .todo(false)
        }
        let chunk = NSMutableAttributedString(string: "\n", attributes: [.font: bodyFont, .paragraphStyle: NoteBodyRendering.listParagraphStyle(level: i.level)])
        chunk.append(NoteBodyRendering.marker(next, level: i.level, font: bodyFont))
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: chunk.string), let ts = textStorage else { return }
        ts.replaceCharacters(in: range, with: chunk)
        // 新段落里被带过去的正文去掉删除线（新待办未完成）
        let newPara = (string as NSString).paragraphRange(for: NSRange(location: range.location + 1, length: 0))
        let ni = info(newPara)
        ts.removeAttribute(.strikethroughStyle, range: ni.content)
        ts.addAttribute(.foregroundColor, value: NSColor.labelColor, range: ni.content)
        ts.addAttribute(.paragraphStyle, value: NoteBodyRendering.listParagraphStyle(level: i.level), range: newPara)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + chunk.length, length: 0))
        renumberLists()
    }

    /// 在列表标记后按删除：先退缩进，再去掉标记
    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if isEditable, sel.length == 0 {
            let para = (string as NSString).paragraphRange(for: NSRange(location: sel.location, length: 0))
            let i = info(para)
            if let kind = i.kind, sel.location == i.content.location {
                rewriteParagraphs([para]) { _ in i.level > 0 ? (kind, i.level - 1) : (nil, 0) }
                return
            }
        }
        super.deleteBackward(sender)
    }

    override func insertTab(_ sender: Any?) {
        if isEditable, shiftLevel(by: 1) { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if isEditable, shiftLevel(by: -1) { return }
        super.insertBacktab(sender)
    }

    /// 选中的列表行整体缩进 / 退缩进；没有列表行返回 false
    private func shiftLevel(by delta: Int) -> Bool {
        let paras = selectedParagraphs()
        guard paras.contains(where: { info($0).kind != nil }) else { return false }
        rewriteParagraphs(paras) { old in
            guard let kind = old.kind else { return (nil, 0) }
            return (kind, min(NoteBodyRendering.maxListLevel, max(0, old.level + delta)))
        }
        return true
    }

    /// 输入快捷方式：行首敲「- 」「* 」「1. 」「[] 」「[ ] 」自动变成列表 / 待办
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard isEditable, (string as? String) == " " || (string as? NSAttributedString)?.string == " " else { return }
        let caret = selectedRange().location
        let ns = self.string as NSString
        let para = ns.paragraphRange(for: NSRange(location: caret, length: 0))
        let i = info(para)
        let typed = ns.substring(with: NSRange(location: i.content.location, length: max(0, caret - i.content.location)))
        var kind: ListKind?
        if i.kind == nil {
            if typed == "- " || typed == "* " { kind = .bullet }
            else if typed == "[] " || typed == "[ ] " || typed == "- [ ] " { kind = .todo(false) }
            else if typed == "[x] " || typed == "- [x] " { kind = .todo(true) }
            else if typed.range(of: #"^\d{1,3}[.)] $"#, options: .regularExpression) != nil { kind = .number(Int(typed.prefix { $0.isNumber }) ?? 1) }
        } else if case .bullet? = i.kind, typed == "[] " || typed == "[ ] " {
            kind = .todo(false)
        }
        guard let kind, let ts = textStorage else { return }
        let typedRange = NSRange(location: i.content.location, length: (typed as NSString).length)
        guard shouldChangeText(in: typedRange, replacementString: "") else { return }
        ts.replaceCharacters(in: typedRange, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: typedRange.location, length: 0))
        let newPara = (self.string as NSString).paragraphRange(for: NSRange(location: typedRange.location, length: 0))
        rewriteParagraphs([newPara]) { old in (kind, old.level) }
    }

    /// 光标移动后，新输入的文字不要沿用列表标记的属性
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        var attrs = typingAttributes
        if attrs[EdgeNotesAttrs.listMarker] != nil || attrs[.attachment] != nil {
            attrs[EdgeNotesAttrs.listMarker] = nil
            attrs[EdgeNotesAttrs.listLevel] = nil
            attrs[.attachment] = nil
            attrs[.foregroundColor] = NSColor.labelColor
            attrs[.font] = bodyFont
            typingAttributes = attrs
        }
    }

    /// 粗体开关：有选区时整段都粗就取消，否则加粗；没有选区时切换接下来输入的字
    func toggleBold() {
        guard let ts = textStorage else { return }
        let range = selectedRange()
        func isBold(_ f: NSFont?) -> Bool { f.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false }
        if range.length == 0 {
            let current = typingAttributes[.font] as? NSFont ?? bodyFont
            typingAttributes[.font] = isBold(current)
                ? NSFontManager.shared.convert(current, toNotHaveTrait: .boldFontMask)
                : NSFontManager.shared.convert(current, toHaveTrait: .boldFontMask)
            return
        }
        var allBold = true
        ts.enumerateAttribute(.font, in: range) { value, _, stop in
            if !isBold(value as? NSFont) { allBold = false; stop.pointee = true }
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        ts.beginEditing()
        ts.enumerateAttribute(.font, in: range) { value, sub, _ in
            // 列表标记不参与加粗
            if ts.attribute(EdgeNotesAttrs.listMarker, at: sub.location, effectiveRange: nil) != nil { return }
            let f = value as? NSFont ?? bodyFont
            let nf = allBold ? NSFontManager.shared.convert(f, toNotHaveTrait: .boldFontMask)
                             : NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
            ts.addAttribute(.font, value: nf, range: sub)
        }
        ts.endEditing()
        didChangeText()
    }

    // MARK: - Paste / Drag images

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, isEditable, window?.firstResponder === self,
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.charactersIgnoringModifiers == "b" {
            toggleBold()
            return true
        }
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.charactersIgnoringModifiers == "v" {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let md = Self.imageMarkdown(from: pb) {
            insertImageMarkdown(md, preferNewline: true)
            return
        }
        if let url = Self.url(from: pb) {
            let host = url.host ?? L("链接")
            let insertRange = selectedRange()
            insertLink(url: url, title: host)
            let titleProbeRange = NSRange(location: insertRange.location, length: (host as NSString).length)
            LinkTitleFetcher.fetch(url) { [weak self] title in
                guard let self, let ts = self.textStorage else { return }
                // 仍显示为同一条链接时，用网页标题替换可见文字
                let maxLen = ts.length
                guard titleProbeRange.location < maxLen else {
                    self.bridge?.onURLTitle?(title, url)
                    return
                }
                var eff = NSRange()
                let link = ts.attribute(.link, at: titleProbeRange.location, effectiveRange: &eff) as? URL
                guard link == url else {
                    self.bridge?.onURLTitle?(title, url)
                    return
                }
                let styled = NoteBodyRendering.linkAttributedString(
                    title: title,
                    url: url,
                    base: self.typingAttributes,
                    font: (self.font ?? NSFont.systemFont(ofSize: 13))
                )
                ts.replaceCharacters(in: eff, with: styled)
                self.didChangeText()
                self.bridge?.onURLTitle?(title, url)
            }
            return
        }
        let before = selectedRange()
        super.paste(sender)
        // 普通文本粘贴后：把裸 URL 染成可点链接
        linkifyBareURLs(around: before)
    }

    private func insertLink(url: URL, title: String) {
        guard let ts = textStorage else { return }
        let styled = NoteBodyRendering.linkAttributedString(
            title: title,
            url: url,
            base: typingAttributes,
            font: font ?? NSFont.systemFont(ofSize: 13)
        )
        let range = selectedRange()
        ts.replaceCharacters(in: range, with: styled)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + styled.length, length: 0))
    }

    /// 将指定范围附近新出现的裸 http(s) URL 加上 .link
    func linkifyBareURLs(around origin: NSRange) {
        guard let ts = textStorage else { return }
        let ns = string as NSString
        let start = max(0, origin.location - 8)
        let end = min(ns.length, max(NSMaxRange(origin), origin.location) + 2048)
        guard end > start else { return }
        let scan = NSRange(location: start, length: end - start)
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s<>\[\]\ufffc\"']+"#) else { return }
        let matches = re.matches(in: string, range: scan)
        ts.beginEditing()
        for m in matches.reversed() {
            var r = m.range
            var urlStr = ns.substring(with: r)
            while let last = urlStr.last, ".,;:!?)]}>'\"".contains(last) {
                urlStr = String(urlStr.dropLast())
                r.length -= 1
            }
            guard r.length > 0, let url = URL(string: urlStr), url.host != nil else { continue }
            // 已是链接则跳过
            if ts.attribute(.link, at: r.location, effectiveRange: nil) != nil { continue }
            var attrs = typingAttributes
            attrs[.link] = url
            attrs[.foregroundColor] = NSColor.linkColor
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.toolTip] = L("点击在浏览器中打开\n") + url.absoluteString
            ts.addAttributes(attrs, range: r)
        }
        ts.endEditing()
        if !matches.isEmpty {
            didChangeText()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.imageFileURLs(from: sender.draggingPasteboard).isEmpty { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !Self.imageFileURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.imageFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        // Place caret near drop point
        if let lm = layoutManager, let tc = textContainer {
            let point = convert(sender.draggingLocation, from: nil)
            var fraction: CGFloat = 0
            let idx = lm.characterIndex(for: point, in: tc, fractionOfDistanceBetweenInsertionPoints: &fraction)
            setSelectedRange(NSRange(location: min(idx, (string as NSString).length), length: 0))
        }
        for url in urls {
            if let md = AttachmentStore.saveImageFile(from: url) {
                insertImageMarkdown(md, preferNewline: true)
            }
        }
        return true
    }

    private static func imageFileURLs(from pb: NSPasteboard) -> [URL] {
        let exts = Set(["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"])
        var out: [URL] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] {
            for url in urls where exts.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        return out
    }

    private func insertChunk(_ text: String, preferNewline: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("![") && trimmed.contains("](attachments/") {
            insertImageMarkdown(trimmed, preferNewline: preferNewline)
            return
        }
        insertChunkPlain(text, preferNewline: preferNewline)
    }

    /// 把 `![](attachments/…)` 插成可见 NSTextAttachment；持久化仍写 markdown。
    func insertImageMarkdown(_ md: String, preferNewline: Bool) {
        guard let ts = textStorage else {
            insertChunkPlain(md, preferNewline: preferNewline)
            return
        }
        let trimmed = md.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pathStart = trimmed.range(of: "](attachments/") else {
            insertChunkPlain(md, preferNewline: preferNewline)
            return
        }
        let after = trimmed[pathStart.upperBound...]
        guard let end = after.firstIndex(of: ")") else {
            insertChunkPlain(md, preferNewline: preferNewline)
            return
        }
        let relative = "attachments/" + String(after[..<end])
        let width = max(240, bounds.width > 1 ? bounds.width - 24 : 280)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: textColor ?? NSColor.labelColor
        ]
        guard let piece = NoteBodyRendering.attachmentAttributedString(
            relativePath: relative,
            maxImageWidth: width,
            textAttrs: textAttrs
        ) else {
            insertChunkPlain(md, preferNewline: preferNewline)
            return
        }

        let chunk = NSMutableAttributedString()
        let range = selectedRange()
        if preferNewline, range.location > 0 {
            let prev = (string as NSString).substring(with: NSRange(location: max(0, range.location - 1), length: 1))
            if prev != "\n" {
                chunk.append(NSAttributedString(string: "\n", attributes: typingAttributes))
            }
        }
        chunk.append(piece)
        chunk.append(NSAttributedString(string: "\n", attributes: typingAttributes))

        ts.beginEditing()
        ts.replaceCharacters(in: range, with: chunk)
        ts.endEditing()
        didChangeText()
        setSelectedRange(NSRange(location: range.location + chunk.length, length: 0))
    }

    private func insertChunkPlain(_ text: String, preferNewline: Bool) {
        var chunk = text
        let range = selectedRange()
        if preferNewline, range.location > 0 {
            let prev = (string as NSString).substring(with: NSRange(location: max(0, range.location - 1), length: 1))
            if prev != "\n" { chunk = "\n" + chunk }
            if !chunk.hasSuffix("\n") { chunk += "\n" }
        }
        if shouldChangeText(in: range, replacementString: chunk) {
            replaceCharacters(in: range, with: chunk)
            didChangeText()
        }
    }

    private static func imageMarkdown(from pb: NSPasteboard) -> String? {
        if pb.canReadObject(forClasses: [NSImage.self], options: nil),
           let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = imgs.first,
           let md = AttachmentStore.saveImage(img, preferredName: "paste") {
            return md
        }
        for type in [NSPasteboard.PasteboardType.tiff, .png] {
            if let data = pb.data(forType: type), let img = NSImage(data: data),
               let md = AttachmentStore.saveImage(img, preferredName: "paste") {
                return md
            }
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                let ext = url.pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext),
                   let md = AttachmentStore.saveImageFile(from: url) {
                    return md
                }
            }
        }
        if let s = pb.string(forType: .fileURL) ?? pb.propertyList(forType: .fileURL) as? String {
            let path = s.replacingOccurrences(of: "file://", with: "").removingPercentEncoding ?? s
            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext),
               let md = AttachmentStore.saveImageFile(from: url) {
                return md
            }
        }
        return nil
    }

    private static func url(from pb: NSPasteboard) -> URL? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            if let u = urls.first(where: { $0.scheme == "http" || $0.scheme == "https" }) {
                return u
            }
        }
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let u = URL(string: s),
           let scheme = u.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           u.host != nil,
           !s.contains(" ") {
            return u
        }
        return nil
    }
}

@MainActor
final class EditorBridge: ObservableObject {
    weak var textView: NSTextView?
    var onURLTitle: ((String, URL) -> Void)?

    func focus() {
        guard let tv = textView else { return }
        NSApp.activate(ignoringOtherApps: true)
        tv.window?.makeKeyAndOrderFront(nil)
        tv.window?.makeFirstResponder(tv)
    }

    func bold() {
        focus()
        (textView as? TypingTextView)?.toggleBold()
    }

    func list() {
        focus()
        (textView as? TypingTextView)?.toggleList(.bullet)
    }

    func numbered() {
        focus()
        (textView as? TypingTextView)?.toggleList(.number(1))
    }

    func todo() {
        focus()
        (textView as? TypingTextView)?.toggleList(.todo(false))
    }

    func wrapSelection(left: String, right: String, placeholder: String = L("文本")) {
        guard let tv = textView, tv.window != nil else { return }
        focus()
        let ns = tv.string as NSString
        var range = tv.selectedRange()
        if range.location == NSNotFound { range = NSRange(location: ns.length, length: 0) }
        let selected = range.length > 0 ? ns.substring(with: range) : placeholder
        let replacement = left + selected + right
        if tv.shouldChangeText(in: range, replacementString: replacement) {
            tv.replaceCharacters(in: range, with: replacement)
            tv.didChangeText()
            let newLoc = range.location + (replacement as NSString).length
            tv.setSelectedRange(NSRange(location: newLoc, length: 0))
        }
    }

    func link() { wrapSelection(left: "[", right: "](https://)", placeholder: L("链接文字")) }

    func insertMarkdown(_ md: String) {
        guard let tv = textView else { return }
        focus()
        if let typing = tv as? TypingTextView,
           md.trimmingCharacters(in: .whitespacesAndNewlines).contains("](attachments/") {
            typing.insertImageMarkdown(md, preferNewline: true)
            return
        }
        let range = tv.selectedRange()
        let insert: String
        if range.location > 0 {
            let prev = (tv.string as NSString).substring(with: NSRange(location: max(0, range.location - 1), length: 1))
            insert = (prev == "\n" ? "" : "\n") + md + "\n"
        } else {
            insert = md + "\n"
        }
        if tv.shouldChangeText(in: range, replacementString: insert) {
            tv.replaceCharacters(in: range, with: insert)
            tv.didChangeText()
        }
    }

    func pasteImageFromClipboard() {
        guard let tv = textView as? TypingTextView else {
            textView?.paste(nil)
            return
        }
        tv.paste(nil)
    }

    func insertImageFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let md = AttachmentStore.saveImageFile(from: url) else { return }
        insertMarkdown(md)
    }
}
