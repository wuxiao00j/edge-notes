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
    private var saveTask: Task<Void, Never>?
    private var versionTask: Task<Void, Never>?
    private var lastVersionSnapshot: [UUID: String] = [:]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dir = support.appendingPathComponent("EdgeNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("notes.json")
        crashURL = dir.appendingPathComponent("crash-recovery.json")
        backupURL = dir.appendingPathComponent("notes.backup.json")

        load()
        recoverCrashDraftIfNeeded()

        if notes.isEmpty && trash.isEmpty {
            let welcome = Note(
                title: "欢迎使用贴边便签",
                body: """
                把鼠标移到屏幕右边缘的细条上，面板会滑出来。

                • ⌥⌘T 极速新建并开始输入
                • ⌥⌘N 显示/隐藏侧栏
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
            writeCrashDraft()
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

    func toggleLocked(id: UUID) {
        update(id: id) { $0.isLocked.toggle() }
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
        scheduleSave()
    }

    func emptyTrash() {
        trash.removeAll()
        scheduleSave()
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
        versionTask?.cancel()
        versionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
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
        persistNow(reason: "version")
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
        guard lineIndex >= 0, lineIndex < lines.count else { return }
        let line = lines[lineIndex]
        if line.contains("- [ ]") {
            lines[lineIndex] = line.replacingOccurrences(of: "- [ ]", with: "- [x]")
        } else if line.contains("- [x]") {
            lines[lineIndex] = line.replacingOccurrences(of: "- [x]", with: "- [ ]")
        }
        // completed sink to bottom among checklist lines
        update(id: noteID) { $0.body = Self.sinkCompletedChecklists(lines.joined(separator: "\n")) }
    }

    static func sinkCompletedChecklists(_ body: String) -> String {
        let lines = body.components(separatedBy: "\n")
        var head: [String] = []
        var open: [String] = []
        var done: [String] = []
        var tail: [String] = []
        var inList = false
        for line in lines {
            let isOpen = line.contains("- [ ]")
            let isDone = line.contains("- [x]")
            if isOpen || isDone {
                inList = true
                if isDone { done.append(line) } else { open.append(line) }
            } else if inList && line.trimmingCharacters(in: .whitespaces).isEmpty {
                // keep blank inside list zone as separator after reorder
                continue
            } else if inList {
                inList = false
                head.append(contentsOf: open + done)
                open = []; done = []
                tail.append(line)
            } else {
                head.append(line)
            }
        }
        if inList {
            head.append(contentsOf: open + done)
        }
        return (head + tail).joined(separator: "\n")
    }

    // MARK: - Export / Backup

    func exportNotes(format: ExportFormat, to url: URL) throws {
        let payload = visibleNotes.isEmpty ? notes : notes
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
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("backup-\(stamp).json")
        let db = NotesDatabase(notes: notes, trash: trash, versions: versions, schemaVersion: NotesDatabase.currentSchema)
        let data = try JSONEncoder().encode(db)
        try data.write(to: url, options: .atomic)
        return url
    }

    enum ExportFormat { case json, txt, markdown }

    // MARK: - Persistence

    private func load() {
        // Prefer main DB; migrate legacy [Note] array
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return }
        do {
            let data = try Data(contentsOf: dbURL)
            if let db = try? JSONDecoder().decode(NotesDatabase.self, from: data) {
                notes = db.notes.sorted { $0.updatedAt > $1.updatedAt }
                trash = db.trash
                versions = db.versions
            } else if let legacy = try? JSONDecoder().decode([Note].self, from: data) {
                notes = legacy
            } else if let legacyLite = try? JSONDecoder().decode([LegacyNote].self, from: data) {
                notes = legacyLite.map { $0.upgraded }
            }
        } catch {
            NSLog("EdgeNotes: 读取失败 — \(error.localizedDescription)")
            if FileManager.default.fileExists(atPath: backupURL.path),
               let data = try? Data(contentsOf: backupURL),
               let db = try? JSONDecoder().decode(NotesDatabase.self, from: data) {
                notes = db.notes
                trash = db.trash
                versions = db.versions
            }
        }
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
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persistNow(reason: "debounce")
        }
    }

    private func writeCrashDraft() {
        let db = NotesDatabase(notes: notes, trash: trash, versions: versions, schemaVersion: NotesDatabase.currentSchema)
        if let data = try? JSONEncoder().encode(db) {
            try? data.write(to: crashURL, options: .atomic)
        }
    }

    private func recoverCrashDraftIfNeeded() {
        guard FileManager.default.fileExists(atPath: crashURL.path) else { return }
        // If crash draft is newer than main DB, prefer it
        let crashDate = (try? FileManager.default.attributesOfItem(atPath: crashURL.path)[.modificationDate] as? Date) ?? .distantPast
        let dbDate = (try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.modificationDate] as? Date) ?? .distantPast
        if crashDate > dbDate, let data = try? Data(contentsOf: crashURL),
           let db = try? JSONDecoder().decode(NotesDatabase.self, from: data) {
            notes = db.notes
            trash = db.trash
            versions = db.versions
            persistNow(reason: "crash-recover")
        }
        try? FileManager.default.removeItem(at: crashURL)
    }

    private func persistNow(reason: String) {
        do {
            if FileManager.default.fileExists(atPath: dbURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
                try? FileManager.default.copyItem(at: dbURL, to: backupURL)
            }
            let db = NotesDatabase(notes: notes, trash: trash, versions: versions, schemaVersion: NotesDatabase.currentSchema)
            let data = try JSONEncoder().encode(db)
            try data.write(to: dbURL, options: .atomic)
            try? FileManager.default.removeItem(at: crashURL)
        } catch {
            NSLog("EdgeNotes: 保存失败(\(reason)) — \(error.localizedDescription)")
        }
    }

    func flush() {
        saveTask?.cancel()
        persistNow(reason: "flush")
    }
}
