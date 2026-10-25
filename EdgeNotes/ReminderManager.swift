import Foundation
import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class ReminderManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderManager()
    private weak var store: NoteStore?
    private var timer: Timer?

    static let categoryID = "EDGENOTES_REMINDER"
    static let snooze5 = "SNOOZE_5"
    static let snooze15 = "SNOOZE_15"
    static let snooze60 = "SNOOZE_60"
    static let openNote = "OPEN_NOTE"

    private override init() { super.init() }

    func start(store: NoteStore) {
        self.store = store
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let snooze5 = UNNotificationAction(identifier: Self.snooze5, title: "稍后 5 分钟", options: [])
        let snooze15 = UNNotificationAction(identifier: Self.snooze15, title: "稍后 15 分钟", options: [])
        let snooze60 = UNNotificationAction(identifier: Self.snooze60, title: "稍后 1 小时", options: [])
        let open = UNNotificationAction(identifier: Self.openNote, title: "打开便签", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [open, snooze5, snooze15, snooze60],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func snooze(noteID: UUID, minutes: Int) {
        guard let store else { return }
        let at = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let days = store.note(id: noteID)?.reminderRepeatDays
        store.setReminder(id: noteID, at: at, repeatDays: days)
    }

    private func tick() {
        guard let store else { return }
        let now = Date()
        for note in store.notes {
            guard let at = note.reminderAt, at <= now else { continue }
            fire(note: note)
            if let days = note.reminderRepeatDays, days > 0 {
                let next = Calendar.current.date(byAdding: .day, value: days, to: max(at, now)) ?? now.addingTimeInterval(Double(days) * 86400)
                store.setReminder(id: note.id, at: next, repeatDays: days)
            } else {
                store.setReminder(id: note.id, at: nil, repeatDays: nil)
            }
        }
    }

    private func fire(note: Note) {
        notify(note: note)
        bringToFront(noteID: note.id)
    }

    private func bringToFront(noteID: UUID) {
        guard let store else { return }
        store.select(noteID)
        NoteWindowManager.shared.open(noteID: noteID, store: store, focusEditor: true)
        EdgePanelController.shared.expand(animated: true)
        EdgePanelController.shared.makeKeyForEditing()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func notify(note: Note) {
        let content = UNMutableNotificationContent()
        content.title = "便签提醒"
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = note.id.uuidString
        // 隐私：锁定或全局速藏时不暴露正文
        if note.isLocked || AppSettings.shared.privacyHideBodies {
            content.body = "有一条私密便签到期"
            content.subtitle = ""
        } else {
            content.body = note.displayTitle
        }
        content.sound = .default
        content.userInfo = ["noteID": note.id.uuidString]
        let req = UNNotificationRequest(identifier: note.id.uuidString + "-\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let idString = (info["noteID"] as? String) ?? response.notification.request.identifier.components(separatedBy: "-").first
        guard let idString, let id = UUID(uuidString: idString) else {
            completionHandler()
            return
        }
        switch response.actionIdentifier {
        case Self.snooze5: snooze(noteID: id, minutes: 5)
        case Self.snooze15: snooze(noteID: id, minutes: 15)
        case Self.snooze60: snooze(noteID: id, minutes: 60)
        case Self.openNote, UNNotificationDefaultActionIdentifier:
            bringToFront(noteID: id)
        default:
            break
        }
        completionHandler()
    }
}

struct ReminderEditor: View {
    let noteID: UUID
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var date = Date().addingTimeInterval(3600)
    @State private var repeatDays = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 标题栏 + 关闭
            HStack(spacing: 10) {
                Image(systemName: "bell.fill")
                    .foregroundStyle(.orange)
                Text("定时提醒")
                    .font(.headline)
                Spacer()
                Button {
                    clearAndClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭并清除提醒")
                .accessibilityLabel("关闭并清除提醒")
            }

            Toggle(isOn: $enabled) {
                Text(enabled ? "已开启" : "未开启")
            }
            .toggleStyle(.switch)
            .onChange(of: enabled) { _, on in
                if on {
                    store.setReminder(id: noteID, at: date, repeatDays: repeatDays > 0 ? repeatDays : nil)
                } else {
                    store.setReminder(id: noteID, at: nil, repeatDays: nil)
                }
            }

            if enabled {
                VStack(alignment: .leading, spacing: 10) {
                    DatePicker("提醒时间", selection: $date, displayedComponents: [.date, .hourAndMinute])
                        .onChange(of: date) { _, v in
                            store.setReminder(id: noteID, at: v, repeatDays: repeatDays > 0 ? repeatDays : nil)
                        }

                    Picker("重复", selection: $repeatDays) {
                        Text("不重复").tag(0)
                        Text("每天").tag(1)
                        Text("每 7 天").tag(7)
                        Text("每 30 天").tag(30)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: repeatDays) { _, v in
                        store.setReminder(id: noteID, at: date, repeatDays: v > 0 ? v : nil)
                    }

                    Text("快速延后")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("5 分钟") { ReminderManager.shared.snooze(noteID: noteID, minutes: 5); reload() }
                        Button("15 分钟") { ReminderManager.shared.snooze(noteID: noteID, minutes: 15); reload() }
                        Button("1 小时") { ReminderManager.shared.snooze(noteID: noteID, minutes: 60); reload() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }

            HStack(spacing: 12) {
                if enabled || store.note(id: noteID)?.reminderAt != nil {
                    Button("清除提醒", role: .destructive) {
                        clearAndClose()
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(16)
        .frame(minWidth: 320)
        .onAppear(perform: reload)
        .onChange(of: noteID) { _, _ in reload() }
    }

    private func clearAndClose() {
        enabled = false
        store.setReminder(id: noteID, at: nil, repeatDays: nil)
        dismiss()
    }

    private func reload() {
        if let n = store.note(id: noteID), let at = n.reminderAt {
            enabled = true
            date = at
            repeatDays = n.reminderRepeatDays ?? 0
        } else {
            enabled = false
            date = Date().addingTimeInterval(3600)
            repeatDays = 0
        }
    }
}
