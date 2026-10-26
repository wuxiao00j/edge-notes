import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: NoteStore
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var bridge = EditorBridge()
    @State private var draftTitle = ""
    @State private var draftBody = ""
    @State private var syncing = false
    @State private var isEditing = true
    @State private var tagDraft = ""
    @State private var showVersions = false
    @State private var showReminder = false

    var body: some View {
        VStack(spacing: 0) {
            StickyHeaderBar(
                title: "贴边便签",
                color: .glass,
                isEditing: isEditing,
                isAlwaysOnTop: settings.isAlwaysOnTop,
                onTogglePin: {
                    EdgePanelController.shared.setAlwaysOnTop(!settings.isAlwaysOnTop)
                },
                onToggleEdit: { beginEditing() },
                onNew: { createInSidebar() },
                onCollapse: { EdgePanelController.shared.collapse(animated: true) },
                onToggleSidebar: { settings.setSidebarHidden(!settings.sidebarHidden) },
                sidebarHidden: settings.sidebarHidden,
                // 左上角红点：只关闭侧栏，不退出 App
                onClose: { EdgePanelController.shared.collapse(animated: true) },
                onPrivacyQuickHide: {
                    settings.setPrivacyHideBodies(!settings.privacyHideBodies)
                },
                privacyOn: settings.privacyHideBodies,
                dragEnabled: true
            )

            Divider().opacity(0.3)
            toolbarRow
            Divider().opacity(0.25)

            HStack(spacing: 0) {
                if !settings.sidebarHidden {
                    noteList.frame(width: 150)
                    Divider().opacity(0.3)
                }
                editorColumn
            }
        }
        .background(
            // 主面板始终磨玻璃本色；贴纸色仅影响独立弹窗
            FrostedPanelBackground(tint: .glass)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .padding(6)
        .onAppear {
            pull()
            bridge.onURLTitle = { title, _ in
                // set via Notification to avoid capturing mutating state awkwardly — handled below
                NotificationCenter.default.post(name: .edgeNotesURLTitle, object: nil, userInfo: ["title": title])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .edgeNotesURLTitle)) { note in
            guard let title = note.userInfo?["title"] as? String else { return }
            if draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draftTitle = title
                commit()
            }
        }
        .onChange(of: store.selectedNoteID) { _, _ in
            isEditing = true
            pull()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                EdgePanelController.shared.makeKeyForEditing()
                bridge.focus()
            }
        }
        .sheet(isPresented: $showVersions) { versionsSheet }
        .sheet(isPresented: $showReminder) {
            if let id = store.selectedNoteID {
                ReminderEditor(noteID: id)
                    .environmentObject(store)
                    .padding()
                    .frame(width: 360)
            }
        }
    }

    private var toolbarRow: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { settings.mainViewMode },
                set: { settings.setMainViewMode($0) }
            )) {
                ForEach(MainViewMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)

            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索…", text: $store.searchQuery)
                .textFieldStyle(.plain)

            Menu {
                Button(store.showArchived ? "隐藏归档" : "显示归档") { store.showArchived.toggle() }
                Button(store.showTrash ? "隐藏回收站" : "回收站 (\(store.trash.count))") { store.showTrash.toggle() }
                Divider()
                Button("导出 Markdown…") { export(.markdown) }
                Button("导出 TXT…") { export(.txt) }
                Button("导出 JSON…") { export(.json) }
                Button("手动备份…") { backup() }
                Divider()
                Button("在 Finder 显示数据目录") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: store.dataDirectoryPath))
                }
                if !SelectionCapture.accessibilityTrusted() {
                    Button("授予辅助功能（选区贴入）…") {
                        SelectionCapture.promptAccessibilityIfNeeded()
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("更多操作：归档、回收站、导出、备份")
            .accessibilityLabel("更多操作")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .font(.system(size: 12))
    }

    private var listNotes: [Note] {
        if settings.mainViewMode == .desktop {
            return store.visibleNotes.filter { $0.pinnedToDesktop }
        }
        return store.visibleNotes
    }

    private var noteList: some View {
        Group {
            if store.showTrash {
                List {
                    ForEach(store.trash) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.note.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text("删除于 \(entry.deletedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("恢复") { store.restoreFromTrash(id: entry.note.id) }
                            Button("彻底删除", role: .destructive) { store.purgeTrash(id: entry.note.id) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if settings.mainViewMode == .desktop {
                        Text("桌面贴 · \(listNotes.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 6)
                        if listNotes.isEmpty {
                            Text("还没有桌面贴纸\n在便签里点「弹窗」即可")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(10)
                        }
                    }
                    List(selection: Binding(
                        get: { store.selectedNoteID },
                        set: { if let id = $0 { store.select(id) } }
                    )) {
                        ForEach(listNotes) { note in
                            HStack(spacing: 6) {
                                Circle().fill(note.color.normalized == .glass ? Color.secondary.opacity(0.35) : note.color.accent).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        if note.isLocked { Image(systemName: "lock.fill").font(.system(size: 9)) }
                                        if note.reminderAt != nil { Image(systemName: "bell.fill").font(.system(size: 9)) }
                                        Text(note.displayTitle)
                                            .font(.system(size: 12, weight: .medium))
                                            .lineLimit(1)
                                    }
                                    Text(previewText(for: note))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .tag(note.id)
                            .opacity(note.isArchived ? 0.55 : 1)
                            .contextMenu {
                                Button("在新窗口打开") {
                                    NoteWindowManager.shared.open(noteID: note.id, store: store)
                                }
                                Button(note.onLine ? "从挂绳取下" : "挂到挂绳") {
                                    if note.onLine { store.takeOffLine(id: note.id) } else { store.hangOnLine(id: note.id) }
                                }
                                Button(note.isArchived ? "取消归档" : "归档") { store.toggleArchive(id: note.id) }
                                Button(note.isLocked ? "解锁" : "锁定") {
                                    if note.isLocked {
                                        NoteLock.unlock(note.id, store: store)
                                    } else {
                                        store.setLocked(id: note.id, true)
                                    }
                                }
                                Button("删除", role: .destructive) {
                                    store.softDelete(id: note.id)
                                    pull()
                                }
                            }
                        }
                        .onDelete { idxs in
                            for i in idxs { store.softDelete(id: listNotes[i].id) }
                            pull()
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }

    private func previewText(for note: Note) -> String {
        var body = note.body
        if let re = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(attachments\/[^)]+\)"#) {
            body = re.stringByReplacingMatches(
                in: body,
                range: NSRange(location: 0, length: (body as NSString).length),
                withTemplate: "[图片]"
            )
        }
        let flat = body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.isEmpty { return "空便签" }
        return flat
    }

    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.showTrash {
                Text("回收站 — 右键可恢复").foregroundStyle(.secondary).padding()
                Spacer()
            } else if store.selectedNote == nil {
                VStack(spacing: 10) {
                    Text(settings.mainViewMode == .desktop ? "选择一张桌面贴，或切到「全部列表」" : "还没有便签")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("新建一条") { createInSidebar() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NoteEditorPane(
                    title: $draftTitle,
                    bodyText: $draftBody,
                    color: store.selectedNote?.color ?? .glass,
                    isEditing: isEditing,
                    isLocked: store.selectedNote?.isLocked ?? false,
                    privacyHide: settings.privacyHideBodies,
                    onChange: commit,
                    bridge: bridge
                )
                if isEditing {
                    metaBar
                }
                footerBar
            }
        }
        .padding(12)
    }

    private var metaBar: some View {
        ViewThatFits(in: .horizontal) {
            metaBarWide
            metaBarNarrow
        }
    }

    private var metaColorChips: some View {
        ColorChipRow(selected: store.selectedNote?.color ?? .glass) { c in
            if let id = store.selectedNoteID { store.setColor(id: id, c) }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var metaTagField: some View {
        TextField("标签", text: $tagDraft)
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .onSubmit { applyTags() }
            .frame(minWidth: 64, idealWidth: 100, maxWidth: 120)
    }

    @ViewBuilder
    private var metaReminderChip: some View {
        if let note = store.selectedNote, let at = note.reminderAt {
            HStack(spacing: 4) {
                Image(systemName: "bell.fill").font(.system(size: 9))
                Text(at.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10))
                    .lineLimit(1)
                Button {
                    store.setReminder(id: note.id, at: nil, repeatDays: nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .help("清除定时提醒")
                .accessibilityLabel("清除定时提醒")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.orange.opacity(0.18)))
            .foregroundStyle(.orange)
            .help("点击铃铛旁时间可改提醒；点 × 清除")
            .onTapGesture { showReminder = true }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var metaReminderButton: some View {
        Button {
            showReminder = true
        } label: {
            Text(store.selectedNote?.reminderAt == nil ? "提醒" : "改提醒")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help("设置或修改定时提醒")
        .fixedSize(horizontal: true, vertical: false)
    }

    private var metaVersionButton: some View {
        Button {
            showVersions = true
        } label: {
            Text("版本")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help("查看历史版本")
        .fixedSize(horizontal: true, vertical: false)
    }

    /// 侧栏关闭、编辑区够宽：一行排开
    private var metaBarWide: some View {
        HStack(spacing: 10) {
            metaColorChips
            metaTagField
            metaReminderChip
            metaReminderButton
            metaVersionButton
            Spacer(minLength: 4)
        }
    }

    /// 侧栏打开、编辑区变窄：色点独占一行，其余折到第二行 / 更多菜单
    private var metaBarNarrow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                metaColorChips
                Spacer(minLength: 0)
                metaReminderChip
                Button { showReminder = true } label: {
                    Image(systemName: store.selectedNote?.reminderAt == nil ? "bell" : "bell.badge")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("设置或修改定时提醒")
                Button { showVersions = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("查看历史版本")
            }
            metaTagField
                .frame(maxWidth: .infinity)
        }
    }

    private var footerBar: some View {
        HStack {
            Text("共 \(store.activeNotes.count) 条 · 输入即保存")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                if let id = store.selectedNoteID {
                    NoteWindowManager.shared.open(noteID: id, store: store)
                    settings.setMainViewMode(.desktop)
                }
            } label: {
                Label("弹窗", systemImage: "macwindow").font(.caption)
            }
            .buttonStyle(.borderless)
            .help("在独立贴纸窗口打开（计入桌面贴）")

            Button {
                guard let note = store.selectedNote else { return }
                if note.onLine { store.takeOffLine(id: note.id) } else { store.hangOnLine(id: note.id) }
            } label: {
                Label(store.selectedNote?.onLine == true ? "取下" : "挂绳", systemImage: "paperclip").font(.caption)
            }
            .buttonStyle(.borderless)
            .help("挂到屏幕顶部的挂绳上 / 从挂绳取下")

            Button {
                store.deleteSelected()
                pull()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private var versionsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("历史版本").font(.headline)
            if let id = store.selectedNoteID {
                let list = store.versions(for: id)
                if list.isEmpty {
                    Text("暂无版本快照（编辑约 8 秒后自动记录）").foregroundStyle(.secondary)
                } else {
                    List(list) { v in
                        VStack(alignment: .leading) {
                            Text(v.savedAt.formatted()).font(.caption)
                            Text(v.title.isEmpty ? String(v.body.prefix(60)) : String(v.title.prefix(40)))
                                .lineLimit(2)
                        }
                        .contextMenu {
                            Button("恢复此版本") {
                                store.restoreVersion(v)
                                pull()
                                showVersions = false
                            }
                        }
                    }
                }
            }
            Button("关闭") { showVersions = false }
        }
        .padding()
        .frame(width: 360, height: 320)
    }

    private func createInSidebar() {
        store.addNote(select: true)
        pull()
        beginEditing(forceOn: true)
        EdgePanelController.shared.expand(animated: true)
    }

    private func beginEditing(forceOn: Bool = false) {
        // 锁定的便签需先验证身份解锁，不再点「编辑」就静默解锁
        if let note = store.selectedNote, note.isLocked, !isEditing || forceOn {
            NoteLock.unlock(note.id, store: store) { ok in
                if ok { beginEditing(forceOn: true) }
            }
            return
        }
        if forceOn { isEditing = true } else { isEditing.toggle() }
        if isEditing {
            EdgePanelController.shared.makeKeyForEditing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                bridge.focus()
            }
        }
    }

    private func pull() {
        syncing = true
        defer { syncing = false }
        if let note = store.selectedNote {
            draftTitle = note.title
            draftBody = note.body
            tagDraft = note.tags.joined(separator: ", ")
        } else {
            draftTitle = ""; draftBody = ""; tagDraft = ""
        }
    }

    private func commit() {
        guard !syncing, let id = store.selectedNoteID else { return }
        store.update(id: id) {
            $0.title = draftTitle
            $0.body = draftBody
        }
    }

    private func applyTags() {
        guard let id = store.selectedNoteID else { return }
        let tags = tagDraft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        store.setTags(id: id, tags)
    }

    private func export(_ format: NoteStore.ExportFormat) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        switch format {
        case .json:
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "edgenotes.json"
        case .txt:
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = "edgenotes.txt"
        case .markdown:
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "edgenotes.md"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.exportNotes(format: format, to: url)
    }

    private func backup() {
        if let url = try? store.manualBackup() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
