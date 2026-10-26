import Foundation
import Combine
import AppKit

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published private(set) var trash: [TrashEntry] = []
    @Published private(set) var versions: [NoteVersion] = []
    @Published var selectedNoteID: UUID?
    @Published var searchQuery: String = ""
    @Published var showArchived: Bool = false
    @Published var showTrash: Bool = false
    @Published var filterTag: String?

    private let dir: URL
    private let dbURL: URL
    private let crashURL: URL
    private let backupURL: URL
    private let backupsDir: URL
    private var saveTask: Task<Void, Never>?
    private var versionTasks: [UUID: Task<Void, Never>] = [:]
    private var lastVersionSnapshot: [UUID: String] = [:]
    /// 读盘/写盘在后台串行队列上做，避免打字时卡主线程
    private let ioQueue = DispatchQueue(label: "EdgeNotes.persist", qos: .utility)
    /// 数据文件存在但无法解析且没有可用备份：不再写盘，避免覆盖用户数据
    private(set) var loadFailure: String?

    static let trashRetentionDays = 30
    static let dailyBackupsKept = 7

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dir = support.appendingPathComponent("EdgeNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("notes.json")
        crashURL = dir.appendingPathComponent("crash-recovery.json")
        backupURL = dir.appendingPathComponent("notes.backup.json")
        backupsDir = dir.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)

        let hadExistingData = load()
        recoverCrashDraftIfNeeded()

        if loadFailure == nil {
            // 启动时留一份「上次启动」的快照；放在写盘队列上，排在恢复写入之后，且只复制能解析的文件
            let dbURL = dbURL, backupURL = backupURL
            ioQueue.async {
                guard let data = try? Data(contentsOf: dbURL),
                      (try? JSONDecoder().decode(NotesDatabase.self, from: data)) != nil else { return }
                try? data.write(to: backupURL, options: .atomic)
            }
            expireOldTrash()
            AttachmentStore.collectGarbage(referencedBy: allReferencedAttachments())
        }

        if !hadExistingData && notes.isEmpty && trash.isEmpty {
            let welcome = Note(
                title: "欢迎使用贴边便签",
                body: """
                把鼠标移到菜单栏正下方停一下，挂绳会放下来；图片、文字、链接拖上去就挂住了。

                • 菜单栏图标或 ⌥⌘N 显示/隐藏这个侧栏
                • ⌥⌘T 极速新建并开始输入
                • ⌥⇧⌘V 把剪贴板内容贴成新便签
                • 点 + 默认在侧栏新建；底部「弹窗」可弹出独立贴纸窗
                • 拖动整条顶栏可移动；靠近右边缘松手贴回
                """,
                color: .glass,
                tags: ["入门"]
            )
            notes = [welcome]
            selectedNoteID = welcome.id
            persistNow(reason: "welcome")
        } else if selectedNoteID == nil {
            selectedNoteID = activeNotes.first?.id
        }
    }

    var dataDirectoryPath: String { dir.path }

    var activeNotes: [Note] {
        notes.filter { !$0.isArchived }
    }

    var visibleNotes: [Note] {
        var list = showArchived ? notes : activeNotes
        if let tag = filterTag, !tag.isEmpty {
            list = list.filter { $0.tags.contains(tag) }
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter { $0.searchBlob.contains(q) }
        }
        return list.sorted { $0.updatedAt > $1.updatedAt }
    }

    var allTags: [String] {
        Array(Set(notes.flatMap(\.tags))).sorted()
    }

    var selectedNote: Note? {
        guard let id = selectedNoteID else { return nil }
        return notes.first { $0.id == id }
    }

    // MARK: - CRUD

    @discardableResult
    func addNote(
        title: String = "",
        body: String = "",
        color: NoteColor? = nil,
        select: Bool = true,
        pinnedToDesktop: Bool = false
    ) -> Note {
        let note = Note(
            title: title,
            body: body,
            color: color ?? .glass,
            opacity: AppSettings.shared.defaultOpacity,
            pinnedToDesktop: pinnedToDesktop
        )
        notes.insert(note, at: 0)
        if select { selectedNoteID = note.id }
        scheduleSave()
        snapshotVersionSoon(noteID: note.id)
        return note
    }

    func note(id: UUID) -> Note? { notes.first { $0.id == id } }

    func select(_ id: UUID) {
        // 仅切换选中，不改 updatedAt，不调整排序
        selectedNoteID = id
    }

    /// - Parameter bumpModified: 是否更新「最后修改时间」并影响列表排序。选中、钉桌面等元数据应传 false。
    func update(id: UUID, bumpModified: Bool = true, mutate: (inout Note) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        mutate(&notes[index])
        notes[index].color = notes[index].color.normalized
        if bumpModified {
            notes[index].updatedAt = Date()
        }
        // 不在数组里手动置顶；列表按 updatedAt 排序
        scheduleSave()
        if bumpModified {
            snapshotVersionSoon(noteID: id)
        }
    }

    func updateSelected(title: String? = nil, body: String? = nil) {
        guard let id = selectedNoteID else { return }
        update(id: id) { note in
            if let title { note.title = title }
            if let body { note.body = body }
        }
    }

    func setColor(id: UUID, _ color: NoteColor) {
        update(id: id) { $0.color = color.normalized }
    }

    func setOpacity(id: UUID, _ opacity: Double) {
        update(id: id) { $0.opacity = min(1, max(0.35, opacity)) }
    }

    func setTags(id: UUID, _ tags: [String]) {
        update(id: id) { $0.tags = tags }
    }

    func toggleArchive(id: UUID) {
        update(id: id) { $0.isArchived.toggle() }
    }

    func toggleCollapsed(id: UUID) {
        update(id: id) { $0.isCollapsed.toggle() }
    }

    func setLocked(id: UUID, _ locked: Bool) {
        update(id: id, bumpModified: false) { $0.isLocked = locked }
    }

    // MARK: - Clothesline

    /// 挂在挂绳上的便签（不含归档）
    var lineNotes: [Note] {
        notes.filter { $0.onLine && !$0.isArchived }
    }

    func hangOnLine(id: UUID, at position: Double? = nil) {
        let pos = position ?? nextLineSlot()
        update(id: id, bumpModified: false) {
            $0.onLine = true
            $0.linePosition = min(1, max(0, pos))
        }
    }

    func takeOffLine(id: UUID) {
        update(id: id, bumpModified: false) {
            $0.onLine = false
            $0.linePosition = nil
        }
    }

    func setLinePosition(id: UUID, _ position: Double) {
        update(id: id, bumpModified: false) { $0.linePosition = min(1, max(0, position)) }
    }

    /// 新建一条直接挂上绳的便签（图片或文字）
    @discardableResult
    func addLineNote(body: String, at position: Double? = nil, color: NoteColor = .yellow) -> Note {
        let note = addNote(body: body, color: color, select: false)
        hangOnLine(id: note.id, at: position)
        return note
    }

    /// 挂一个网址：先用域名当标题，再去抓网页标题替换
    @discardableResult
    func addLineLink(_ url: URL, at position: Double? = nil) -> Note {
        let host = url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "链接"
        let note = addLineNote(body: url.absoluteString, at: position, color: .blue)
        update(id: note.id, bumpModified: false) { $0.title = host }
        LinkTitleFetcher.fetch(url) { [weak self] title in
            guard let self, let current = self.note(id: note.id), current.title == host else { return }
            self.update(id: note.id, bumpModified: false) { $0.title = title }
        }
        return note
    }

    /// 在现有夹子之间找最大的空隙
    func nextLineSlot() -> Double {
        let taken = lineNotes.compactMap(\.linePosition).sorted()
        let bounds = [0.0] + taken + [1.0]
        var best = (gap: -1.0, mid: 0.5)
        for i in 0..<(bounds.count - 1) {
            // 两端只算半个空隙，避免贴边
            let lo = bounds[i], hi = bounds[i + 1]
            let edge = (i == 0 || i == bounds.count - 2) && !taken.isEmpty
            let gap = (hi - lo) * (edge ? 0.5 : 1)
            if gap > best.gap {
                let mid: Double
                if taken.isEmpty { mid = 0.5 }
                else if i == 0 { mid = max(0.04, hi - 0.12) }
                else if i == bounds.count - 2 { mid = min(0.96, lo + 0.12) }
                else { mid = (lo + hi) / 2 }
                best = (gap, mid)
            }
        }
        return best.mid
    }

    func setReminder(id: UUID, at: Date?, repeatDays: Int?) {
        update(id: id) {
            $0.reminderAt = at
            $0.reminderRepeatDays = repeatDays
        }
    }

    func deleteSelected() {
        guard let id = selectedNoteID else { return }
        softDelete(id: id)
    }

    func softDelete(id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let note = notes.remove(at: index)
        trash.insert(TrashEntry(note: note, deletedAt: Date()), at: 0)
        if selectedNoteID == id {
            selectedNoteID = visibleNotes.first?.id
        }
        NoteWindowManager.shared.close(noteID: id)
        scheduleSave()
    }

    func restoreFromTrash(id: UUID) {
        guard let index = trash.firstIndex(where: { $0.note.id == id }) else { return }
        let entry = trash.remove(at: index)
        notes.insert(entry.note, at: 0)
        selectedNoteID = entry.note.id
        scheduleSave()
    }

    func purgeTrash(id: UUID) {
        trash.removeAll { $0.note.id == id }
        versions.removeAll { $0.noteID == id }
        scheduleSave()
        AttachmentStore.collectGarbage(referencedBy: allReferencedAttachments())
    }

    func emptyTrash() {
        let ids = Set(trash.map(\.note.id))
        trash.removeAll()
        versions.removeAll { ids.contains($0.noteID) }
        scheduleSave()
        AttachmentStore.collectGarbage(referencedBy: allReferencedAttachments())
    }

    /// 回收站超过保留期的条目自动清除
    private func expireOldTrash() {
        let cutoff = Date().addingTimeInterval(-Double(Self.trashRetentionDays) * 86400)
        let expired = Set(trash.filter { $0.deletedAt < cutoff }.map(\.note.id))
        guard !expired.isEmpty else { return }
        trash.removeAll { expired.contains($0.note.id) }
        versions.removeAll { expired.contains($0.noteID) }
        persistNow(reason: "trash-expire")
    }

    /// 便签、回收站、历史版本里引用到的附件文件名
    private func allReferencedAttachments() -> Set<String> {
        var bodies = notes.map(\.body) + trash.map(\.note.body) + versions.map(\.body)
        bodies.removeAll { !$0.contains("attachments/") }
        var names = Set<String>()
        for body in bodies {
            let probe = Note(body: body)
            for path in probe.attachmentPaths {
                names.insert(String(path.dropFirst("attachments/".count)))
            }
        }
        return names
    }

    // MARK: - Versions

    func versions(for noteID: UUID) -> [NoteVersion] {
        versions.filter { $0.noteID == noteID }.sorted { $0.savedAt > $1.savedAt }
    }

    func restoreVersion(_ version: NoteVersion) {
        update(id: version.noteID) {
            $0.title = version.title
            $0.body = version.body
        }
    }

    private func snapshotVersionSoon(noteID: UUID) {
        // 每条便签各自防抖，切到另一条编辑不会丢掉上一条的快照
        versionTasks[noteID]?.cancel()
        versionTasks[noteID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.versionTasks[noteID] = nil
            self.snapshotVersionNow(noteID: noteID)
        }
    }

    private func snapshotVersionNow(noteID: UUID) {
        guard let note = note(id: noteID) else { return }
        let fingerprint = note.title + "\u{1e}" + note.body
        if lastVersionSnapshot[noteID] == fingerprint { return }
        lastVersionSnapshot[noteID] = fingerprint
        versions.insert(NoteVersion(note: note), at: 0)
        // Keep last 12 per note
        var kept: [NoteVersion] = []
        var counts: [UUID: Int] = [:]
        for v in versions {
            let c = counts[v.noteID, default: 0]
            if c < 12 {
                kept.append(v)
                counts[v.noteID] = c + 1
            }
        }
        versions = kept
        scheduleSave()
    }

    // MARK: - Search jump

    func jumpToSearchResult(_ id: UUID) {
        if let note = notes.first(where: { $0.id == id }), note.isArchived {
            showArchived = true
        }
        showTrash = false
        selectedNoteID = id
    }

    // MARK: - Checklist helpers

    func toggleChecklistLine(noteID: UUID, lineIndex: Int) {
        guard let note = note(id: noteID) else { return }
        var lines = note.body.components(separatedBy: "\n")
        guard lineIndex >= 0, lineIndex < lines.count, var item = Checklist.parse(lines[lineIndex]) else { return }
        item.done.toggle()
        lines[lineIndex] = Checklist.line(item)
        // completed sink to bottom among checklist lines
        update(id: noteID) { $0.body = Self.sinkCompletedChecklists(lines.joined(separator: "\n")) }
    }

    /// 每个连续的待办块内，已完成项沉到块底；空行与其它内容原样保留。
    static func sinkCompletedChecklists(_ body: String) -> String {
        var out: [String] = []
        var open: [String] = []
        var done: [String] = []
        func flush() {
            out.append(contentsOf: open + done)
            open = []; done = []
        }
        for line in body.components(separatedBy: "\n") {
            if let item = Checklist.parse(line) {
                if item.done { done.append(line) } else { open.append(line) }
            } else {
                flush()
                out.append(line)
            }
        }
        flush()
        return out.joined(separator: "\n")
    }

    // MARK: - Export / Backup

    func exportNotes(format: ExportFormat, to url: URL) throws {
        // 导出当前列表（受归档/标签/搜索筛选影响）；列表为空时导出全部
        let payload = visibleNotes.isEmpty ? notes : visibleNotes
        switch format {
        case .json:
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)
        case .txt:
            let text = payload.map { n in
                "# \(n.displayTitle)\n\n\(n.body)\n"
            }.joined(separator: "\n-----\n\n")
            try text.write(to: url, atomically: true, encoding: .utf8)
        case .markdown:
            let text = payload.map { n in
                var md = "# \(n.displayTitle)\n\n"
                if !n.tags.isEmpty {
                    md += n.tags.map { "#\($0)" }.joined(separator: " ") + "\n\n"
                }
                md += n.body + "\n"
                return md
            }.joined(separator: "\n---\n\n")
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func manualBackup() throws -> URL {
        let url = dir.appendingPathComponent("backup-\(Self.fileStamp()).json")
        let db = NotesDatabase(notes: notes, trash: trash, versions: versions, schemaVersion: NotesDatabase.currentSchema)
        let data = try JSONEncoder().encode(db)
        try data.write(to: url, options: .atomic)
        return url
    }

    enum ExportFormat { case json, txt, markdown }

    // MARK: - Persistence

    /// - Returns: 数据目录里是否已经有数据文件（有就绝不能用欢迎便签覆盖）
    @discardableResult
    private func load() -> Bool {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return false }
        if let db = Self.decode(at: dbURL) {
            apply(db)
            return true
        }
        // 主文件坏了：先隔离，再依次尝试启动快照与每日备份
        let stamp = Self.fileStamp()
        let quarantine = dir.appendingPathComponent("notes.corrupt-\(stamp).json")
        try? FileManager.default.copyItem(at: dbURL, to: quarantine)
        NSLog("EdgeNotes: notes.json 无法解析，已另存为 \(quarantine.lastPathComponent)，尝试从备份恢复")

        let dailies = ((try? FileManager.default.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for candidate in [backupURL] + dailies {
            if let db = Self.decode(at: candidate) {
                apply(db)
                NSLog("EdgeNotes: 已从 \(candidate.lastPathComponent) 恢复")
                persistNow(reason: "restore-from-backup")
                return true
            }
        }
        loadFailure = "数据文件无法读取，已另存为 \(quarantine.lastPathComponent)。为避免覆盖，本次不会保存任何改动。"
        return true
    }

    private func apply(_ db: NotesDatabase) {
        notes = db.notes.sorted { $0.updatedAt > $1.updatedAt }
        trash = db.trash
        versions = db.versions
    }

    private static func decode(at url: URL) -> NotesDatabase? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        if let db = try? decoder.decode(NotesDatabase.self, from: data) { return db }
        if let legacy = try? decoder.decode([Note].self, from: data) {
            return NotesDatabase(notes: legacy, trash: [], versions: [], schemaVersion: NotesDatabase.currentSchema)
        }
        if let lite = try? decoder.decode([LegacyNote].self, from: data) {
            return NotesDatabase(notes: lite.map(\.upgraded), trash: [], versions: [], schemaVersion: NotesDatabase.currentSchema)
        }
        return nil
    }

    private static func fileStamp() -> String {
        ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }

    private struct LegacyNote: Codable {
        var id: UUID
        var title: String
        var body: String
        var updatedAt: Date
        var createdAt: Date
        var upgraded: Note {
            Note(id: id, title: title, body: body, updatedAt: updatedAt, createdAt: createdAt)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persistNow(reason: "debounce")
        }
    }

    /// 旧版本每次按键写的崩溃草稿：若比主库新则采用一次，然后删除（新版本不再写它）
    private func recoverCrashDraftIfNeeded() {
        guard FileManager.default.fileExists(atPath: crashURL.path) else { return }
        let crashDate = (try? FileManager.default.attributesOfItem(atPath: crashURL.path)[.modificationDate] as? Date) ?? .distantPast
        let dbDate = (try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.modificationDate] as? Date) ?? .distantPast
        if crashDate > dbDate, let db = Self.decode(at: crashURL) {
            apply(db)
            loadFailure = nil
            persistNow(reason: "crash-recover")
        }
        try? FileManager.default.removeItem(at: crashURL)
    }

    private func persistNow(reason: String, synchronous: Bool = false) {
        guard loadFailure == nil else {
            NSLog("EdgeNotes: 跳过保存(\(reason)) — 数据文件读取失败，避免覆盖")
            return
        }
        // 值类型快照，编码与写盘放到后台队列
        let db = NotesDatabase(notes: notes, trash: trash, versions: versions, schemaVersion: NotesDatabase.currentSchema)
        let dbURL = dbURL, backupsDir = backupsDir
        let work = {
            do {
                Self.rotateDailyBackup(dbURL: dbURL, backupsDir: backupsDir)
                let data = try JSONEncoder().encode(db)
                try data.write(to: dbURL, options: .atomic)
            } catch {
                NSLog("EdgeNotes: 保存失败(\(reason)) — \(error.localizedDescription)")
            }
        }
        if synchronous { ioQueue.sync(execute: work) } else { ioQueue.async(execute: work) }
    }

    /// 每天第一次保存前，把当前主库复制成 Backups/notes-YYYY-MM-DD.json，保留最近若干天。
    nonisolated private static func rotateDailyBackup(dbURL: URL, backupsDir: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbURL.path) else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let today = backupsDir.appendingPathComponent("notes-\(f.string(from: Date())).json")
        guard !fm.fileExists(atPath: today.path) else { return }
        // 只备份能解析的文件，避免把坏数据轮换进备份
        guard let data = try? Data(contentsOf: dbURL),
              (try? JSONDecoder().decode(NotesDatabase.self, from: data)) != nil else { return }
        try? data.write(to: today, options: .atomic)
        let all = ((try? fm.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("notes-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(dailyBackupsKept) { try? fm.removeItem(at: old) }
    }

    func flush() {
        saveTask?.cancel()
        for (id, task) in versionTasks {
            task.cancel()
            snapshotVersionNow(noteID: id)
        }
        versionTasks.removeAll()
        persistNow(reason: "flush", synchronous: true)
    }
}
