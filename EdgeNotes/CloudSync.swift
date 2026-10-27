import AppKit
import CloudKit
import Combine
import Security

/// iCloud 同步（测试版）：用 CKSyncEngine 把便签、回收站、附件图片同步到用户自己的 iCloud 私有数据库。
/// 默认关闭；只有带 iCloud 授权（Developer ID 签名 + 描述文件）的版本才能打开。
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()
    static let containerID = "iCloud.com.barry.EdgeNotes"

    enum Status: Equatable {
        case off
        /// 这个版本没有 iCloud 授权（开发版、旧的 ad-hoc 版）
        case unavailable
        case syncing
        case synced(Date)
        case error(String)
    }

    @Published private(set) var status: Status = .off

    private weak var store: NoteStore?
    private var stateURL: URL?
    private var state = SyncState()
    private var engine: CKSyncEngine?
    private var settingsCancellable: AnyCancellable?
    private var runCancellables: Set<AnyCancellable> = []
    private var pollTimer: Timer?

    private init() {}

    /// 没有 iCloud 授权时调用 CloudKit 会直接崩溃，所以先检查自己的签名里有没有这项授权
    static var isAvailable: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) != nil
    }

    func configure(store: NoteStore, dataDirectory: URL) {
        self.store = store
        stateURL = dataDirectory.appendingPathComponent("sync-state.json")
        settingsCancellable = AppSettings.shared.$iCloudSyncEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] on in on ? self?.start() : self?.stop() }
    }

    func syncNow() {
        guard let engine else { return }
        status = .syncing
        Task {
            do {
                try await engine.fetchChanges()
                try await engine.sendChanges()
                status = .synced(Date())
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - 启停

    private func start() {
        guard Self.isAvailable else { status = .unavailable; return }
        guard engine == nil, let store else { return }
        state = loadState()
        let serialization = state.engine.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let container = CKContainer(identifier: Self.containerID)
        let config = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: serialization,
            delegate: self
        )
        let engine = CKSyncEngine(config)
        self.engine = engine
        if serialization == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncSchema.zoneID))])
        }

        // 本机有改动就排队上传（和上次同步成功的内容比对）
        store.$notes.combineLatest(store.$trash)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in self?.enqueueLocalChanges() }
            .store(in: &runCancellables)
        // 回到前台时、以及每 5 分钟兜底拉一次（推送没到时也能同步）
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.syncNow() }
            .store(in: &runCancellables)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in CloudSync.shared.syncNow() }
        }
        NSApp.registerForRemoteNotifications()

        enqueueLocalChanges()
        syncNow()
    }

    private func stop() {
        engine = nil
        runCancellables.removeAll()
        pollTimer?.invalidate(); pollTimer = nil
        status = Self.isAvailable ? .off : .unavailable
    }

    // MARK: - 本机改动 → 待上传

    private func enqueueLocalChanges() {
        guard let engine, let store else { return }
        let snapshot = store.syncSnapshot
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for (id, note) in snapshot where state.bases[id]?.note != note {
            changes.append(.saveRecord(SyncSchema.noteRecordID(id)))
            for name in Self.attachmentNames(in: note) where !state.uploadedAttachments.contains(name) {
                changes.append(.saveRecord(SyncSchema.attachmentRecordID(name)))
            }
        }
        // 本机彻底删除（清出回收站）的，云端也删
        for id in state.bases.keys where snapshot[id] == nil {
            changes.append(.deleteRecord(SyncSchema.noteRecordID(id)))
        }
        let pending = Set(engine.state.pendingRecordZoneChanges)
        let fresh = changes.filter { !pending.contains($0) }
        if !fresh.isEmpty { engine.state.add(pendingRecordZoneChanges: fresh) }
    }

    static func attachmentNames(in note: SyncedNote) -> [String] {
        Note(body: note.body).attachmentPaths.map { String($0.dropFirst("attachments/".count)) }
    }

    /// 要上传的记录：便签带上次的系统字段（change tag），附件带图片文件
    fileprivate func record(for id: CKRecord.ID) -> CKRecord? {
        if let name = SyncSchema.attachmentFileName(from: id) {
            let url = AttachmentStore.directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
                return nil
            }
            let record = CKRecord(recordType: SyncSchema.attachmentType, recordID: id)
            record["asset"] = CKAsset(fileURL: url)
            record["name"] = name
            return record
        }
        guard let uuid = UUID(uuidString: id.recordName), let note = store?.syncSnapshot[uuid] else {
            engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
            return nil
        }
        let record = state.bases[uuid]?.systemFields.flatMap(SyncState.record(fromSystemFields:))
            ?? CKRecord(recordType: SyncSchema.noteType, recordID: id)
        note.write(to: record)
        return record
    }

    // MARK: - 引擎事件

    fileprivate func handle(_ event: CKSyncEngine.Event) {
        switch event {
        case .stateUpdate(let e):
            state.engine = try? JSONEncoder().encode(e.stateSerialization)
            saveState()

        case .accountChange(let e):
            switch e.changeType {
            case .signIn:
                break
            case .signOut, .switchAccounts:
                // 账号没了或换了：停止同步，本机数据原样保留，下次打开同步当作全新开始
                state = SyncState()
                saveState()
                AppSettings.shared.setICloudSyncEnabled(false)
                status = .error(L("iCloud 账号已退出或更换，同步已关闭。本机便签都还在，重新打开同步即可。"))
            @unknown default:
                break
            }

        case .fetchedDatabaseChanges(let e):
            // 云端数据被清空（比如在系统设置里删了 iCloud 数据）：重新上传本机全部内容
            if e.deletions.contains(where: { $0.zoneID == SyncSchema.zoneID }) {
                state.bases = [:]
                state.uploadedAttachments = []
                engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncSchema.zoneID))])
                enqueueLocalChanges()
            }

        case .fetchedRecordZoneChanges(let e):
            for modification in e.modifications { applyServer(modification.record) }
            for deletion in e.deletions { applyServerDeletion(deletion.recordID) }
            saveState()
            enqueueLocalChanges()

        case .sentRecordZoneChanges(let e):
            for record in e.savedRecords {
                if let name = SyncSchema.attachmentFileName(from: record.recordID) {
                    state.uploadedAttachments.insert(name)
                } else if let uuid = UUID(uuidString: record.recordID.recordName), let note = SyncedNote(record: record) {
                    state.bases[uuid] = .init(note: note, systemFields: SyncState.systemFields(of: record))
                }
            }
            for id in e.deletedRecordIDs {
                if let uuid = UUID(uuidString: id.recordName) { state.bases[uuid] = nil }
            }
            var retry: [CKSyncEngine.PendingRecordZoneChange] = []
            for failure in e.failedRecordSaves {
                let id = failure.record.recordID
                switch failure.error.code {
                case .serverRecordChanged:
                    // 别的设备先改了：按规则合并，再把合并结果传上去
                    if let server = failure.error.serverRecord { applyServer(server) }
                    retry.append(.saveRecord(id))
                case .zoneNotFound:
                    engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncSchema.zoneID))])
                    retry.append(.saveRecord(id))
                case .unknownItem:
                    // 云端已经没有这条：去掉旧的系统字段，当新记录重新上传
                    if let uuid = UUID(uuidString: id.recordName) { state.bases[uuid]?.systemFields = nil }
                    retry.append(.saveRecord(id))
                default:
                    status = .error(failure.error.localizedDescription)
                }
            }
            if !retry.isEmpty { engine?.state.add(pendingRecordZoneChanges: retry) }
            saveState()

        case .didFetchChanges, .didSendChanges:
            if case .error = status {} else { status = .synced(Date()) }

        default:
            break
        }
    }

    /// 收到云端的一条记录：便签按三方合并写进本机；附件图片落到附件目录
    private func applyServer(_ record: CKRecord) {
        if let name = SyncSchema.attachmentFileName(from: record.recordID) {
            let target = AttachmentStore.directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: target.path),
               let source = (record["asset"] as? CKAsset)?.fileURL {
                try? FileManager.default.copyItem(at: source, to: target)
            }
            state.uploadedAttachments.insert(name)
            return
        }
        guard let store, let uuid = UUID(uuidString: record.recordID.recordName),
              let server = SyncedNote(record: record) else { return }
        if let local = store.syncSnapshot[uuid] {
            let result = SyncMerge.merge(local: local, server: server, base: state.bases[uuid]?.note)
            if result.merged != local { store.applySynced(result.merged, id: uuid) }
            if let copy = result.conflictCopy { store.addConflictCopy(copy) }
        } else {
            store.applySynced(server, id: uuid)
        }
        state.bases[uuid] = .init(note: server, systemFields: SyncState.systemFields(of: record))
    }

    /// 别的设备彻底删除了：本机没改过就跟着删；改过就保留并当新记录重新上传（编辑优先）
    private func applyServerDeletion(_ id: CKRecord.ID) {
        if let name = SyncSchema.attachmentFileName(from: id) {
            state.uploadedAttachments.remove(name)
            return
        }
        guard let store, let uuid = UUID(uuidString: id.recordName) else { return }
        let local = store.syncSnapshot[uuid]
        if let local, let base = state.bases[uuid]?.note, local != base {
            state.bases[uuid] = nil
        } else {
            store.removeSynced(id: uuid)
            state.bases[uuid] = nil
        }
    }

    // MARK: - 存取同步进度

    private func loadState() -> SyncState {
        guard let url = stateURL, let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(SyncState.self, from: data) else { return SyncState() }
        return s
    }

    private func saveState() {
        guard let url = stateURL, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension CloudSync: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await MainActor.run { self.handle(event) }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            await MainActor.run { self.record(for: id) }
        }
    }
}
