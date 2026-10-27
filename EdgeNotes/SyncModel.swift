import Foundation
import CloudKit

/// 一条便签参与 iCloud 同步的内容。
/// 不同步的：历史版本、剪贴板、窗口位置、文件书签（只在本机有效）。
struct SyncedNote: Codable, Equatable {
    var title: String
    var body: String
    var tags: [String]
    var color: String
    var isArchived: Bool
    var isLocked: Bool
    var opacity: Double
    var reminderAt: Date?
    var reminderRepeatDays: Int?
    var onLine: Bool
    var linePosition: Double?
    var lineHungAt: Date?
    var lineCardSize: String?
    var createdAt: Date
    var updatedAt: Date
    /// 在回收站里：删除时间；nil = 正常便签
    var deletedAt: Date?

    init(note: Note, deletedAt: Date? = nil) {
        title = note.title
        body = note.body
        tags = note.tags
        color = note.color.normalized.rawValue
        isArchived = note.isArchived
        isLocked = note.isLocked
        opacity = note.opacity
        reminderAt = note.reminderAt
        reminderRepeatDays = note.reminderRepeatDays
        onLine = note.onLine
        linePosition = note.linePosition
        lineHungAt = note.lineHungAt
        lineCardSize = note.lineCardSize
        createdAt = note.createdAt
        updatedAt = note.updatedAt
        self.deletedAt = deletedAt
    }

    /// 写回一条便签；只在本机有效的字段（文件书签、窗口位置等）沿用 base
    func applied(to base: Note) -> Note {
        var n = base
        n.title = title
        n.body = body
        n.tags = tags
        n.color = NoteColor(rawValue: color)?.normalized ?? .glass
        n.isArchived = isArchived
        n.isLocked = isLocked
        n.opacity = opacity
        n.reminderAt = reminderAt
        n.reminderRepeatDays = reminderRepeatDays
        n.onLine = onLine
        n.linePosition = linePosition
        n.lineHungAt = lineHungAt
        n.lineCardSize = lineCardSize
        n.createdAt = createdAt
        n.updatedAt = updatedAt
        return n
    }
}

// MARK: - CloudKit 记录

enum SyncSchema {
    static let zoneName = "EdgeNotes"
    static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    static let noteType = "Note"
    static let attachmentType = "Attachment"

    static func noteRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    static func attachmentRecordID(_ fileName: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "att-" + fileName, zoneID: zoneID)
    }

    static func attachmentFileName(from id: CKRecord.ID) -> String? {
        id.recordName.hasPrefix("att-") ? String(id.recordName.dropFirst(4)) : nil
    }
}

extension SyncedNote {
    /// 标题、正文、标签放进端到端加密字段（苹果也看不到明文）
    func write(to record: CKRecord) {
        record.encryptedValues["title"] = title
        record.encryptedValues["body"] = body
        record.encryptedValues["tags"] = tags
        record["color"] = color
        record["isArchived"] = isArchived ? 1 : 0
        record["isLocked"] = isLocked ? 1 : 0
        record["opacity"] = opacity
        record["reminderAt"] = reminderAt
        record["reminderRepeatDays"] = reminderRepeatDays
        record["onLine"] = onLine ? 1 : 0
        record["linePosition"] = linePosition
        record["lineHungAt"] = lineHungAt
        record["lineCardSize"] = lineCardSize
        record["createdAt"] = createdAt
        record["updatedAt"] = updatedAt
        record["deletedAt"] = deletedAt
    }

    init?(record: CKRecord) {
        guard record.recordType == SyncSchema.noteType,
              let createdAt = record["createdAt"] as? Date,
              let updatedAt = record["updatedAt"] as? Date else { return nil }
        title = record.encryptedValues["title"] as? String ?? ""
        body = record.encryptedValues["body"] as? String ?? ""
        tags = record.encryptedValues["tags"] as? [String] ?? []
        color = record["color"] as? String ?? NoteColor.glass.rawValue
        isArchived = (record["isArchived"] as? Int64 ?? 0) != 0
        isLocked = (record["isLocked"] as? Int64 ?? 0) != 0
        opacity = record["opacity"] as? Double ?? 1
        reminderAt = record["reminderAt"] as? Date
        reminderRepeatDays = (record["reminderRepeatDays"] as? Int64).map(Int.init)
        onLine = (record["onLine"] as? Int64 ?? 0) != 0
        linePosition = record["linePosition"] as? Double
        lineHungAt = record["lineHungAt"] as? Date
        lineCardSize = record["lineCardSize"] as? String
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        deletedAt = record["deletedAt"] as? Date
    }
}

// MARK: - 冲突合并

enum SyncMerge {
    struct Result: Equatable {
        var merged: SyncedNote
        /// 两边都改了正文 / 标题：本机这份另存为一条冲突副本
        var conflictCopy: SyncedNote?
    }

    /// 三方合并：base 是上次同步成功时的内容（nil = 从没同步过）
    /// - 正文 / 标题两边都改了且不同：以云端为准，本机另存「冲突副本」，不丢字
    /// - 其它字段：只有一边改了就用那一边；两边都改了，按修改时间新的为准
    /// - 一边删除（进回收站）、另一边改了正文：编辑优先，恢复成正常便签
    static func merge(local: SyncedNote, server: SyncedNote, base: SyncedNote?) -> Result {
        if local == server { return Result(merged: server, conflictCopy: nil) }
        let localIsNewer = local.updatedAt > server.updatedAt

        func pick<T: Equatable>(_ key: KeyPath<SyncedNote, T>) -> T {
            guard let base else { return localIsNewer ? local[keyPath: key] : server[keyPath: key] }
            let localChanged = local[keyPath: key] != base[keyPath: key]
            let serverChanged = server[keyPath: key] != base[keyPath: key]
            switch (localChanged, serverChanged) {
            case (true, false): return local[keyPath: key]
            case (false, _): return server[keyPath: key]
            case (true, true): return localIsNewer ? local[keyPath: key] : server[keyPath: key]
            }
        }

        var merged = server
        var copy: SyncedNote?

        // 文字：两边各自改成了不同内容 → 冲突副本
        let localText = (local.title, local.body)
        let serverText = (server.title, server.body)
        let baseText = base.map { ($0.title, $0.body) }
        let localTextChanged = baseText.map { $0 != localText } ?? true
        let serverTextChanged = baseText.map { $0 != serverText } ?? true
        if localText != serverText {
            if localTextChanged && serverTextChanged {
                (merged.title, merged.body) = serverText
                copy = local
            } else if localTextChanged {
                (merged.title, merged.body) = localText
            } else {
                (merged.title, merged.body) = serverText
            }
        }

        // 标签：两边都改了就取并集
        if let base, local.tags != base.tags, server.tags != base.tags {
            merged.tags = server.tags + local.tags.filter { !server.tags.contains($0) }
        } else {
            merged.tags = pick(\.tags)
        }

        merged.color = pick(\.color)
        merged.isArchived = pick(\.isArchived)
        merged.isLocked = pick(\.isLocked)
        merged.opacity = pick(\.opacity)
        merged.reminderAt = pick(\.reminderAt)
        merged.reminderRepeatDays = pick(\.reminderRepeatDays)
        merged.onLine = pick(\.onLine)
        merged.linePosition = pick(\.linePosition)
        merged.lineHungAt = pick(\.lineHungAt)
        merged.lineCardSize = pick(\.lineCardSize)
        merged.createdAt = min(local.createdAt, server.createdAt)
        merged.updatedAt = max(local.updatedAt, server.updatedAt)

        // 删除 vs 编辑：有人改了文字，就别删
        merged.deletedAt = pick(\.deletedAt)
        if merged.deletedAt != nil {
            let deletedByServer = server.deletedAt != nil && base?.deletedAt == nil
            let deletedByLocal = local.deletedAt != nil && base?.deletedAt == nil
            if (deletedByServer && localTextChanged && base != nil) || (deletedByLocal && serverTextChanged && base != nil) {
                merged.deletedAt = nil
            }
        }

        if var c = copy {
            c.title = (c.title.isEmpty ? L("未命名便签") : c.title) + L("（冲突副本）")
            c.deletedAt = nil
            c.onLine = false
            c.linePosition = nil
            copy = c
        }
        return Result(merged: merged, conflictCopy: copy)
    }
}

/// 同步进度：引擎状态 + 每条便签上次同步成功的内容和记录元数据（存在数据目录的 sync-state.json）
struct SyncState: Codable {
    struct Base: Codable {
        var note: SyncedNote
        /// CKRecord.encodeSystemFields 的结果（带 change tag，更新时避免冲突）
        var systemFields: Data?
    }

    var engine: Data?
    var bases: [UUID: Base] = [:]
    var uploadedAttachments: Set<String> = []

    static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}
