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
        case .glass: return "本色"
        case .yellow: return "黄色"
        case .blue: return "蓝色"
        case .green: return "绿色"
        case .pink: return "粉色"
        case .purple: return "紫色"
        case .gray: return "灰色"
        default: return "本色"
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
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }

    var preview: String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "空便签" }
        return String(trimmed.prefix(80)).replacingOccurrences(of: "\n", with: " ")
    }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let first = body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let cleaned = first
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "- [ ] ", with: "")
            .replacingOccurrences(of: "- [x] ", with: "")
            .replacingOccurrences(of: "- ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未命名便签" : String(cleaned.prefix(28))
    }

    var searchBlob: String {
        ([title, body] + tags).joined(separator: "\n").lowercased()
    }

    enum CodingKeys: String, CodingKey {
        case id, title, body, color, tags, isArchived, isCollapsed, isLocked
        case opacity, windowFrame, pinnedToDesktop, reminderAt, reminderRepeatDays
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

    static let currentSchema = 3

    static var empty: NotesDatabase {
        NotesDatabase(notes: [], trash: [], versions: [], schemaVersion: currentSchema)
    }
}
