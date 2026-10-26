import Foundation
import AppKit
import SwiftUI
import UserNotifications
import Combine

@MainActor
final class ReminderManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderManager()
    private weak var store: NoteStore?
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    /// 已交给系统排期的提醒：noteID → 指纹（时间 + 文案），变了才重排
    private var scheduled: [UUID: String] = [:]

    static let categoryID = "EDGENOTES_REMINDER"
    static let snooze5 = "SNOOZE_5"
    static let snooze15 = "SNOOZE_15"
    static let snooze60 = "SNOOZE_60"
    static let openNote = "OPEN_NOTE"
    private static let requestPrefix = "reminder-"

    private override init() { super.init() }

    /// 需在 applicationWillFinishLaunching 里调用，才能接住「点通知启动 App」的回调。
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

        // 通知交给系统按时间投递（App 退出也会响）；这里只负责同步排期
        store.$notes
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.syncSchedule() }
            .store(in: &cancellables)
        AppSettings.shared.$privacyHideBodies
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduled.removeAll()
                self?.syncSchedule()
            }
            .store(in: &cancellables)

        // 启动时：错过的提醒只推进/清除，不重复弹
        advanceDueReminders(launching: true)
        syncSchedule()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceDueReminders(launching: false) }
        }
    }

    func snooze(noteID: UUID, minutes: Int) {
        guard let store else { return }
        let at = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let days = store.note(id: noteID)?.reminderRepeatDays
        store.setReminder(id: noteID, at: at, repeatDays: days)
    }

    /// 重复提醒的下一次：从原定时间按周期往后推，保持原来的钟点
    static func nextOccurrence(after at: Date, everyDays days: Int, now: Date = Date()) -> Date {
        var next = at
        let cal = Calendar.current
        repeat {
            next = cal.date(byAdding: .day, value: days, to: next) ?? next.addingTimeInterval(Double(days) * 86400)
        } while next <= now
        return next
    }

    /// 到点的提醒：系统已经投递了通知，这里把便签带到前台并推进下一次
    private func advanceDueReminders(launching: Bool) {
        guard let store else { return }
        let now = Date()
        for note in store.notes {
            guard let at = note.reminderAt, at <= now else { continue }
            // 刚到点（App 正在运行）才把便签弹到前面；很久以前错过的只推进
            if !launching && now.timeIntervalSince(at) < 120 {
                bringToFront(noteID: note.id)
            }
            if let days = note.reminderRepeatDays, days > 0 {
                store.setReminder(id: note.id, at: Self.nextOccurrence(after: at, everyDays: days, now: now), repeatDays: days)
            } else {
                store.setReminder(id: note.id, at: nil, repeatDays: nil)
            }
        }
    }

    private func syncSchedule() {
        guard let store else { return }
        let center = UNUserNotificationCenter.current()
        let now = Date()
        var wanted: [UUID: (Note, String)] = [:]
        let privacy = AppSettings.shared.privacyHideBodies
        for note in store.notes {
            guard let at = note.reminderAt, at > now else { continue }
            let fingerprint = "\(at.timeIntervalSince1970)|\(note.displayTitle)|\(note.isLocked)|\(privacy)"
            wanted[note.id] = (note, fingerprint)
        }
        let stale = scheduled.keys.filter { wanted[$0] == nil }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale.map { Self.requestPrefix + $0.uuidString })
            stale.forEach { scheduled.removeValue(forKey: $0) }
        }
        for (id, (note, fingerprint)) in wanted where scheduled[id] != fingerprint {
            scheduled[id] = fingerprint
            schedule(note: note, at: note.reminderAt!)
        }
    }

    private func schedule(note: Note, at: Date) {
        let content = UNMutableNotificationContent()
        content.title = "便签提醒"
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = note.id.uuidString
        // 隐私：锁定或全局速藏时不暴露正文
        if note.isLocked || AppSettings.shared.privacyHideBodies {
            content.body = "有一条私密便签到期"
        } else {
            content.body = note.displayTitle
        }
        content.sound = .default
        content.userInfo = ["noteID": note.id.uuidString]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: at)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        // 同一 identifier 会替换旧的排期
        let req = UNNotificationRequest(identifier: Self.requestPrefix + note.id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }

    private func bringToFront(noteID: UUID) {
        guard let store else { return }
        store.select(noteID)
        NoteWindowManager.shared.open(noteID: noteID, store: store, focusEditor: true)
        EdgePanelController.shared.expand(animated: true)
        EdgePanelController.shared.makeKeyForEditing()
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        var idString = info["noteID"] as? String
        if idString == nil {
            // 兜底：identifier 形如 reminder-<UUID>；UUID 自身带「-」，不能按「-」切
            let raw = response.notification.request.identifier
            idString = String(raw.hasPrefix(Self.requestPrefix) ? raw.dropFirst(Self.requestPrefix.count).prefix(36) : raw.prefix(36))
        }
        let action = response.actionIdentifier
        guard let idString, let id = UUID(uuidString: idString) else {
            completionHandler()
            return
        }
        Task { @MainActor in
            switch action {
            case Self.snooze5: self.snooze(noteID: id, minutes: 5)
            case Self.snooze15: self.snooze(noteID: id, minutes: 15)
            case Self.snooze60: self.snooze(noteID: id, minutes: 60)
            case Self.openNote, UNNotificationDefaultActionIdentifier:
                self.bringToFront(noteID: id)
            default:
                break
            }
            completionHandler()
        }
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
