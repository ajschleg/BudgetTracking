import CloudKit
import Foundation
import os.log

extension Notification.Name {
    /// Posted whenever local data changes and should be pushed to CloudKit.
    static let localDataDidChange = Notification.Name("localDataDidChange")
}

/// Coordinates bidirectional sync between the local GRDB database and CloudKit
/// using CKSyncEngine (macOS 14+).
@Observable
final class SyncEngine: @unchecked Sendable {

    enum SyncStatus: Equatable {
        case idle
        case syncing
        case error(String)
        case noAccount
    }

    private(set) var status: SyncStatus = .idle
    private(set) var lastSyncDate: Date?

    private let container: CKContainer
    private var engine: CKSyncEngine?
    private let stateStore = SyncStateStore()
    private let logger = Logger(subsystem: "BudgetTracking", category: "Sync")

    /// Track record names we've sent that are pending confirmation.
    private var pendingRecordNames: Set<String> = []

    private var changeObserver: Any?

    init() {
        container = CKContainer(identifier: SyncConstants.containerIdentifier)

        // Listen for local data changes to trigger sync
        changeObserver = NotificationCenter.default.addObserver(
            forName: .localDataDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pushLocalChanges()
        }

        Task { await start() }
    }

    deinit {
        if let observer = changeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    private func start() async {
        // Check for iCloud account
        do {
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else {
                await MainActor.run { status = .noAccount }
                logger.warning("No iCloud account available")
                return
            }
        } catch {
            await MainActor.run { status = .error(error.localizedDescription) }
            return
        }

        // Initialize CKSyncEngine
        let config = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: stateStore.load(),
            delegate: self
        )
        let syncEngine = CKSyncEngine(config)
        engine = syncEngine

        // Ensure our custom zone exists
        let zoneID = SyncConstants.zoneID
        syncEngine.state.add(pendingDatabaseChanges: [
            .saveZone(CKRecordZone(zoneID: zoneID))
        ])

        // Schedule a fetch to pull any existing data
        do {
            try await syncEngine.fetchChanges()
        } catch {
            logger.error("Initial fetch failed: \(error)")
        }

        logger.info("SyncEngine started")
    }

    // MARK: - Push Local Changes

    /// Call this after any local write to schedule pushing changes to CloudKit.
    func pushLocalChanges() {
        guard let engine else { return }

        do {
            // Gather all pending changes from all tables
            let now = Date()
            let since = lastSyncDate ?? .distantPast

            var recordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] = []

            // Categories
            let categories = try DatabaseManager.shared.fetchPendingChanges(
                type: BudgetCategory.self, since: since
            )
            for cat in categories {
                let name = cat.cloudKitRecordName ?? cat.id.uuidString
                if cat.isDeleted {
                    recordZoneChanges.append(.deleteRecord(
                        CKRecord.ID(recordName: name, zoneID: SyncConstants.zoneID)
                    ))
                } else {
                    recordZoneChanges.append(.saveRecord(
                        CKRecord.ID(recordName: name, zoneID: SyncConstants.zoneID)
                    ))
                }
            }

            // Transactions
            let transactions = try DatabaseManager.shared.fetchPendingChanges(
                type: Transaction.self, since: since
            )
            for txn in transactions {
                let name = txn.cloudKitRecordName ?? txn.id.uuidString
                if txn.isDeleted {
                    recordZoneChanges.append(.deleteRecord(
                        CKRecord.ID(recordName: name, zoneID: SyncConstants.zoneID)
                    ))
                } else {
                    recordZoneChanges.append(.saveRecord(
                        CKRecord.ID(recordName: name, zoneID: SyncConstants.zoneID)
                    ))
                }
            }

            // Imported files
            let files = try DatabaseManager.shared.fetchPendingChanges(
                type: ImportedFile.self, since: since
            )
            for file in files {
                let name = file.cloudKitRecordName ?? file.id.uuidString
                if file.isDeleted {
                    recordZoneChanges.append(.deleteRecord(
                        CKRecord.ID(recordName: name, zoneID: SyncConstants.zoneID)
                    ))
                } else {
                    recordZoneChanges.append(.saveRecord(
                        CKRecord.ID(recordName: name, zoneID: SyncConstants.zoneID)
                    ))
                }
            }

            // Rules
            let rules = try DatabaseManager.shared.fetchPendingChanges(
                type: CategorizationRule.self, since: since
            )
            for rule in rules {
                let name = rule.cloudKitRecordName ?? rule.id.uuidString
                if rule.isDeleted {
                    recordZoneChanges.append(.deleteRecord(
                        CKRecord.ID(recordName: name, zoneID: SyncConstants.zoneID)
                    ))
                } else {
                    recordZoneChanges.append(.saveRecord(
                        CKRecord.ID(recordName: name, zoneID: SyncConstants.zoneID)
                    ))
                }
            }

            // Snapshots
            let snapshots = try DatabaseManager.shared.fetchPendingChanges(
                type: MonthlySnapshot.self, since: since
            )
            for snap in snapshots {
                let name = snap.cloudKitRecordName ?? snap.id.uuidString
                if snap.isDeleted {
                    recordZoneChanges.append(.deleteRecord(
                        CKRecord.ID(recordName: name, zoneID: SyncConstants.zoneID)
                    ))
                } else {
                    recordZoneChanges.append(.saveRecord(
                        CKRecord.ID(recordName: name, zoneID: SyncConstants.zoneID)
                    ))
                }
            }

            if !recordZoneChanges.isEmpty {
                engine.state.add(pendingRecordZoneChanges: recordZoneChanges)
                logger.info("Scheduled \(recordZoneChanges.count) record changes for sync")
            }

            lastSyncDate = now
        } catch {
            logger.error("Failed to gather pending changes: \(error)")
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension SyncEngine: CKSyncEngineDelegate {

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        switch event {
        case .stateUpdate(let stateUpdate):
            stateStore.save(stateUpdate.stateSerialization)

        case .accountChange(let accountChange):
            handleAccountChange(accountChange)

        case .fetchedDatabaseChanges(let fetchedChanges):
            // Zone-level changes; CKSyncEngine handles zone fetching automatically
            logger.info("Fetched database changes: \(fetchedChanges.modifications.count) modified zones")

        case .fetchedRecordZoneChanges(let fetchedChanges):
            handleFetchedRecordZoneChanges(fetchedChanges)

        case .sentRecordZoneChanges(let sentChanges):
            handleSentRecordZoneChanges(sentChanges)

        case .sentDatabaseChanges(let sentChanges):
            for failedSave in sentChanges.failedZoneSaves {
                logger.error("Failed to save zone: \(failedSave.error)")
            }

        case .willFetchChanges:
            Task { @MainActor in status = .syncing }

        case .didFetchChanges:
            Task { @MainActor in
                status = .idle
                lastSyncDate = Date()
            }

        case .willSendChanges:
            Task { @MainActor in status = .syncing }

        case .didSendChanges:
            Task { @MainActor in
                status = .idle
                lastSyncDate = Date()
            }

        @unknown default:
            logger.info("Unknown sync event: \(String(describing: event))")
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges

        let batch = await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: Array(pendingChanges)
        ) { recordID in
            self.buildRecord(for: recordID)
        }
        return batch
    }

    // MARK: - Event Handlers

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            logger.info("iCloud account signed in")
            Task { @MainActor in status = .idle }
        case .signOut:
            logger.info("iCloud account signed out")
            Task { @MainActor in status = .noAccount }
        case .switchAccounts:
            logger.info("iCloud account switched")
            // Could reset local sync state here if needed
        @unknown default:
            break
        }
    }

    private func handleFetchedRecordZoneChanges(
        _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges
    ) {
        // Process fetched records
        for modification in changes.modifications {
            let record = modification.record
            applyRemoteRecord(record)
        }

        // Process deletions
        for deletion in changes.deletions {
            applyRemoteDeletion(deletion.recordID, recordType: deletion.recordType)
        }
    }

    private func handleSentRecordZoneChanges(
        _ changes: CKSyncEngine.Event.SentRecordZoneChanges
    ) {
        // Update system fields for successfully saved records
        for savedRecord in changes.savedRecords {
            let systemData = RecordConverter.archiveSystemFields(of: savedRecord)
            let recordName = savedRecord.recordID.recordName

            do {
                switch savedRecord.recordType {
                case SyncConstants.RecordType.budgetCategory:
                    try DatabaseManager.shared.dbQueue.write { db in
                        try db.execute(sql: """
                            UPDATE budgetCategory
                            SET cloudKitSystemFields = ?, cloudKitRecordName = ?
                            WHERE cloudKitRecordName = ? OR id = ?
                            """, arguments: [systemData, recordName, recordName, recordName])
                    }
                case SyncConstants.RecordType.transaction:
                    try DatabaseManager.shared.dbQueue.write { db in
                        try db.execute(sql: """
                            UPDATE "transaction"
                            SET cloudKitSystemFields = ?, cloudKitRecordName = ?
                            WHERE cloudKitRecordName = ? OR id = ?
                            """, arguments: [systemData, recordName, recordName, recordName])
                    }
                case SyncConstants.RecordType.importedFile:
                    try DatabaseManager.shared.dbQueue.write { db in
                        try db.execute(sql: """
                            UPDATE importedFile
                            SET cloudKitSystemFields = ?, cloudKitRecordName = ?
                            WHERE cloudKitRecordName = ? OR id = ?
                            """, arguments: [systemData, recordName, recordName, recordName])
                    }
                case SyncConstants.RecordType.categorizationRule:
                    try DatabaseManager.shared.dbQueue.write { db in
                        try db.execute(sql: """
                            UPDATE categorizationRule
                            SET cloudKitSystemFields = ?, cloudKitRecordName = ?
                            WHERE cloudKitRecordName = ? OR id = ?
                            """, arguments: [systemData, recordName, recordName, recordName])
                    }
                case SyncConstants.RecordType.monthlySnapshot:
                    try DatabaseManager.shared.dbQueue.write { db in
                        try db.execute(sql: """
                            UPDATE monthlySnapshot
                            SET cloudKitSystemFields = ?, cloudKitRecordName = ?
                            WHERE cloudKitRecordName = ? OR id = ?
                            """, arguments: [systemData, recordName, recordName, recordName])
                    }
                case SyncConstants.RecordType.bankProfile:
                    try DatabaseManager.shared.dbQueue.write { db in
                        try db.execute(sql: """
                            UPDATE bankProfile
                            SET cloudKitSystemFields = ?, cloudKitRecordName = ?
                            WHERE cloudKitRecordName = ? OR id = ?
                            """, arguments: [systemData, recordName, recordName, recordName])
                    }
                default:
                    break
                }
            } catch {
                logger.error("Failed to update system fields for \(savedRecord.recordID): \(error)")
            }
        }

        // Handle conflicts
        for failedSave in changes.failedRecordSaves {
            let ckError = failedSave.error as CKError
            if ckError.code == CKError.Code.serverRecordChanged,
               let serverRecord = ckError.serverRecord {
                // Conflict — resolve it
                let clientRecord = failedSave.record
                if let resolved = ConflictResolver.resolve(
                    clientRecord: clientRecord,
                    serverRecord: serverRecord
                ) {
                    // Re-queue the resolved record
                    engine?.state.add(pendingRecordZoneChanges: [
                        .saveRecord(resolved.recordID)
                    ])
                }
                // else: accept server version, apply it locally
                applyRemoteRecord(serverRecord)
            } else {
                logger.error("Failed to save record \(failedSave.record.recordID): \(ckError)")
            }
        }
    }

    // MARK: - Record Building

    /// Build a CKRecord for a pending save, looking up the local record by recordName.
    private func buildRecord(for recordID: CKRecord.ID) -> CKRecord? {
        let recordName = recordID.recordName

        do {
            // Try each table to find the matching record
            if let cat = try DatabaseManager.shared.dbQueue.read({ db in
                try BudgetCategory
                    .filter(sql: "cloudKitRecordName = ? OR id = ?",
                            arguments: [recordName, recordName])
                    .fetchOne(db)
            }) {
                return RecordConverter.ckRecord(from: cat)
            }

            if let txn = try DatabaseManager.shared.dbQueue.read({ db in
                try Transaction
                    .filter(sql: "cloudKitRecordName = ? OR id = ?",
                            arguments: [recordName, recordName])
                    .fetchOne(db)
            }) {
                return RecordConverter.ckRecord(from: txn)
            }

            if let file = try DatabaseManager.shared.dbQueue.read({ db in
                try ImportedFile
                    .filter(sql: "cloudKitRecordName = ? OR id = ?",
                            arguments: [recordName, recordName])
                    .fetchOne(db)
            }) {
                return RecordConverter.ckRecord(from: file)
            }

            if let rule = try DatabaseManager.shared.dbQueue.read({ db in
                try CategorizationRule
                    .filter(sql: "cloudKitRecordName = ? OR id = ?",
                            arguments: [recordName, recordName])
                    .fetchOne(db)
            }) {
                return RecordConverter.ckRecord(from: rule)
            }

            if let snap = try DatabaseManager.shared.dbQueue.read({ db in
                try MonthlySnapshot
                    .filter(sql: "cloudKitRecordName = ? OR id = ?",
                            arguments: [recordName, recordName])
                    .fetchOne(db)
            }) {
                return RecordConverter.ckRecord(from: snap)
            }

            if let profile = try DatabaseManager.shared.dbQueue.read({ db in
                try BankProfile
                    .filter(sql: "cloudKitRecordName = ? OR id = ?",
                            arguments: [recordName, recordName])
                    .fetchOne(db)
            }) {
                return RecordConverter.ckRecord(from: profile)
            }
        } catch {
            logger.error("Failed to build record for \(recordName): \(error)")
        }

        return nil
    }

    // MARK: - Apply Remote Changes

    private func applyRemoteRecord(_ record: CKRecord) {
        do {
            switch record.recordType {
            case SyncConstants.RecordType.budgetCategory:
                if let category = RecordConverter.budgetCategory(from: record) {
                    try DatabaseManager.shared.upsertFromCloud(category)
                }
            case SyncConstants.RecordType.transaction:
                if let transaction = RecordConverter.transaction(from: record) {
                    try DatabaseManager.shared.upsertFromCloud(transaction)
                }
            case SyncConstants.RecordType.importedFile:
                if let file = RecordConverter.importedFile(from: record) {
                    try DatabaseManager.shared.upsertFromCloud(file)
                }
            case SyncConstants.RecordType.categorizationRule:
                if let rule = RecordConverter.categorizationRule(from: record) {
                    try DatabaseManager.shared.upsertFromCloud(rule)
                }
            case SyncConstants.RecordType.monthlySnapshot:
                if let snapshot = RecordConverter.monthlySnapshot(from: record) {
                    try DatabaseManager.shared.upsertFromCloud(snapshot)
                }
            case SyncConstants.RecordType.bankProfile:
                if let profile = RecordConverter.bankProfile(from: record) {
                    try DatabaseManager.shared.upsertFromCloud(profile)
                }
            default:
                logger.warning("Unknown record type: \(record.recordType)")
            }
        } catch {
            logger.error("Failed to apply remote record \(record.recordID): \(error)")
        }
    }

    private func applyRemoteDeletion(_ recordID: CKRecord.ID, recordType: CKRecord.RecordType) {
        let table: String
        switch recordType {
        case SyncConstants.RecordType.budgetCategory:
            table = "budgetCategory"
        case SyncConstants.RecordType.transaction:
            table = "transaction"
        case SyncConstants.RecordType.importedFile:
            table = "importedFile"
        case SyncConstants.RecordType.categorizationRule:
            table = "categorizationRule"
        case SyncConstants.RecordType.monthlySnapshot:
            table = "monthlySnapshot"
        case SyncConstants.RecordType.bankProfile:
            table = "bankProfile"
        default:
            logger.warning("Unknown record type for deletion: \(recordType)")
            return
        }

        do {
            try DatabaseManager.shared.hardDelete(
                table: table,
                recordName: recordID.recordName
            )
        } catch {
            logger.error("Failed to apply remote deletion \(recordID): \(error)")
        }
    }
}
