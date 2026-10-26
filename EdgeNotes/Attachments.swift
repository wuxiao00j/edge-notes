import AppKit

enum AttachmentStore {
    /// 数据根目录，由 NoteStore 设置（附件放在其下的 Attachments/）
    nonisolated(unsafe) static var root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("EdgeNotes", isDirectory: true)

    static var directory: URL {
        let dir = root.appendingPathComponent("Attachments", isDirectory: true)
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

    /// 删除没有任何便签 / 回收站 / 历史版本引用的附件。
    /// 只清理 1 小时前的文件，避免刚拖进编辑器、尚未保存的图片被误删。
    static func collectGarbage(referencedBy referenced: Set<String>) {
        let dir = directory
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let cutoff = Date().addingTimeInterval(-3600)
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            var removed = 0
            for url in files where !referenced.contains(url.lastPathComponent) {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
                guard modified < cutoff else { continue }
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
            }
            if removed > 0 { NSLog("EdgeNotes: 清理了 \(removed) 个未引用附件") }
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
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) EdgeNotes/0.5",
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
                completion(finalTitle.isEmpty ? (url.host ?? L("链接")) : finalTitle)
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
