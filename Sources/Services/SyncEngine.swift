import CloudKit
import Foundation

/// CKSyncEngine over the shared config directory.
///
/// The engine is deliberately the LAST piece written. Everything that
/// makes it safe — the domain guard that keeps machine state off the wire,
/// the typed status that stops a stopped sync from rendering as a running
/// one, the three-way merge that refuses to discard an edit — exists and
/// is tested without it. This class moves bytes; it decides nothing.
@MainActor final class SyncEngine {

    private var engine: CKSyncEngine?
    private weak var hostStore: HostStore?
    private let monitor: SyncMonitor

    /// CKSyncEngine's own bookkeeping. MACHINE-SCOPED: it records what
    /// this Mac has already seen, and handing it to another machine would
    /// tell that machine it had already fetched changes it never received.
    private static var stateURL: URL {
        ConfigPaths.machine.appendingPathComponent("sync-state.bin")
    }

    /// One engine for the app. Two would offer the same records on two
    /// schedules and race each other's state serialization.
    @MainActor static let shared = SyncEngine()

    init(monitor: SyncMonitor = .shared) { self.monitor = monitor }

    /// Start syncing, or say why not.
    ///
    /// Refuses rather than throws when sync is unavailable, because every
    /// reason it could be unavailable is already a state the human is
    /// being shown — starting anyway would produce a second, quieter
    /// failure behind the one they can see.
    func start(hostStore: HostStore) async {
        self.hostStore = hostStore
        await monitor.refresh()
        guard monitor.isSyncing else {
            AppLog.sync.error(
                "not starting the sync engine: \(String(describing: self.monitor.status), privacy: .public)")
            return
        }

        var config = CKSyncEngine.Configuration(
            database: CKContainer(identifier: SyncPreflight.containerID).privateCloudDatabase,
            stateSerialization: Self.loadState(),
            delegate: self)
        config.automaticallySync = true
        engine = CKSyncEngine(config)
        AppLog.sync.info("sync engine started")

        // THE ZONE FIRST. CKSyncEngine does not create a custom zone on
        // your behalf — it queues database changes ahead of record
        // changes, but only ones you asked for. Without this every send
        // fails with "Zone does not exist", which reads like a schema
        // problem and is not one.
        engine?.state.add(pendingDatabaseChanges: [
            .saveZone(CKRecordZone(zoneID: SyncRecord.zoneID))
        ])

        // Everything already on disk is a pending change until the server
        // says otherwise. CKSyncEngine deduplicates, so re-offering a
        // record it already holds is cheap and forgetting one is not.
        let pending = SyncDomain.files().compactMap(SyncDomain.recordID)
        engine?.state.add(pendingRecordZoneChanges: pending.map {
            .saveRecord(SyncRecord.recordID(for: $0))
        })
    }

    func stop() {
        engine = nil
        AppLog.sync.info("sync engine stopped")
    }

    /// Paths offered since the last reset. Recorded so a test can assert
    /// the WIRING — that a local edit reaches the engine at all — which is
    /// the part that was missing and that no amount of testing the engine
    /// itself would have caught.
    private(set) var offeredPaths: [String] = []
    func resetOfferedPathsForTesting() { offeredPaths = [] }

    /// Offer a locally changed file to the engine.
    func noteLocalChange(path: String) {
        offeredPaths.append(path)
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(SyncRecord.recordID(for: path))])
    }

    func noteLocalDeletion(path: String) {
        offeredPaths.append(path)
        engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(SyncRecord.recordID(for: path))])
        SyncBaseStore.forget(path)
        SyncSystemFields.forget(path)
    }

    // MARK: - State persistence

    private static func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        // Codable, not NSCoding: CKSyncEngine's serialization is a Swift
        // value type and does not inherit from NSObject.
        return try? PropertyListDecoder().decode(
            CKSyncEngine.State.Serialization.self, from: data)
    }

    private static func saveState(_ s: CKSyncEngine.State.Serialization) {
        do {
            try FileManager.default.createDirectory(
                at: ConfigPaths.machine, withIntermediateDirectories: true)
            let data = try PropertyListEncoder().encode(s)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            // Losing this means re-fetching everything next launch — slow,
            // not wrong. Said out loud because "sync is mysteriously
            // re-downloading on every start" is otherwise unexplainable.
            AppLog.sync.error(
                "could not persist sync state: \(error.localizedDescription, privacy: .public) — the next launch will re-fetch from scratch")
        }
    }

    // MARK: - Applying a fetched record

    /// Write a fetched record to disk, merging when this machine has local
    /// changes it has not yet sent.
    ///
    /// This is where the merge policy meets the wire. Deliberately small:
    /// the decisions live in RecordMerge and the refusals in SyncDomain.
    func apply(path: String, remote: Data) {
        let local = SyncDomain.root.appendingPathComponent(path)
        guard SyncDomain.contains(local) else {
            AppLog.sync.error(
                "refusing a record for \(path, privacy: .public): it resolves outside the shared directory")
            return
        }

        // WHAT ARRIVES IS HELD TO THE SAME RULE AS WHAT IS SENT.
        //
        // An outbound guard alone leaves the hole open at the end that
        // matters: this is how a record with no fields reaches a second
        // Mac, and how one deleted locally comes back — the branch below
        // takes an absent local file as licence to write whatever the
        // wire offered.
        guard SyncDomain.isSendableRecord(remote, named: path) else {
            AppLog.sync.error(
                "refusing a record for \(path, privacy: .public): it carries no fields")
            return
        }

        guard let ours = try? Data(contentsOf: local) else {
            // Nothing local: take the remote as-is. This is the new-Mac
            // case and the common one.
            write(remote, to: local, path: path)
            return
        }
        if ours == remote {
            SyncBaseStore.setBase(for: path, contents: remote)
            return
        }

        guard let ourObj = JSONValue.object(fromJSON: ours),
              let theirObj = JSONValue.object(fromJSON: remote)
        else {
            // Not JSON (ghostty.conf, for instance). Nothing field-level
            // is possible, so the honest move is to keep ours and say the
            // whole file disagrees rather than overwrite it.
            hostStore?.noteConflict(recordID: path, fields: ["file contents"])
            return
        }

        let result = RecordMerge.threeWay(
            base: SyncBaseStore.base(for: path), ours: ourObj, theirs: theirObj)
        guard var mergedData = JSONValue.data(from: result.merged) else { return }
        // A MERGE MUST NOT PRODUCE A CONFLICT ([[RFC-0016]] C-CONFLICT),
        // and this merge cannot promise that on its own: it is FIELD-WISE,
        // so two machines that bind DIFFERENT commands to one chord touch
        // different keys, and it reports no conflict while producing a
        // file that holds one chord against two commands. Injectivity is a
        // cross-field invariant and a field-wise merge is blind to it.
        if path == ConfigPaths.Entry.keymap.name { mergedData = KeymapStore.normalised(mergedData) ?? mergedData }
        write(mergedData, to: local, path: path)

        if result.isClean {
            hostStore?.clearConflict(recordID: path)
            // Agreement is only real once the merge is also sent, so the
            // base moves to what we just wrote and the record is offered.
            noteLocalChange(path: path)
        } else {
            hostStore?.noteConflict(recordID: path, fields: result.conflicts)
        }
    }

    private func write(_ data: Data, to url: URL, path: String) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            SyncBaseStore.setBase(for: path, contents: data)
            // Tell whoever owns this file that it changed underneath
            // them. Writing to disk is not applying: a running app holds
            // its settings in memory, and without this a preference
            // synced from another Mac shows up only after a relaunch.
            switch path {
            case ConfigPaths.Entry.settings.name:
                // And the settings object regenerates the ghostty fragment
                // from what arrived — the fragment itself is not a record.
                SynaptySettings.shared.reloadFromDisk()
            case ConfigPaths.Entry.keymap.name:
                // WRITING TO DISK IS NOT APPLYING, and for a keymap the
                // gap is a whole session: the table is built from the
                // store ([[RFC-0016]] C-CONFLICT), so without this a
                // rebind made on another Mac arrives silently and takes
                // effect at the next launch.
                KeyDispatcher.shared.reload()
            default:
                hostStore?.load()
            }
        } catch {
            AppLog.sync.error(
                "could not write synced record \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension SyncEngine: CKSyncEngineDelegate {

    nonisolated func handleEvent(
        _ event: CKSyncEngine.Event, syncEngine: CKSyncEngine
    ) async {
        switch event {
        case .stateUpdate(let update):
            await MainActor.run { Self.saveState(update.stateSerialization) }

        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                guard let decoded = SyncRecord.decode(modification.record) else { continue }
                let record = modification.record
                await MainActor.run {
                    SyncSystemFields.remember(record, path: decoded.path)
                    self.apply(path: decoded.path, remote: decoded.contents)
                }
            }
            for deletion in changes.deletions {
                await MainActor.run { self.applyRemoteDeletion(deletion.recordID) }
            }

        case .sentRecordZoneChanges(let sent):
            for saved in sent.savedRecords {
                guard let decoded = SyncRecord.decode(saved) else { continue }
                await MainActor.run {
                    SyncBaseStore.setBase(for: decoded.path, contents: decoded.contents)
                    SyncSystemFields.remember(saved, path: decoded.path)
                }
            }
            for failed in sent.failedRecordSaves {
                let name = failed.record.recordID.recordName
                let error = failed.error
                // THE SERVER HANDS BACK ITS OWN VERSION ON A CONFLICT, and
                // ignoring it is why this machine could seed the container
                // once and never update anything again: without the
                // server's change tag every save is an INSERT, and every
                // insert after the first is refused. The tag is right
                // here, in the failure.
                let serverRecord = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
                await MainActor.run {
                    self.handleFailedSave(name: name, error: error, serverRecord: serverRecord)
                }
            }

        case .accountChange(let change):
            // NOT every account event is a sign-out. CKSyncEngine emits
            // one when it first ESTABLISHES the account too, so treating
            // the change types alike makes the engine stop itself the
            // moment it starts — truthfully logged at both ends, and
            // syncing nothing.
            switch change.changeType {
            case .signOut, .switchAccounts:
                await MainActor.run { self.stop() }
            case .signIn:
                break
            @unknown default:
                break
            }
            await monitor.refresh()

        default:
            break
        }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = await syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            await MainActor.run { Self.record(for: recordID) }
        }
    }

    /// Read the file this record stands for, at send time rather than at
    /// queue time — a record queued and then edited again must go out with
    /// the newer contents.
    @MainActor private static func record(for recordID: CKRecord.ID) -> CKRecord? {
        let path = SyncDomain.files()
            .compactMap(SyncDomain.recordID)
            .first { SyncRecord.recordName(for: $0) == recordID.recordName }
        guard let path, let data = try? Data(contentsOf: SyncDomain.root.appendingPathComponent(path))
        else {
            // The file is gone. Returning nil drops the change rather than
            // sending an empty record over a good one.
            return nil
        }
        // Reuse the server's record when we have seen one: a fresh
        // CKRecord has no change tag, and CloudKit reads that as an
        // INSERT. That is why the first upload succeeded and every later
        // one failed "record to insert already exists" — the container
        // was seeded once and then nothing could ever be updated.
        if let existing = SyncSystemFields.record(for: path) {
            existing[SyncRecord.pathKey] = path as CKRecordValue
            existing[SyncRecord.dataKey] = data as CKRecordValue
            return existing
        }
        return SyncRecord.makeRecord(path: path, contents: data)
    }

    @MainActor private func applyRemoteDeletion(_ recordID: CKRecord.ID) {
        guard let path = SyncDomain.files()
            .compactMap(SyncDomain.recordID)
            .first(where: { SyncRecord.recordName(for: $0) == recordID.recordName })
        else { return }
        let url = SyncDomain.root.appendingPathComponent(path)
        guard SyncDomain.contains(url) else { return }
        try? FileManager.default.removeItem(at: url)
        SyncBaseStore.forget(path)
        hostStore?.load()
    }

    @MainActor private func handleFailedSave(
        name: String, error: CKError, serverRecord: CKRecord?
    ) {
        // Recoverable: the server has a version we did not know about.
        // Take its tag, merge its contents through the same policy a
        // fetch uses, and offer the record again — the next attempt is an
        // update rather than a doomed insert.
        if let serverRecord, let decoded = SyncRecord.decode(serverRecord) {
            SyncSystemFields.remember(serverRecord, path: decoded.path)
            apply(path: decoded.path, remote: decoded.contents)
            noteLocalChange(path: decoded.path)
            AppLog.sync.info("reconciled \(decoded.path, privacy: .public) against the server's version")
            return
        }
        let status = SyncPreflight.classify(error)
        AppLog.sync.error(
            "send failed for \(name, privacy: .public): \(String(describing: status), privacy: .public)")
        // A send that keeps failing is a sync that is not running, and the
        // human is told through the same channel as every other reason.
        Task { await monitor.refresh() }
    }
}
