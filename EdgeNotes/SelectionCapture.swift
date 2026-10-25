import AppKit
import ApplicationServices

enum SelectionCapture {
    struct Result {
        var text: String
        var source: String // "选区" / "剪贴板" / "空"
    }

    /// 优先读系统当前选区（需辅助功能权限）；失败则回退剪贴板（含图片提示）。
    static func capturePreferringSelection() -> Result {
        if let selected = selectedTextViaAccessibility(), !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Result(text: selected, source: "选区")
        }
        return captureClipboard()
    }

    static func captureClipboard() -> Result {
        let pb = NSPasteboard.general
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Result(text: s, source: "剪贴板")
        }
        // 图片：保存到附件并返回 markdown
        if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let img = imgs.first,
           let md = AttachmentStore.saveImage(img, preferredName: "paste") {
            return Result(text: md, source: "剪贴板图片")
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let text = urls.map(\.absoluteString).joined(separator: "\n")
            return Result(text: text, source: "剪贴板链接")
        }
        return Result(text: "", source: "空")
    }

    static func accessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func promptAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private static func selectedTextViaAccessibility() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedEl = focused else { return nil }
        let element = unsafeBitCast(focusedEl, to: AXUIElement.self)
        var selected: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
           let s = selected as? String, !s.isEmpty {
            return s
        }
        return nil
    }
}

enum AttachmentStore {
    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("EdgeNotes/Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func saveImageFile(from url: URL) -> String? {
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let name = "\(UUID().uuidString).\(ext)"
        let dest = directory.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return "![\(url.lastPathComponent)](attachments/\(name))"
        } catch {
            return nil
        }
    }

    static func saveImage(_ image: NSImage, preferredName: String) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let name = "\(preferredName)-\(UUID().uuidString).png"
        let dest = directory.appendingPathComponent(name)
        do {
            try png.write(to: dest)
            return "![\(preferredName)](attachments/\(name))"
        } catch {
            return nil
        }
    }

    static func absoluteURL(forMarkdownPath path: String) -> URL? {
        // attachments/xxx
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("attachments/") {
            return directory.appendingPathComponent(String(trimmed.dropFirst("attachments/".count)))
        }
        return nil
    }
}


extension Notification.Name {
    static let edgeNotesURLTitle = Notification.Name("EdgeNotes.URLTitle")
}

enum LinkTitleFetcher {
    /// 抓取网页 <title>；失败则回退 host。
    static func fetch(_ url: URL, completion: @escaping @MainActor (String) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) EdgeNotes/0.4",
            forHTTPHeaderField: "User-Agent"
        )
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var title = url.host ?? url.absoluteString
            if let data {
                let html = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""
                if let parsed = parseTitle(html), !parsed.isEmpty {
                    title = decodeEntities(parsed)
                }
            }
            let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                completion(finalTitle.isEmpty ? (url.host ?? "链接") : finalTitle)
            }
        }.resume()
    }

    private static func parseTitle(_ html: String) -> String? {
        // 简单匹配 <title>...</title>
        guard let startRange = html.range(of: "<title", options: .caseInsensitive) else { return nil }
        let after = html[startRange.upperBound...]
        guard let gt = after.firstIndex(of: ">") else { return nil }
        let rest = after[after.index(after: gt)...]
        guard let end = rest.range(of: "</title>", options: .caseInsensitive) else { return nil }
        return String(rest[..<end.lowerBound])
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let map = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "
        ]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        // numeric &#NNNN;
        if let re = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let ns = out as NSString
            let matches = re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed()
            for m in matches {
                if m.numberOfRanges >= 2 {
                    let num = ns.substring(with: m.range(at: 1))
                    if let code = Int(num), let scalar = UnicodeScalar(code) {
                        out = (out as NSString).replacingCharacters(in: m.range, with: String(Character(scalar)))
                    }
                }
            }
        }
        return out
    }
}
