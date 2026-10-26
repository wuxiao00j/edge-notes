import AppKit
import SwiftUI

@MainActor
final class NoteWindowManager {
    static let shared = NoteWindowManager()

    private var windows: [UUID: NSPanel] = [:]
    private weak var store: NoteStore?

    private init() {}

    func attach(store: NoteStore) { self.store = store }

    func open(noteID: UUID, store: NoteStore, focusEditor: Bool = true) {
        self.store = store
        if let existing = windows[noteID] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = StickyNoteWindowView(noteID: noteID, startEditing: focusEditor)
            .environmentObject(store)

        let hosting = NSHostingView(rootView: root)
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: 240, height: 220)
        panel.contentView = hosting
        panel.level = AppSettings.shared.isAlwaysOnTop ? .floating : .normal
        panel.setFrameAutosaveName("EdgeNotes.Sticky.\(noteID.uuidString)")
        panel.delegate = StickyWindowDelegate.shared
        StickyWindowDelegate.shared.track(noteID: noteID, window: panel)

        if let note = store.note(id: noteID) {
            panel.alphaValue = CGFloat(note.opacity)
        }

        panel.center()
        clamp(panel)
        windows[noteID] = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

    }

    func close(noteID: UUID) {
        if let panel = windows.removeValue(forKey: noteID) {
            panel.close()
        }
        StickyWindowDelegate.shared.untrack(noteID: noteID)
    }

    func handleClosed(_ window: NSWindow) {
        if let pair = windows.first(where: { $0.value === window }) {
            windows.removeValue(forKey: pair.key)
            StickyWindowDelegate.shared.untrack(noteID: pair.key)
        }
    }

    func applyAlwaysOnTop(_ on: Bool) {
        let level: NSWindow.Level = on ? .floating : .normal
        windows.values.forEach { $0.level = level }
    }

    func applyOpacity(noteID: UUID, opacity: Double) {
        windows[noteID]?.alphaValue = CGFloat(opacity)
    }

    func clampAllOnScreen() {
        for panel in windows.values { clamp(panel) }
    }

    private func clamp(_ panel: NSPanel) {
        var frame = panel.frame
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let v = screen.visibleFrame
        frame.origin.x = min(max(frame.origin.x, v.minX), v.maxX - min(frame.width, v.width))
        frame.origin.y = min(max(frame.origin.y, v.minY), v.maxY - min(frame.height, v.height))
        panel.setFrame(frame, display: true)
    }
}

@MainActor
final class StickyWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = StickyWindowDelegate()
    private var map: [ObjectIdentifier: UUID] = [:]

    func track(noteID: UUID, window: NSWindow) { map[ObjectIdentifier(window)] = noteID }
    func untrack(noteID: UUID) { map = map.filter { $0.value != noteID } }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        NoteWindowManager.shared.handleClosed(window)
    }

    func windowDidResize(_ notification: Notification) {
        NoteWindowManager.shared.clampAllOnScreen()
    }
}

struct StickyNoteWindowView: View {
    let noteID: UUID
    var startEditing: Bool = true
    @EnvironmentObject private var store: NoteStore
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var bridge = EditorBridge()
    @State private var draftTitle = ""
    @State private var draftBody = ""
    @State private var isEditing = true
    @State private var syncing = false
    @State private var showReminder = false

    var note: Note? { store.note(id: noteID) }

    var body: some View {
        VStack(spacing: 0) {
            StickyHeaderBar(
                title: note?.displayTitle ?? L("便签"),
                color: note?.color ?? .glass,
                isEditing: isEditing,
                isAlwaysOnTop: settings.isAlwaysOnTop,
                onTogglePin: {
                    NotesWindowController.shared.setAlwaysOnTop(!settings.isAlwaysOnTop)
                },
                onToggleEdit: {
                    isEditing.toggle()
                    if isEditing {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                },
                onClose: { NoteWindowManager.shared.close(noteID: noteID) },
                onPrivacyQuickHide: {
                    settings.setPrivacyHideBodies(!settings.privacyHideBodies)
                },
                privacyOn: settings.privacyHideBodies,
                dragEnabled: true
            )

            Divider().opacity(0.25)

            NoteEditorPane(
                title: $draftTitle,
                bodyText: $draftBody,
                color: note?.color ?? .glass,
                isEditing: isEditing,
                isLocked: note?.isLocked ?? false,
                privacyHide: settings.privacyHideBodies,
                onChange: commit,
                bridge: bridge
            )
            .padding(12)

            // 退出编辑后隐藏底栏（色点 / 透明度 / 提醒 / 侧栏）
            if isEditing {
                footer
            }
        }
        .background(
            FrostedPanelBackground(tint: note?.color ?? .glass)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(note?.opacity ?? 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(6)
        .onAppear {
            isEditing = startEditing
            pull()
            bridge.onURLTitle = { title, _ in
                NotificationCenter.default.post(
                    name: .edgeNotesURLTitle,
                    object: noteID,
                    userInfo: ["title": title]
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                bridge.focus()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .edgeNotesURLTitle)) { note in
            guard (note.object as? UUID) == noteID,
                  let title = note.userInfo?["title"] as? String else { return }
            if draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draftTitle = title
                commit()
            }
        }
        .onChange(of: noteID) { _, _ in pull() }
        .sheet(isPresented: $showReminder) {
            ReminderEditor(noteID: noteID)
                .environmentObject(store)
                .padding()
                .frame(width: 340)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            colorMenu
            opacitySlider
            if let at = note?.reminderAt {
                HStack(spacing: 4) {
                    Image(systemName: "bell.fill").font(.system(size: 9))
                    Text(at.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10))
                    Button {
                        store.setReminder(id: noteID, at: nil, repeatDays: nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help(L("清除定时提醒"))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.orange.opacity(0.18)))
                .foregroundStyle(.orange)
                .onTapGesture { showReminder = true }
            }
            Button(note?.reminderAt == nil ? L("提醒") : L("改提醒")) { showReminder = true }
                .buttonStyle(.borderless)
                .font(.caption)
                .help(L("设置或修改定时提醒"))
            Spacer()
            Button(L("全部便签")) {
                store.select(noteID)
                NotesWindowController.shared.show()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var colorMenu: some View {
        ColorChipRow(selected: note?.color ?? .glass) { c in
            store.setColor(id: noteID, c)
        }
    }

    private var opacitySlider: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.lefthalf.filled").font(.caption2)
            Slider(
                value: Binding(
                    get: { note?.opacity ?? 1 },
                    set: {
                        store.setOpacity(id: noteID, $0)
                        NoteWindowManager.shared.applyOpacity(noteID: noteID, opacity: $0)
                    }
                ),
                in: 0.35...1
            )
            .frame(width: 80)
        }
    }

    private func pull() {
        syncing = true
        defer { syncing = false }
        if let n = note {
            draftTitle = n.title
            draftBody = n.body
        }
    }

    private func commit() {
        guard !syncing else { return }
        store.update(id: noteID) {
            $0.title = draftTitle
            $0.body = draftBody
        }
    }
}
