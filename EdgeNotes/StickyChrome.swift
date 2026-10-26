import SwiftUI
import AppKit

struct StickyHeaderBar: View {
    let title: String
    let color: NoteColor
    var isEditing: Bool
    var isAlwaysOnTop: Bool
    var onTogglePin: () -> Void
    var onToggleEdit: () -> Void
    var onNew: (() -> Void)? = nil
    var onCollapse: (() -> Void)? = nil
    var onToggleSidebar: (() -> Void)? = nil
    var sidebarHidden: Bool = false
    var onClose: (() -> Void)? = nil
    var onPrivacyQuickHide: (() -> Void)? = nil
    var privacyOn: Bool = false
    var dragEnabled: Bool = true

    var body: some View {
        ZStack {
            if dragEnabled {
                PanelDragHandle()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 2) {
                if let onClose {
                    Button(action: onClose) {
                        Circle().fill(Color.red.opacity(0.85)).frame(width: 10, height: 10)
                    }
                    .buttonStyle(.plain)
                    .help(L("关闭（不退出）"))
                    .accessibilityLabel(L("关闭窗口"))
                    .padding(.trailing, 4)
                }

                Circle()
                    .fill(color.normalized == .glass ? Color.primary.opacity(0.25) : color.accent.opacity(0.9))
                    .frame(width: 8, height: 8)
                    .allowsHitTesting(false)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .allowsHitTesting(false)

                Spacer(minLength: 6)
                    .allowsHitTesting(false)

                // 主操作：仅图标 + 中文 tooltip（避免 Label 文字被挤成省略号）
                HStack(spacing: 14) {
                    Button(action: onToggleEdit) {
                        Image(systemName: isEditing ? "checkmark.circle" : "pencil")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(isEditing ? L("完成编辑，回到预览") : L("开始编辑正文"))
                    .accessibilityLabel(isEditing ? L("完成编辑") : L("编辑"))
                    .foregroundStyle(isEditing ? Color.accentColor : Color.primary)

                    if let onNew {
                        Button(action: onNew) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help(L("新建一条便签"))
                        .accessibilityLabel(L("新建便签"))
                    }
                }

                HStack(spacing: 14) {
                    if let onToggleSidebar {
                        Button(action: onToggleSidebar) {
                            Image(systemName: sidebarHidden ? "sidebar.left" : "sidebar.leading")
                                .font(.system(size: 13))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help(sidebarHidden ? L("显示左侧笔记列表") : L("隐藏左侧笔记列表"))
                        .accessibilityLabel(sidebarHidden ? L("显示列表") : L("隐藏列表"))
                    }

                    Button(action: onTogglePin) {
                        Image(systemName: isAlwaysOnTop ? "pin.fill" : "pin")
                            .font(.system(size: 13))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(isAlwaysOnTop ? L("取消始终置顶") : L("始终置顶"))
                    .accessibilityLabel(isAlwaysOnTop ? L("取消置顶") : L("置顶"))
                    .foregroundStyle(isAlwaysOnTop ? Color.accentColor : Color.secondary)

                    if let onPrivacyQuickHide {
                        Button(action: onPrivacyQuickHide) {
                            Image(systemName: privacyOn ? "eye.slash" : "eye")
                                .font(.system(size: 13))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help(privacyOn ? L("取消速藏正文") : L("速藏正文（预览时隐藏内容）"))
                        .accessibilityLabel(privacyOn ? L("取消速藏") : L("速藏正文"))
                    }
                }
                .padding(.leading, 6)

                if let onCollapse {
                    Divider()
                        .frame(height: 16)
                        .padding(.horizontal, 8)
                    Button(action: onCollapse) {
                        Image(systemName: "chevron.right.circle")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(L("收回面板，贴回屏幕右边缘"))
                    .accessibilityLabel(L("收回面板"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 40)
    }
}

struct NoteEditorPane: View {
    @Binding var title: String
    @Binding var bodyText: String
    let color: NoteColor
    var isEditing: Bool
    var isLocked: Bool
    var privacyHide: Bool
    var onChange: () -> Void
    @ObservedObject var bridge: EditorBridge
    @State private var focusToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLocked {
                Label(L("已锁定"), systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField(L("标题（可留空）"), text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .disabled(!isEditing)
                .onChange(of: title) { _, _ in onChange() }

            if let url = Note(body: bodyText).fileLink {
                // 文件卡片：正文只是文件地址，显示成文件信息，而不是一串编码过的 file:// 地址
                FileNoteView(url: url)
            } else if isEditing {
                formattingBar
                MarkdownTextView(
                    text: $bodyText,
                    isEditable: !isLocked,
                    onChange: onChange,
                    bridge: bridge,
                    focusToken: focusToken
                )
                .frame(minHeight: 140)
                .onAppear {
                    focusToken &+= 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        bridge.focus()
                    }
                }
            } else {
                if privacyHide || isLocked {
                    Text(L("内容已隐藏"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if bodyText.isEmpty {
                    Text(L("点「编辑」，或点此处开始编辑…"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { /* 由标题栏编辑按钮进入 */ }
                } else {
                    // 预览也渲染附件图片，避免只看到 markdown 路径
                    MarkdownTextView(
                        text: $bodyText,
                        isEditable: false,
                        onChange: {},
                        bridge: bridge,
                        focusToken: 0
                    )
                    .frame(minHeight: 140)
                }
            }
        }
    }

    private var formattingBar: some View {
        HStack(spacing: 4) {
            formatButton("bold", L("粗体（⌘B）")) { bridge.bold() }
            formatButton("list.bullet", L("项目符号列表（行首输入「- 」）")) { bridge.list() }
            formatButton("list.number", L("编号列表（行首输入「1. 」）")) { bridge.numbered() }
            formatButton("checklist", L("待办（行首输入「[] 」）")) { bridge.todo() }
            Text(L("Tab 缩进"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            Spacer()
            Text(L("可拖入图片"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(color.accent)
    }

    private func formatButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onChange()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 指向本地文件的便签：缩略图、文件名、所在位置、大小，以及打开 / 在 Finder 中显示 / 复制路径；可直接拖出文件
struct FileNoteView: View {
    let url: URL
    @State private var thumb: NSImage?

    private var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// 所在文件夹，家目录显示成 ~
    private var folder: String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    private var detail: String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey, .localizedTypeDescriptionKey])
        var parts: [String] = []
        if let type = values?.localizedTypeDescription { parts.append(type) }
        if values?.isDirectory != true, let size = values?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let date = values?.contentModificationDate {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Group {
                    if let thumb {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                    } else if exists {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "questionmark.folder").font(.system(size: 40)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, height: 96)
                .onDrag { NSItemProvider(object: url as NSURL) }
                .help(L("拖出去即可把文件放进其它 App"))

                VStack(alignment: .leading, spacing: 6) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 14, weight: .semibold))
                        .textSelection(.enabled)
                        .lineLimit(3)
                    if exists {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(L("文件已移动或删除")).font(.caption).foregroundStyle(.red)
                    }
                    Label(folder, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            HStack(spacing: 8) {
                Button(L("打开")) { NSWorkspace.shared.open(url) }
                    .keyboardShortcut(.defaultAction)
                Button(L("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button(L("复制路径")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
            }
            .disabled(!exists)
            .controlSize(.small)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 6)
        .task(id: url) { thumb = await FileThumbnailCache.thumbnail(for: url) }
    }
}

struct ColorChipRow: View {
    let selected: NoteColor
    var onPick: (NoteColor) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(NoteColor.palette) { c in
                Button { onPick(c) } label: {
                    ZStack {
                        if c.normalized == .glass {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .frame(width: 14, height: 14)
                        } else {
                            Circle()
                                .fill(c.fill)
                                .frame(width: 14, height: 14)
                        }
                        Circle()
                            .strokeBorder(
                                selected.normalized == c ? Color.accentColor : Color.primary.opacity(0.2),
                                lineWidth: selected.normalized == c ? 2 : 1
                            )
                            .frame(width: 14, height: 14)
                    }
                }
                .buttonStyle(.plain)
                .help(c.label)
            }
        }
    }
}
