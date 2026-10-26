import Foundation
import SwiftUI

/// 经典贴纸色板（兼容旧数据 rawValue：mint/sky/peach/lavender/rose/slate）。
enum NoteColor: String, Codable, CaseIterable, Identifiable {
    case glass     // 默认磨玻璃本色（无贴纸色）
    case yellow
    case blue      // was sky
    case green     // was mint
    case pink      // was rose
    case purple    // was lavender
    case gray      // was slate
    // legacy aliases kept for decoding old files
    case mint, sky, peach, lavender, rose, slate

    var id: String { rawValue }

    /// 调色板：本色 + 可选贴纸色
    static var palette: [NoteColor] {
        [.glass, .yellow, .blue, .green, .pink, .purple, .gray]
    }

    static var allCases: [NoteColor] { palette }

    var label: String {
        switch normalized {
        case .glass: return L("本色")
        case .yellow: return L("黄色")
        case .blue: return L("蓝色")
        case .green: return L("绿色")
        case .pink: return L("粉色")
        case .purple: return L("紫色")
        case .gray: return L("灰色")
        default: return L("本色")
        }
    }

    var normalized: NoteColor {
        switch self {
        case .glass: return .glass
        case .yellow, .peach: return .yellow
        case .blue, .sky: return .blue
        case .green, .mint: return .green
        case .pink, .rose: return .pink
        case .purple, .lavender: return .purple
        case .gray, .slate: return .gray
        }
    }

    /// 贴纸色填充；glass 透明（由磨玻璃承载）
    var fill: Color {
        switch normalized {
        case .glass:  return Color.clear
        case .yellow: return Color(red: 1.00, green: 0.95, blue: 0.55)
        case .blue:   return Color(red: 0.75, green: 0.88, blue: 1.00)
        case .green:  return Color(red: 0.78, green: 0.95, blue: 0.78)
        case .pink:   return Color(red: 1.00, green: 0.82, blue: 0.88)
        case .purple: return Color(red: 0.90, green: 0.82, blue: 1.00)
        case .gray:   return Color(red: 0.90, green: 0.90, blue: 0.90)
        default:      return Color.clear
        }
    }

    var accent: Color {
        switch normalized {
        case .glass:  return Color.primary.opacity(0.55)
        case .yellow: return Color(red: 0.85, green: 0.62, blue: 0.10)
        case .blue:   return Color(red: 0.20, green: 0.45, blue: 0.85)
        case .green:  return Color(red: 0.20, green: 0.60, blue: 0.30)
        case .pink:   return Color(red: 0.85, green: 0.30, blue: 0.45)
        case .purple: return Color(red: 0.50, green: 0.30, blue: 0.80)
        case .gray:   return Color(red: 0.40, green: 0.40, blue: 0.42)
        default:      return Color.primary.opacity(0.55)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = (NoteColor(rawValue: raw) ?? .glass).normalized
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(normalized.rawValue)
    }
}

struct Note: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var title: String
    var body: String
    var color: NoteColor
    var tags: [String]
    var isArchived: Bool
    var isCollapsed: Bool
    var isLocked: Bool
    var opacity: Double
    var windowFrame: String?
    var pinnedToDesktop: Bool
    var reminderAt: Date?
    var reminderRepeatDays: Int?
    /// 挂在顶部挂绳上
    var onLine: Bool
    /// 在挂绳上的水平位置（0…1）；nil 表示尚未摆放
    var linePosition: Double?
    /// 挂上绳的时间（用于「挂满 N 天自动取下」）
    var lineHungAt: Date?
    /// 挂在绳上的本地文件：只记引用（书签），不复制文件
    var fileBookmark: Data?
    /// 这张卡片自己的大小（small / medium / large）；nil = 跟随设置里的默认
    var lineCardSize: String?
    var updatedAt: Date
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        color: NoteColor = .glass,
        tags: [String] = [],
        isArchived: Bool = false,
        isCollapsed: Bool = false,
        isLocked: Bool = false,
        opacity: Double = 1.0,
        windowFrame: String? = nil,
        pinnedToDesktop: Bool = false,
        reminderAt: Date? = nil,
        reminderRepeatDays: Int? = nil,
        onLine: Bool = false,
        linePosition: Double? = nil,
        lineHungAt: Date? = nil,
        fileBookmark: Data? = nil,
        updatedAt: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.color = color.normalized
        self.tags = tags
        self.isArchived = isArchived
        self.isCollapsed = isCollapsed
        self.isLocked = isLocked
        self.opacity = opacity
        self.windowFrame = windowFrame
        self.pinnedToDesktop = pinnedToDesktop
        self.reminderAt = reminderAt
        self.reminderRepeatDays = reminderRepeatDays
        self.onLine = onLine
        self.linePosition = linePosition
        self.lineHungAt = lineHungAt
        self.fileBookmark = fileBookmark
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }

    var preview: String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return L("空便签") }
        return String(trimmed.prefix(80)).replacingOccurrences(of: "\n", with: " ")
    }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let first = body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        var cleaned = first.trimmingCharacters(in: .whitespaces)
        // 只剥行首的列表/待办标记，正文里的 "- " 保留
        if let item = Checklist.parse(cleaned) {
            cleaned = item.text
        } else if cleaned.hasPrefix("- ") || cleaned.hasPrefix("• ") {
            cleaned = String(cleaned.dropFirst(2))
        }
        if Note.imageRegex.firstMatch(in: cleaned, range: NSRange(location: 0, length: (cleaned as NSString).length)) != nil {
            cleaned = L("图片")
        }
        cleaned = cleaned
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? L("未命名便签") : String(cleaned.prefix(28))
    }

    static let imageRegex = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\((attachments\/[^)\s]+)\)"#)

    /// 正文里引用的所有附件路径（attachments/…）
    var attachmentPaths: [String] {
        let ns = body as NSString
        return Note.imageRegex.matches(in: body, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 2))
        }
    }

    /// 正文只有一张图（挂绳上以照片样式展示）
    var isImageOnly: Bool {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        guard let m = Note.imageRegex.firstMatch(in: trimmed as String, range: NSRange(location: 0, length: trimmed.length)) else { return false }
        return m.range.length == trimmed.length
    }

    /// 正文只有一个网址（挂绳上以链接卡片展示，点击直接打开网页）
    var webLink: URL? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// 正文只是一个本地文件地址（挂绳上的文件卡片，指向原文件）
    var fileLink: URL? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("file://"), trimmed.rangeOfCharacter(from: .newlines) == nil,
              let url = URL(string: trimmed), url.isFileURL else { return nil }
        return url
    }

    var searchBlob: String {
        ([title, body] + tags).joined(separator: "\n").lowercased()
    }

    enum CodingKeys: String, CodingKey {
        case id, title, body, color, tags, isArchived, isCollapsed, isLocked
        case opacity, windowFrame, pinnedToDesktop, reminderAt, reminderRepeatDays
        case onLine, linePosition, lineHungAt, fileBookmark, lineCardSize
        case updatedAt, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        let decodedColor = try c.decodeIfPresent(NoteColor.self, forKey: .color) ?? .glass
        color = decodedColor.normalized
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        windowFrame = try c.decodeIfPresent(String.self, forKey: .windowFrame)
        pinnedToDesktop = try c.decodeIfPresent(Bool.self, forKey: .pinnedToDesktop) ?? false
        reminderAt = try c.decodeIfPresent(Date.self, forKey: .reminderAt)
        reminderRepeatDays = try c.decodeIfPresent(Int.self, forKey: .reminderRepeatDays)
        onLine = try c.decodeIfPresent(Bool.self, forKey: .onLine) ?? false
        linePosition = try c.decodeIfPresent(Double.self, forKey: .linePosition)
        lineHungAt = try c.decodeIfPresent(Date.self, forKey: .lineHungAt)
        fileBookmark = try c.decodeIfPresent(Data.self, forKey: .fileBookmark)
        lineCardSize = try c.decodeIfPresent(String.self, forKey: .lineCardSize)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(body, forKey: .body)
        try c.encode(color.normalized.rawValue, forKey: .color)
        try c.encode(tags, forKey: .tags)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encode(isCollapsed, forKey: .isCollapsed)
        try c.encode(isLocked, forKey: .isLocked)
        try c.encode(opacity, forKey: .opacity)
        try c.encodeIfPresent(windowFrame, forKey: .windowFrame)
        try c.encode(pinnedToDesktop, forKey: .pinnedToDesktop)
        try c.encodeIfPresent(reminderAt, forKey: .reminderAt)
        try c.encodeIfPresent(reminderRepeatDays, forKey: .reminderRepeatDays)
        try c.encode(onLine, forKey: .onLine)
        try c.encodeIfPresent(linePosition, forKey: .linePosition)
        try c.encodeIfPresent(lineHungAt, forKey: .lineHungAt)
        try c.encodeIfPresent(fileBookmark, forKey: .fileBookmark)
        try c.encodeIfPresent(lineCardSize, forKey: .lineCardSize)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

struct NoteVersion: Identifiable, Codable, Equatable {
    var id: UUID
    var noteID: UUID
    var title: String
    var body: String
    var savedAt: Date

    init(note: Note, id: UUID = UUID(), savedAt: Date = Date()) {
        self.id = id
        self.noteID = note.id
        self.title = note.title
        self.body = note.body
        self.savedAt = savedAt
    }
}

struct TrashEntry: Identifiable, Codable, Equatable {
    var id: UUID { note.id }
    var note: Note
    var deletedAt: Date
}

struct NotesDatabase: Codable {
    var notes: [Note]
    var trash: [TrashEntry]
    var versions: [NoteVersion]
    var schemaVersion: Int

    static let currentSchema = 5

    static var empty: NotesDatabase {
        NotesDatabase(notes: [], trash: [], versions: [], schemaVersion: currentSchema)
    }
}

/// 待办行解析：只认行首（可缩进）的 `- [ ]` / `- [x]` / `- [X]`。
enum Checklist {
    struct Item {
        var indent: String
        var done: Bool
        var text: String
    }

    private static let regex = try! NSRegularExpression(pattern: #"^(\s*)[-*] \[( |x|X)\](?: (.*))?$"#)

    static func parse(_ line: String) -> Item? {
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let indent = ns.substring(with: m.range(at: 1))
        let done = ns.substring(with: m.range(at: 2)) != " "
        let text = m.range(at: 3).location == NSNotFound ? "" : ns.substring(with: m.range(at: 3))
        return Item(indent: indent, done: done, text: text)
    }

    static func line(_ item: Item) -> String {
        item.indent + (item.done ? "- [x] " : "- [ ] ") + item.text
    }
}

/// 中文转拼音（系统自带转换），用于拼音 / 首字母搜索
enum Pinyin {
    /// full：去空格的全拼；initials：每个音节（或英文单词）的首字母
    static func of(_ text: String) -> (full: String, initials: String) {
        let m = NSMutableString(string: text.lowercased()) as CFMutableString
        CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        let latin = (m as String).lowercased()
        let words = latin.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return (words.joined(), String(words.compactMap(\.first)))
    }
}

/// 界面文字本地化：键就是中文原文；英文在 en.lproj/Localizable.strings
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// 带参数的本地化：键里用 %@ 占位，参数按顺序填入
func LF(_ key: String, _ args: Any...) -> String {
    String(format: L(key), arguments: args.map { "\($0)" as NSString })
}
