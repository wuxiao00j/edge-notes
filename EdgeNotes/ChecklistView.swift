import SwiftUI

struct ChecklistItem: Identifiable, Equatable {
    let id: UUID
    var text: String
    var done: Bool
    var rawPrefix: String // "- [ ] " or "- [x] "
}

enum ChecklistParser {
    static func extract(from body: String) -> (before: String, items: [ChecklistItem], after: String) {
        let lines = body.components(separatedBy: "\n")
        var before: [String] = []
        var items: [ChecklistItem] = []
        var after: [String] = []
        var phase = 0 // 0 before, 1 list, 2 after
        for line in lines {
            if let item = parseItem(line) {
                if phase == 2 {
                    // new list after other content — treat as after block restart: append to items still
                    items.append(item)
                } else {
                    phase = 1
                    items.append(item)
                }
            } else if phase == 0 {
                before.append(line)
            } else if phase == 1 {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    continue
                } else {
                    phase = 2
                    after.append(line)
                }
            } else {
                after.append(line)
            }
        }
        return (before.joined(separator: "\n"), items, after.joined(separator: "\n"))
    }

    static func parseItem(_ line: String) -> ChecklistItem? {
        let trimmed = line
        if trimmed.contains("- [ ]") {
            let text = trimmed.replacingOccurrences(of: "- [ ]", with: "").trimmingCharacters(in: .whitespaces)
            return ChecklistItem(id: UUID(), text: text, done: false, rawPrefix: "- [ ] ")
        }
        if trimmed.contains("- [x]") || trimmed.contains("- [X]") {
            let text = trimmed
                .replacingOccurrences(of: "- [x]", with: "")
                .replacingOccurrences(of: "- [X]", with: "")
                .trimmingCharacters(in: .whitespaces)
            return ChecklistItem(id: UUID(), text: text, done: true, rawPrefix: "- [x] ")
        }
        return nil
    }

    static func rebuild(before: String, items: [ChecklistItem], after: String) -> String {
        let open = items.filter { !$0.done }
        let done = items.filter { $0.done }
        let ordered = open + done
        let listLines = ordered.map { ($0.done ? "- [x] " : "- [ ] ") + $0.text }
        var parts: [String] = []
        if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || before.contains("\n") {
            parts.append(before)
        } else if !before.isEmpty {
            parts.append(before)
        }
        if !listLines.isEmpty {
            parts.append(listLines.joined(separator: "\n"))
        }
        if !after.isEmpty {
            parts.append(after)
        }
        return parts.joined(separator: "\n")
    }
}

struct ChecklistBlockView: View {
    @Binding var bodyText: String
    var onChange: () -> Void
    @State private var items: [ChecklistItem] = []
    @State private var before = ""
    @State private var after = ""
    @State private var syncing = false

    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("待办（拖拽排序 · 完成沉底）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    List {
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Button {
                                    toggle(item.id)
                                } label: {
                                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(item.done ? .green : .secondary)
                                }
                                .buttonStyle(.plain)
                                Text(item.text.isEmpty ? "（空）" : item.text)
                                    .strikethrough(item.done)
                                    .foregroundStyle(item.done ? .secondary : .primary)
                                    .font(.system(size: 12))
                            }
                        }
                        .onMove(perform: move)
                    }
                    .frame(minHeight: CGFloat(min(180, max(44, items.count * 28))))
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .onAppear { reloadFromBody() }
        .onChange(of: bodyText) { _, _ in
            if !syncing { reloadFromBody() }
        }
    }

    private func reloadFromBody() {
        let parsed = ChecklistParser.extract(from: bodyText)
        before = parsed.before
        after = parsed.after
        // Keep stable ids when text/done match by index order where possible
        items = parsed.items
    }

    private func toggle(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].done.toggle()
        commit()
    }

    private func move(from: IndexSet, to: Int) {
        items.move(fromOffsets: from, toOffset: to)
        commit()
    }

    private func commit() {
        syncing = true
        // sink done to bottom after any change
        let open = items.filter { !$0.done }
        let done = items.filter { $0.done }
        items = open + done
        bodyText = ChecklistParser.rebuild(before: before, items: items, after: after)
        onChange()
        syncing = false
    }
}
