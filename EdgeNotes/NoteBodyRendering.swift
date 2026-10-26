import AppKit

enum EdgeNotesAttrs {
    static let attachmentPath = NSAttributedString.Key("EdgeNotes.AttachmentPath")
    /// "ul" for bullet list marker characters
    static let listMarker = NSAttributedString.Key("EdgeNotes.ListMarker")
}

/// 正文存储仍为 Markdown；编辑器内渲染粗体 / 列表 / 待办勾选 / 图片。
enum NoteBodyRendering {
    private static let imageRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\((attachments\/[^)\s]+)\)"#
        )
    }()

    private static let boldRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
    }()

    /// Markdown 链接 `[text](https://…)`（排除图片 `![…](…)`）
    private static let mdLinkRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"(?<!!)\[([^\]]+)\]\((https?://[^)\s]+)\)"#)
    }()

    /// 裸 URL
    private static let bareURLRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"https?://[^\s<>\[\]\ufffc"']+"#)
    }()

    private static func baseAttrs(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: color
        ]
    }

    private static func boldFont(from font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    // MARK: - Markdown → Attributed

    static func attributed(
        from markdown: String,
        font: NSFont = .systemFont(ofSize: 13),
        color: NSColor = .labelColor,
        maxImageWidth: CGFloat = 280
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let attrs = baseAttrs(font: font, color: color)
        let lines = markdown.components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() {
            appendLine(line, into: result, base: attrs, font: font, color: color, maxImageWidth: maxImageWidth)
            if idx < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        }
        if markdown.hasSuffix("\n") {
            // components drops trailing empty only when fully trailing — keep parity
        }
        // Restore exact trailing newlines: components(separatedBy) keeps one trailing empty
        return result
    }

    private static func appendLine(
        _ line: String,
        into result: NSMutableAttributedString,
        base: [NSAttributedString.Key: Any],
        font: NSFont,
        color: NSColor,
        maxImageWidth: CGFloat
    ) {
        if let todo = parseTodoPrefix(line) {
            let box = checkboxAttachment(checked: todo.checked)
            let chunk = NSMutableAttributedString(attachment: box)
            chunk.addAttributes(base, range: NSRange(location: 0, length: chunk.length))
            result.append(chunk)
            result.append(NSAttributedString(string: " ", attributes: base))
            appendInline(todo.text, into: result, base: base, font: font, color: color, maxImageWidth: maxImageWidth, strike: todo.checked)
            return
        }
        if let bullet = parseBulletPrefix(line) {
            var markerAttrs = base
            markerAttrs[EdgeNotesAttrs.listMarker] = "ul"
            markerAttrs[.foregroundColor] = NSColor.secondaryLabelColor
            result.append(NSAttributedString(string: "• ", attributes: markerAttrs))
            appendInline(bullet, into: result, base: base, font: font, color: color, maxImageWidth: maxImageWidth, strike: false)
            return
        }
        appendInline(line, into: result, base: base, font: font, color: color, maxImageWidth: maxImageWidth, strike: false)
    }

    private static func parseTodoPrefix(_ line: String) -> (checked: Bool, text: String)? {
        let patterns: [(String, Bool)] = [
            ("- [x] ", true), ("- [X] ", true), ("- [ ] ", false),
            ("- [x]", true), ("- [X]", true), ("- [ ]", false)
        ]
        for (prefix, checked) in patterns {
            if line.hasPrefix(prefix) {
                var text = String(line.dropFirst(prefix.count))
                // strip a single leading space if prefix had no trailing space variant matched with content space
                if prefix.hasSuffix("]") { text = text.trimmingCharacters(in: .whitespaces) }
                return (checked, text)
            }
        }
        return nil
    }

    private static func parseBulletPrefix(_ line: String) -> String? {
        if line.hasPrefix("- [") { return nil } // checklist handled elsewhere
        if line.hasPrefix("- ") {
            return String(line.dropFirst(2))
        }
        if line.hasPrefix("* ") {
            return String(line.dropFirst(2))
        }
        return nil
    }

    private static func appendInline(
        _ text: String,
        into result: NSMutableAttributedString,
        base: [NSAttributedString.Key: Any],
        font: NSFont,
        color: NSColor,
        maxImageWidth: CGFloat,
        strike: Bool
    ) {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var cursor = 0
        let imgMatches = imageRegex.matches(in: text, range: full)

        func flushPlain(_ raw: String) {
            guard !raw.isEmpty else { return }
            appendLinksAndBold(raw, into: result, base: base, font: font, strike: strike)
        }

        for match in imgMatches {
            if match.range.location > cursor {
                flushPlain(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            let path = ns.substring(with: match.range(at: 2))
            let alt = ns.substring(with: match.range(at: 1))
            if let attachmentString = attachmentAttributedString(
                relativePath: path,
                alt: alt,
                maxImageWidth: maxImageWidth,
                textAttrs: base
            ) {
                result.append(attachmentString)
            } else {
                flushPlain(ns.substring(with: match.range))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            flushPlain(ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)))
        }
    }

    /// 先拆 markdown 链接与裸 URL，再处理粗体。
    private static func appendLinksAndBold(
        _ text: String,
        into result: NSMutableAttributedString,
        base: [NSAttributedString.Key: Any],
        font: NSFont,
        strike: Bool
    ) {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        // Collect non-overlapping link ranges: prefer [text](url) over bare URL
        var spans: [(range: NSRange, title: String, url: URL)] = []
        for m in mdLinkRegex.matches(in: text, range: full) {
            let title = ns.substring(with: m.range(at: 1))
            let urlStr = ns.substring(with: m.range(at: 2))
            guard let url = URL(string: urlStr) else { continue }
            spans.append((m.range, title, url))
        }
        for m in bareURLRegex.matches(in: text, range: full) {
            var r = m.range
            var urlStr = ns.substring(with: r)
            // Trim trailing punctuation often glued to URLs
            while let last = urlStr.last, ".,;:!?)]}>'\"".contains(last) {
                urlStr = String(urlStr.dropLast())
                r.length -= 1
            }
            guard r.length > 0, let url = URL(string: urlStr), url.host != nil else { continue }
            if spans.contains(where: { NSIntersectionRange($0.range, r).length > 0 }) { continue }
            spans.append((r, urlStr, url))
        }
        spans.sort { $0.range.location < $1.range.location }
        // 合并相邻且 URL 相同的 markdown 碎片（标题抓取曾把一句话拆成多段 [字](url)）
        if !spans.isEmpty {
            var merged: [(range: NSRange, title: String, url: URL)] = []
            var cur = spans[0]
            for next in spans.dropFirst() {
                if next.url == cur.url, next.range.location == NSMaxRange(cur.range) {
                    cur = (NSRange(location: cur.range.location, length: NSMaxRange(next.range) - cur.range.location),
                           cur.title + next.title,
                           cur.url)
                } else {
                    merged.append(cur)
                    cur = next
                }
            }
            merged.append(cur)
            spans = merged
        }

        var cursor = 0
        for span in spans {
            if span.range.location > cursor {
                let pre = NSRange(location: cursor, length: span.range.location - cursor)
                appendBoldAware(ns.substring(with: pre), into: result, base: base, font: font, strike: strike)
            }
            result.append(linkAttributedString(title: span.title, url: span.url, base: base, font: font, strike: strike))
            cursor = NSMaxRange(span.range)
        }
        if cursor < ns.length {
            let rest = NSRange(location: cursor, length: ns.length - cursor)
            appendBoldAware(ns.substring(with: rest), into: result, base: base, font: font, strike: strike)
        }
    }

    static func linkAttributedString(
        title: String,
        url: URL,
        base: [NSAttributedString.Key: Any]? = nil,
        font: NSFont = .systemFont(ofSize: 13),
        strike: Bool = false
    ) -> NSAttributedString {
        var attrs = base ?? [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        attrs[.link] = url
        attrs[.foregroundColor] = NSColor.linkColor
        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        attrs[.toolTip] = L("点击在浏览器中打开\n") + url.absoluteString
        if strike {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: title, attributes: attrs)
    }

    private static func appendBoldAware(
        _ text: String,
        into result: NSMutableAttributedString,
        base: [NSAttributedString.Key: Any],
        font: NSFont,
        strike: Bool
    ) {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = boldRegex.matches(in: text, range: full)
        var cursor = 0
        var plain = base
        if strike {
            plain[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            plain[.foregroundColor] = NSColor.secondaryLabelColor
        }
        var bold = plain
        bold[.font] = boldFont(from: font)

        for match in matches {
            if match.range.location > cursor {
                let r = NSRange(location: cursor, length: match.range.location - cursor)
                result.append(NSAttributedString(string: ns.substring(with: r), attributes: plain))
            }
            let inner = ns.substring(with: match.range(at: 1))
            result.append(NSAttributedString(string: inner, attributes: bold))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            let r = NSRange(location: cursor, length: ns.length - cursor)
            result.append(NSAttributedString(string: ns.substring(with: r), attributes: plain))
        }
    }

    // MARK: - Attributed → Markdown

    static func markdown(from attributed: NSAttributedString) -> String {
        let out = NSMutableString()
        let full = NSRange(location: 0, length: attributed.length)
        var i = 0
        while i < full.length {
            var eff = NSRange(location: i, length: 0)
            let attrs = attributed.attributes(at: i, effectiveRange: &eff)
            // clamp eff to not run past length
            if NSMaxRange(eff) > full.length {
                eff.length = full.length - eff.location
            }

            if let box = attrs[.attachment] as? EdgeNotesCheckboxAttachment {
                out.append(box.isChecked ? "- [x] " : "- [ ] ")
                i = eff.location + eff.length
                // skip a single following space that we inserted as padding
                if i < full.length {
                    let ch = (attributed.string as NSString).substring(with: NSRange(location: i, length: 1))
                    if ch == " " { i += 1 }
                }
                continue
            }

            if attrs[.attachment] is NSTextAttachment {
                if let path = attrs[EdgeNotesAttrs.attachmentPath] as? String {
                    out.append("![](\(path))")
                } else if let custom = attrs[.attachment] as? EdgeNotesImageAttachment {
                    out.append("![](\(custom.relativePath))")
                } else {
                    out.append("![image](attachments/unknown.png)")
                }
                i = eff.location + eff.length
                continue
            }

            if attrs[EdgeNotesAttrs.listMarker] as? String == "ul" {
                // Emit "- " once for the marker run ("• ")
                out.append("- ")
                i = eff.location + eff.length
                continue
            }

            // Collect a text run; fold bold spans into ** **
            let end = NSMaxRange(eff)
            emitStyledText(attributed, range: NSRange(location: i, length: end - i), into: out)
            i = end
        }
        return out as String
    }

    private static func emitStyledText(_ attributed: NSAttributedString, range: NSRange, into out: NSMutableString) {
        var i = range.location
        let end = NSMaxRange(range)

        func isBoldFont(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
            guard let font = attrs[.font] as? NSFont else { return false }
            return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        }

        func linkURL(from attrs: [NSAttributedString.Key: Any]) -> URL? {
            if let u = attrs[.link] as? URL { return u }
            if let s = attrs[.link] as? String { return URL(string: s) }
            return nil
        }

        while i < end {
            var eff = NSRange()
            let attrs = attributed.attributes(at: i, effectiveRange: &eff)
            let sliceEnd = min(NSMaxRange(eff), end)
            let slice = NSRange(location: i, length: sliceEnd - i)
            let piece = (attributed.string as NSString).substring(with: slice)
            if piece.isEmpty || piece == "\u{FFFC}" {
                i = sliceEnd
                continue
            }

            if let url = linkURL(from: attrs) {
                // Extend across contiguous link runs with same URL (may include bold/color splits)
                var linkEnd = sliceEnd
                var title = piece
                while linkEnd < end {
                    var nextEff = NSRange()
                    let nextAttrs = attributed.attributes(at: linkEnd, effectiveRange: &nextEff)
                    guard let nextURL = linkURL(from: nextAttrs), nextURL == url else { break }
                    let nextSliceEnd = min(NSMaxRange(nextEff), end)
                    let nextPiece = (attributed.string as NSString).substring(
                        with: NSRange(location: linkEnd, length: nextSliceEnd - linkEnd)
                    )
                    if nextPiece == "\u{FFFC}" { break }
                    title += nextPiece
                    linkEnd = nextSliceEnd
                }
                let urlStr = url.absoluteString
                if title == urlStr {
                    out.append(urlStr)
                } else {
                    out.append("[\(title)](\(urlStr))")
                }
                i = linkEnd
                continue
            }

            if isBoldFont(attrs) {
                // coalesce bold until non-bold / link
                var boldEnd = sliceEnd
                var buf = piece
                while boldEnd < end {
                    var nextEff = NSRange()
                    let nextAttrs = attributed.attributes(at: boldEnd, effectiveRange: &nextEff)
                    if linkURL(from: nextAttrs) != nil { break }
                    guard isBoldFont(nextAttrs) else { break }
                    let nextSliceEnd = min(NSMaxRange(nextEff), end)
                    buf += (attributed.string as NSString).substring(
                        with: NSRange(location: boldEnd, length: nextSliceEnd - boldEnd)
                    )
                    boldEnd = nextSliceEnd
                }
                out.append("**")
                out.append(buf)
                out.append("**")
                i = boldEnd
                continue
            }

            out.append(piece)
            i = sliceEnd
        }
    }

    // MARK: - Attachments helpers

    static func checkboxAttachment(checked: Bool) -> EdgeNotesCheckboxAttachment {
        EdgeNotesCheckboxAttachment(isChecked: checked)
    }

    static func attachmentAttributedString(
        relativePath: String,
        alt: String = "",
        maxImageWidth: CGFloat,
        textAttrs: [NSAttributedString.Key: Any]
    ) -> NSAttributedString? {
        guard let url = AttachmentStore.absoluteURL(forMarkdownPath: relativePath),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        let scaled = scale(image, maxWidth: maxImageWidth)
        let attachment = EdgeNotesImageAttachment(relativePath: relativePath, image: scaled)
        let chunk = NSMutableAttributedString(attachment: attachment)
        let full = NSRange(location: 0, length: chunk.length)
        chunk.addAttribute(EdgeNotesAttrs.attachmentPath, value: relativePath, range: full)
        if !alt.isEmpty {
            chunk.addAttribute(.toolTip, value: alt, range: full)
        }
        if let font = textAttrs[.font] as? NSFont {
            chunk.addAttribute(.font, value: font, range: full)
        }
        return chunk
    }

    static func scale(_ image: NSImage, maxWidth: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let width = min(size.width, maxWidth)
        let height = size.height * (width / size.width)
        let target = NSSize(width: width, height: height)
        if abs(size.width - target.width) < 0.5 { return image }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(target.width * 2)),
            pixelsHigh: max(1, Int(target.height * 2)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return image }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: target)
        out.addRepresentation(rep)
        return out
    }
}

final class EdgeNotesImageAttachment: NSTextAttachment {
    let relativePath: String

    init(relativePath: String, image: NSImage) {
        self.relativePath = relativePath
        super.init(data: nil, ofType: nil)
        self.image = image
        let s = image.size
        bounds = CGRect(x: 0, y: -2, width: s.width, height: s.height)
    }

    required init?(coder: NSCoder) {
        self.relativePath = ""
        super.init(coder: coder)
    }
}

final class EdgeNotesCheckboxAttachment: NSTextAttachment {
    var isChecked: Bool {
        didSet { refreshImage() }
    }

    init(isChecked: Bool) {
        self.isChecked = isChecked
        super.init(data: nil, ofType: nil)
        refreshImage()
    }

    required init?(coder: NSCoder) {
        self.isChecked = false
        super.init(coder: coder)
        refreshImage()
    }

    private func refreshImage() {
        let name = isChecked ? "checkmark.circle.fill" : "circle"
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: isChecked ? L("已完成") : L("待办"))?
            .withSymbolConfiguration(cfg) ?? NSImage(size: NSSize(width: 14, height: 14))
        self.image = img
        bounds = CGRect(x: 0, y: -3, width: 14, height: 14)
    }
}
