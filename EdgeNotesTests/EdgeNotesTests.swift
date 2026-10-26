import XCTest
@testable import EdgeNotes

/// 每个测试一个临时数据目录，绝不碰 ~/Library/Application Support/EdgeNotes
@MainActor
class TempDirTestCase: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("EdgeNotesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func write(_ text: String, to name: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    static let validDB = #"{"notes":[{"id":"11111111-1111-1111-1111-111111111111","title":"我的数据","body":"x"}],"trash":[],"versions":[],"schemaVersion":4}"#
}

// MARK: - 存储：加载、损坏恢复、备份

@MainActor
final class NoteStoreLoadingTests: TempDirTestCase {
    func testFreshInstallGetsWelcomeNote() {
        let store = NoteStore(directory: dir)
        store.flush()
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.title, L("欢迎使用贴边便签"))
        XCTAssertTrue(exists("notes.json"))
    }

    func testLoadsExistingData() throws {
        try write(Self.validDB, to: "notes.json")
        let store = NoteStore(directory: dir)
        XCTAssertNil(store.loadFailure)
        XCTAssertEqual(store.notes.map(\.title), ["我的数据"])
    }

    func testLegacyArrayFormatLoads() throws {
        try write(#"[{"id":"22222222-2222-2222-2222-222222222222","title":"旧格式","body":"b"}]"#, to: "notes.json")
        let store = NoteStore(directory: dir)
        XCTAssertEqual(store.notes.map(\.title), ["旧格式"])
    }

    /// v0.4 的数据丢失 bug：解析失败时不能用欢迎便签覆盖
    func testCorruptFileWithoutBackupIsNeverOverwritten() throws {
        let corrupt = #"{"notes":[{"id":"bad"}],"trash":[],"versions":[],"schemaVersion":3}"#
        try write(corrupt, to: "notes.json")
        let store = NoteStore(directory: dir)
        XCTAssertNotNil(store.loadFailure)
        XCTAssertTrue(store.notes.isEmpty, "不应出现欢迎便签")
        store.addNote(body: "试图写入")
        store.flush()
        XCTAssertEqual(try read("notes.json"), corrupt, "原文件必须一字不改")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("notes.corrupt-") }, "应另存一份损坏文件")
    }

    func testCorruptFileRestoresFromLaunchSnapshot() throws {
        try write("garbage{", to: "notes.json")
        try write(Self.validDB, to: "notes.backup.json")
        let store = NoteStore(directory: dir)
        store.flush()
        XCTAssertNil(store.loadFailure)
        XCTAssertEqual(store.notes.map(\.title), ["我的数据"])
        XCTAssertTrue(try read("notes.json").contains("我的数据"))
        XCTAssertTrue(try read("notes.backup.json").contains("我的数据"), "好的备份不能被坏文件覆盖")
    }

    func testCorruptFileRestoresFromDailyBackup() throws {
        try write("garbage{", to: "notes.json")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Backups"), withIntermediateDirectories: true)
        try write(Self.validDB, to: "Backups/notes-2026-01-01.json")
        let store = NoteStore(directory: dir)
        XCTAssertNil(store.loadFailure)
        XCTAssertEqual(store.notes.map(\.title), ["我的数据"])
    }

    func testExpiredTrashIsPurged() throws {
        try write(#"{"notes":[],"trash":[{"note":{"id":"33333333-3333-3333-3333-333333333333","body":"old"},"deletedAt":-100000000},{"note":{"id":"44444444-4444-4444-4444-444444444444","body":"new"},"deletedAt":\#(Date().timeIntervalSinceReferenceDate)}],"versions":[],"schemaVersion":4}"#, to: "notes.json")
        let store = NoteStore(directory: dir)
        XCTAssertEqual(store.trash.map(\.note.body), ["new"])
    }

    func testDailyBackupRotationKeepsSevenAndSkipsCorrupt() throws {
        let backups = dir.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        for day in 1...9 {
            try write(Self.validDB, to: String(format: "Backups/notes-2026-01-%02d.json", day))
        }
        let db = dir.appendingPathComponent("notes.json")

        // 坏文件不轮换进备份
        try write("garbage{", to: "notes.json")
        NoteStore.rotateDailyBackup(dbURL: db, backupsDir: backups)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).count, 9)

        try write(Self.validDB, to: "notes.json")
        NoteStore.rotateDailyBackup(dbURL: db, backupsDir: backups)
        let names = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
        XCTAssertEqual(names.count, NoteStore.dailyBackupsKept)
        XCTAssertFalse(names.contains("notes-2026-01-01.json"), "最旧的应被删掉")
    }

    func testAttachmentsFollowStoreDirectory() {
        _ = NoteStore(directory: dir)
        XCTAssertEqual(AttachmentStore.directory.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
    }
}

// MARK: - 挂绳

@MainActor
final class ClotheslineStoreTests: TempDirTestCase {
    func testFileIsReferencedNotCopied() throws {
        let file = dir.appendingPathComponent("报告.pdf")
        try "pdf".write(to: file, atomically: true, encoding: .utf8)
        let store = NoteStore(directory: dir)
        let note = store.addLineFile(file)
        XCTAssertEqual(note.fileLink?.standardizedFileURL, file.standardizedFileURL)
        XCTAssertEqual(note.title, "报告.pdf")
        XCTAssertNotNil(note.fileBookmark)
        let attachments = (try? FileManager.default.contentsOfDirectory(atPath: AttachmentStore.directory.path)) ?? []
        XCTAssertTrue(attachments.isEmpty, "文件不应被复制进附件目录")
    }

    func testMovedFileIsFoundByBookmark() throws {
        let file = dir.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let store = NoteStore(directory: dir)
        let note = store.addLineFile(file)
        let moved = dir.appendingPathComponent("b.txt")
        try FileManager.default.moveItem(at: file, to: moved)
        XCTAssertEqual(store.resolveFile(for: note.id)?.lastPathComponent, "b.txt")
        XCTAssertEqual(store.note(id: note.id)?.title, "b.txt")
    }

    func testAutoRemoveAfterDays() {
        let store = NoteStore(directory: dir)
        let old = store.addLineNote(body: "old")
        let fresh = store.addLineNote(body: "fresh")
        store.update(id: old.id, bumpModified: false) { $0.lineHungAt = Date().addingTimeInterval(-4 * 86400) }
        store.expireLineNotes(afterDays: 3)
        XCTAssertFalse(store.note(id: old.id)!.onLine)
        XCTAssertTrue(store.note(id: fresh.id)!.onLine)
        store.expireLineNotes(afterDays: 0)
        XCTAssertTrue(store.note(id: fresh.id)!.onLine, "0 = 不自动取下")
    }

    func testHangTextDetectsLinks() {
        let store = NoteStore(directory: dir)
        store.hangText("https://www.apple.com/")
        let link = store.lineNotes.first { $0.webLink != nil }
        XCTAssertEqual(link?.title, "apple.com")
    }
}

// MARK: - 纯逻辑

final class ChecklistTests: XCTestCase {
    func testParseOnlyAtLineStart() {
        XCTAssertEqual(Checklist.parse("- [ ] 买菜")?.done, false)
        XCTAssertEqual(Checklist.parse("- [x] 买菜")?.done, true)
        XCTAssertEqual(Checklist.parse("- [X] 买菜")?.done, true)
        XCTAssertEqual(Checklist.parse("  - [ ] 缩进")?.indent, "  ")
        XCTAssertNil(Checklist.parse("说明：- [ ] 不是待办"))
        XCTAssertNil(Checklist.parse("普通一行"))
    }

    @MainActor
    func testSinkKeepsBlankLinesAndOtherContent() {
        let body = "标题\n- [x] a\n- [ ] b\n\n- [x] c\n- [ ] d\n结尾"
        XCTAssertEqual(NoteStore.sinkCompletedChecklists(body), "标题\n- [ ] b\n- [x] a\n\n- [ ] d\n- [x] c\n结尾")
    }
}

final class ReminderTests: XCTestCase {
    @MainActor
    func testRepeatKeepsTimeOfDay() {
        let cal = Calendar.current
        let at = cal.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 9, minute: 0))!
        let now = cal.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 9, minute: 47))!
        let next = ReminderManager.nextOccurrence(after: at, everyDays: 1, now: now)
        XCTAssertEqual(cal.component(.hour, from: next), 9)
        XCTAssertEqual(cal.component(.minute, from: next), 0)
        XCTAssertEqual(cal.component(.day, from: next), 2)
    }

    @MainActor
    func testRepeatSkipsMissedPeriods() {
        let cal = Calendar.current
        let at = cal.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 9))!
        let now = cal.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 12))!
        let next = ReminderManager.nextOccurrence(after: at, everyDays: 7, now: now)
        XCTAssertEqual(cal.component(.day, from: next), 22)
        XCTAssertGreaterThan(next, now)
    }
}

final class RopeLayoutTests: XCTestCase {
    private func items(_ positions: [CGFloat], width: CGFloat = RopeLayout.cardWidth) -> [RopeLayout.Item] {
        positions.map { RopeLayout.Item(id: UUID(), position: $0, width: width) }
    }

    func testCardsThatFitKeepFullSizeAndDontOverlap() {
        let r = RopeLayout.layout(items([0.1, 0.12, 0.5]), lo: 0, hi: 1000)
        XCTAssertEqual(r.scale, 1)
        let xs = r.centers.values.sorted()
        for i in 1..<xs.count { XCTAssertGreaterThanOrEqual(xs[i] - xs[i - 1], RopeLayout.cardWidth - 0.01) }
    }

    func testManyCardsShrinkThenStackWithinBounds() {
        let r = RopeLayout.layout(items(Array(repeating: 0.5, count: 30)), lo: 0, hi: 1000)
        XCTAssertEqual(r.scale, RopeLayout.minScale)
        for x in r.centers.values { XCTAssertTrue((0 - 0.01)...(1000 + 0.01) ~= x) }
    }

    func testSingleWideCardStaysInsideEdges() {
        let wide = RopeLayout.Item(id: UUID(), position: 1, width: 252)
        let r = RopeLayout.layout([wide], lo: 100, hi: 900, edges: 20...980)
        XCTAssertLessThanOrEqual(r.centers[wide.id]! + 126, 980 + 0.01)
    }

    func testWideCardStaysInsideEdges() {
        let wide = RopeLayout.Item(id: UUID(), position: 1, width: 252)
        let r = RopeLayout.layout(items([0.2]) + [wide], lo: 100, hi: 900, edges: 20...980)
        let x = r.centers[wide.id]!
        XCTAssertLessThanOrEqual(x + 252 * r.scale / 2, 980 + 0.01)
    }
}

final class NoteParsingTests: XCTestCase {
    func testWebLinkAndFileLink() {
        XCTAssertNotNil(Note(body: "https://example.com/a").webLink)
        XCTAssertNil(Note(body: "看 https://example.com").webLink)
        XCTAssertNotNil(Note(body: "file:///tmp/a.pdf").fileLink)
        XCTAssertNil(Note(body: "file:///tmp/a.pdf").webLink)
    }

    func testDisplayTitleStripsOnlyLeadingMarkers() {
        XCTAssertEqual(Note(body: "- [ ] 买菜").displayTitle, "买菜")
        XCTAssertEqual(Note(body: "价格 3 - 5 元").displayTitle, "价格 3 - 5 元")
    }

    func testPinyin() {
        let p = Pinyin.of("买菜 list")
        XCTAssertEqual(p.full, "maicailist")
        XCTAssertEqual(p.initials, "mcl")
    }
}

@MainActor
final class SearchTests: TempDirTestCase {
    func testPinyinAndInitialsMatch() {
        let store = NoteStore(directory: dir)
        let note = store.addNote(title: "买菜", body: "鸡蛋")
        XCTAssertTrue(store.matches(note, query: "mc"))
        XCTAssertTrue(store.matches(note, query: "maicai"))
        XCTAssertTrue(store.matches(note, query: "鸡蛋"))
        XCTAssertFalse(store.matches(note, query: "xyz"))
    }
}

@MainActor
final class ClipboardHistoryTests: XCTestCase {
    func testDuplicatesMoveToTopAndLimitIsKept() {
        let h = ClipboardHistory()
        h.insert(.init(kind: .text, text: "a"))
        h.insert(.init(kind: .text, text: "b"))
        h.insert(.init(kind: .text, text: "a"))
        XCTAssertEqual(h.entries.map(\.text), ["a", "b"])
        for i in 0..<(ClipboardHistory.maxEntries + 5) { h.insert(.init(kind: .text, text: "\(i)")) }
        XCTAssertEqual(h.entries.count, ClipboardHistory.maxEntries)
    }

    func testConcealedContentIsSkipped() {
        let pb = NSPasteboard(name: NSPasteboard.Name("EdgeNotesTests-\(UUID().uuidString)"))
        pb.clearContents()
        pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        pb.setString("secret", forType: .string)
        XCTAssertNil(ClipboardHistory.capture(pb, imagesDir: nil))
        pb.clearContents()
        pb.setString("hello", forType: .string)
        XCTAssertEqual(ClipboardHistory.capture(pb, imagesDir: nil)?.text, "hello")
        pb.releaseGlobally()
    }
}

// MARK: - 编辑器：Markdown 往返与列表编辑

@MainActor
final class EditorTests: XCTestCase {
    private func roundTrip(_ md: String) -> String {
        NoteBodyRendering.markdown(from: NoteBodyRendering.attributed(from: md))
    }

    /// 打开便签不能改动内容，否则会被当成修改（列表跳到最上面）
    func testMarkdownRoundTripIsStable() {
        let samples = [
            "普通一行",
            "- 项目\n- 第二项",
            "1. 一\n2. 二\n3. 三",
            "- [ ] 待办\n- [x] 完成",
            "- 外层\n  - 内层\n    - 更深",
            "**粗体** 和 [链接](https://example.com)",
            "标题\n\n- a\n\n正文",
            "末尾换行\n",
            "",
        ]
        for md in samples { XCTAssertEqual(roundTrip(md), md, "往返不稳定：\(md)") }
    }

    private func makeEditor(_ md: String) -> TypingTextView {
        let tv = TypingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        tv.isEditable = true
        tv.isRichText = true
        tv.allowsUndo = true
        tv.textStorage?.setAttributedString(NoteBodyRendering.attributed(from: md))
        return tv
    }

    private func md(_ tv: NSTextView) -> String { NoteBodyRendering.markdown(from: tv.attributedString()) }

    private func caretAtEnd(_ tv: NSTextView) { tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0)) }

    func testToggleBulletOnCurrentLineWithoutPlaceholder() {
        let tv = makeEditor("买菜")
        caretAtEnd(tv)
        tv.toggleList(.bullet)
        XCTAssertEqual(md(tv), "- 买菜")
        tv.toggleList(.bullet)
        XCTAssertEqual(md(tv), "买菜", "再点一次取消")
    }

    func testToggleTodoAndNumberOnSelectedLines() {
        let tv = makeEditor("a\nb\nc")
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        tv.toggleList(.todo(false))
        XCTAssertEqual(md(tv), "- [ ] a\n- [ ] b\n- [ ] c")
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        tv.toggleList(.number(1))
        XCTAssertEqual(md(tv), "1. a\n2. b\n3. c")
    }

    func testEnterContinuesListAndExitsOnEmptyItem() {
        let tv = makeEditor("1. 一")
        caretAtEnd(tv)
        tv.insertNewline(nil)
        tv.insertText("二", replacementRange: tv.selectedRange())
        XCTAssertEqual(md(tv), "1. 一\n2. 二")
        tv.insertNewline(nil)
        tv.insertNewline(nil)
        XCTAssertEqual(md(tv), "1. 一\n2. 二\n", "空项回车结束列表")
    }

    func testEnterOnTodoMakesUncheckedTodo() {
        let tv = makeEditor("- [x] 完成")
        caretAtEnd(tv)
        tv.insertNewline(nil)
        tv.insertText("新的", replacementRange: tv.selectedRange())
        XCTAssertEqual(md(tv), "- [x] 完成\n- [ ] 新的")
    }

    func testBackspaceAfterMarkerRemovesMarker() {
        let tv = makeEditor("- 项目")
        let start = NoteBodyRendering.paragraphInfo(in: tv.textStorage!, paragraph: NSRange(location: 0, length: (tv.string as NSString).length)).content.location
        tv.setSelectedRange(NSRange(location: start, length: 0))
        tv.deleteBackward(nil)
        XCTAssertEqual(md(tv), "项目")
    }

    func testTabIndentsAndShiftTabOutdents() {
        let tv = makeEditor("- a\n- b")
        caretAtEnd(tv)
        tv.insertTab(nil)
        XCTAssertEqual(md(tv), "- a\n  - b")
        tv.insertBacktab(nil)
        XCTAssertEqual(md(tv), "- a\n- b")
    }

    func testTypingShortcutsCreateLists() {
        let tv = makeEditor("")
        for ch in ["-", " "] { tv.insertText(ch, replacementRange: tv.selectedRange()) }
        tv.insertText("x", replacementRange: tv.selectedRange())
        XCTAssertEqual(md(tv), "- x")

        let todo = makeEditor("")
        for ch in ["[", "]", " "] { todo.insertText(ch, replacementRange: todo.selectedRange()) }
        todo.insertText("y", replacementRange: todo.selectedRange())
        XCTAssertEqual(md(todo), "- [ ] y")

        let num = makeEditor("")
        for ch in ["1", ".", " "] { num.insertText(ch, replacementRange: num.selectedRange()) }
        num.insertText("z", replacementRange: num.selectedRange())
        XCTAssertEqual(md(num), "1. z")
    }

    func testBoldTogglesOnSelection() {
        let tv = makeEditor("hello world")
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        tv.toggleBold()
        XCTAssertEqual(md(tv), "**hello** world")
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        tv.toggleBold()
        XCTAssertEqual(md(tv), "hello world", "再按一次取消粗体")
    }
}

@MainActor
final class SelectionOrderTests: TempDirTestCase {
    /// 点选便签（编辑器回填相同内容）不能改修改时间、不能重排
    func testNoOpUpdateDoesNotBumpModifiedTime() {
        let store = NoteStore(directory: dir)
        let note = store.addNote(title: "t", body: "b")
        let before = store.note(id: note.id)!.updatedAt
        store.update(id: note.id) { $0.title = "t"; $0.body = "b" }
        XCTAssertEqual(store.note(id: note.id)!.updatedAt, before)
    }

    func testPerCardSize() {
        let store = NoteStore(directory: dir)
        let note = store.addLineNote(body: "x")
        store.setLineCardSize(id: note.id, .large)
        XCTAssertEqual(store.note(id: note.id)?.lineCardSize, "large")
        store.setLineCardSize(id: note.id, nil)
        XCTAssertNil(store.note(id: note.id)?.lineCardSize)
    }
}

final class TiltTests: XCTestCase {
    @MainActor
    func testTiltIsVariedAndBounded() {
        let tilts = (0..<200).map { _ in ClotheslineView.tilt(for: UUID()) }
        XCTAssertTrue(tilts.allSatisfy { abs($0) >= 1.5 && abs($0) <= 7 })
        XCTAssertGreaterThan(tilts.filter { $0 > 0 }.count, 50)
        XCTAssertGreaterThan(tilts.filter { $0 < 0 }.count, 50)
        XCTAssertGreaterThan(Set(tilts.map { Int($0.rounded()) }).count, 8, "角度要分散")
    }
}
