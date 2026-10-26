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
                    .help("关闭（不退出）")
                    .accessibilityLabel("关闭窗口")
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
                    .help(isEditing ? "完成编辑，回到预览" : "开始编辑正文")
                    .accessibilityLabel(isEditing ? "完成编辑" : "编辑")
                    .foregroundStyle(isEditing ? Color.accentColor : Color.primary)

                    if let onNew {
                        Button(action: onNew) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help("新建一条便签")
                        .accessibilityLabel("新建便签")
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
                        .help(sidebarHidden ? "显示左侧笔记列表" : "隐藏左侧笔记列表")
                        .accessibilityLabel(sidebarHidden ? "显示列表" : "隐藏列表")
                    }

                    Button(action: onTogglePin) {
                        Image(systemName: isAlwaysOnTop ? "pin.fill" : "pin")
                            .font(.system(size: 13))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(isAlwaysOnTop ? "取消始终置顶" : "始终置顶")
                    .accessibilityLabel(isAlwaysOnTop ? "取消置顶" : "置顶")
                    .foregroundStyle(isAlwaysOnTop ? Color.accentColor : Color.secondary)

                    if let onPrivacyQuickHide {
                        Button(action: onPrivacyQuickHide) {
                            Image(systemName: privacyOn ? "eye.slash" : "eye")
                                .font(.system(size: 13))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help(privacyOn ? "取消速藏正文" : "速藏正文（预览时隐藏内容）")
                        .accessibilityLabel(privacyOn ? "取消速藏" : "速藏正文")
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
                    .help("收回面板，贴回屏幕右边缘")
                    .accessibilityLabel("收回面板")
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
                Label("已锁定", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("标题（可留空）", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .disabled(!isEditing)
                .onChange(of: title) { _, _ in onChange() }

            if isEditing {
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
                    Text("内容已隐藏")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if bodyText.isEmpty {
                    Text("点「编辑」，或点此处开始编辑…")
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
        HStack(spacing: 8) {
            Button("粗体") { bridge.bold(); onChange() }.buttonStyle(.borderless)
            Button("列表") { bridge.list(); onChange() }.buttonStyle(.borderless)
            Button("待办") { bridge.todo(); onChange() }.buttonStyle(.borderless)
            Spacer()
            Text("可拖入图片")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(color.accent)
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
