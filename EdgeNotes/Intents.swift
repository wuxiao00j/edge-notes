import AppIntents
import AppKit

/// 快捷指令 / Siri：新建便签、挂剪贴板、打开全部便签、搜索
struct NewNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "新建便签"
    static var description = IntentDescription("新建一条便签，可选择直接挂到挂绳上。")

    @Parameter(title: "内容")
    var text: String

    @Parameter(title: "挂到挂绳", default: true)
    var hangOnLine: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let store = AppDelegate.current?.store else { throw IntentError.notReady }
        if hangOnLine {
            store.hangText(text)
            ClotheslineController.shared.flash()
        } else {
            store.addNote(body: text, select: false)
        }
        return .result(dialog: "已新建便签")
    }
}

struct HangClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "把剪贴板挂到挂绳"
    static var description = IntentDescription("把当前剪贴板里的文字、链接、图片或文件挂到挂绳上。")

    @MainActor
    func perform() async throws -> some IntentResult {
        ClotheslineController.shared.hangClipboard()
        return .result()
    }
}

struct OpenNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "打开全部便签"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotesWindowController.shared.show()
        return .result()
    }
}

struct SearchNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "搜索便签"
    static var description = IntentDescription("按关键词（支持拼音、首字母）搜索便签，返回匹配的便签内容。")

    @Parameter(title: "关键词")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        guard let store = AppDelegate.current?.store else { throw IntentError.notReady }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hits = store.activeNotes.filter { q.isEmpty || store.matches($0, query: q) }
        return .result(value: hits.map { note in
            let t = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? note.body : t + "\n" + note.body
        })
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    var localizedStringResource: LocalizedStringResource { "贴边便签还没准备好，请稍后再试" }
}

struct EdgeNotesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: HangClipboardIntent(), phrases: ["用\(.applicationName)把剪贴板挂上绳"], shortTitle: "剪贴板挂上绳", systemImageName: "paperclip")
        AppShortcut(intent: OpenNotesIntent(), phrases: ["打开\(.applicationName)"], shortTitle: "全部便签", systemImageName: "note.text")
        AppShortcut(intent: NewNoteIntent(), phrases: ["用\(.applicationName)新建便签"], shortTitle: "新建便签", systemImageName: "square.and.pencil")
    }
}
