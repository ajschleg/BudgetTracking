import Foundation
import GRDB

/// Server-record sync support (Phase 3): the five metadata record types —
/// BudgetCategory, CategorizationRule, MonthlySnapshot, BankProfile,
/// ImportedFile — replicate through the server's generic record store as
/// opaque JSON payloads. This file owns the codec, the apply/merge logic
/// (ported from the retired CloudKit/LAN upsertFromPeer family), and the
/// push gathering.
///
/// Payloads are CONTENT-ONLY: sync fields (lastModifiedAt, cloudKit*,
/// isDeleted) are normalized out before encoding, and the encoder uses
/// sortedKeys — so identical content yields identical bytes no matter when
/// or where it was encoded. That determinism is what lets the server treat
/// byte-identical upserts as seq-silent no-ops, which is the structural
/// guarantee against cross-device echo loops.

enum ServerRecordType: String, CaseIterable {
    case budgetCategory = "budget_category"
    case categorizationRule = "categorization_rule"
    case monthlySnapshot = "monthly_snapshot"
    case bankProfile = "bank_profile"
    case importedFile = "imported_file"
}

/// Shared shape of the five syncable models. All already carry these
/// members; conformance is declared (empty) below.
protocol ServerSyncableModel: Codable, FetchableRecord, PersistableRecord, Identifiable where ID == UUID {
    var id: UUID { get set }
    var lastModifiedAt: Date { get set }
    var isDeleted: Bool { get set }
    var cloudKitRecordName: String? { get set }
    var cloudKitSystemFields: Data? { get set }
}

extension BudgetCategory: ServerSyncableModel {}
extension CategorizationRule: ServerSyncableModel {}
extension MonthlySnapshot: ServerSyncableModel {}
extension BankProfile: ServerSyncableModel {}
extension ImportedFile: ServerSyncableModel {}

extension DatabaseManager {

    // MARK: - Codec

    /// Deterministic content codec. sortedKeys is load-bearing (see header);
    /// .iso8601 keeps Dates stable across encode/decode (second precision is
    /// fine — LWW stamps ride the wire envelope, never the payload).
    static let recordPayloadEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let recordPayloadDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func recordStampKey(_ type: ServerRecordType, _ id: UUID) -> String {
        "\(type.rawValue)/\(id.uuidString.lowercased())"
    }

    private static func contentPayload<M: ServerSyncableModel>(_ model: M) throws -> String {
        var copy = model
        copy.lastModifiedAt = Date(timeIntervalSince1970: 0)
        copy.cloudKitRecordName = nil
        copy.cloudKitSystemFields = nil
        copy.isDeleted = false  // travels in the wire envelope, not the payload
        return String(decoding: try Self.recordPayloadEncoder.encode(copy), as: UTF8.self)
    }

    // MARK: - Push gathering

    struct RecordUploadCandidate {
        let upload: PlaidService.RecordUpload
        let stampKey: String
        let lastModifiedAt: Date
    }

    /// Every record of the five types modified after `since`, encoded for
    /// push. Tombstones included — deletions must propagate.
    func gatherRecordUploads(since: Date) throws -> [RecordUploadCandidate] {
        var out: [RecordUploadCandidate] = []
        func gather<M: ServerSyncableModel & TableRecord>(_ type: ServerRecordType, _ kind: M.Type) throws {
            for model in try fetchAllRecords(type: kind, since: since) {
                out.append(RecordUploadCandidate(
                    upload: PlaidService.RecordUpload(
                        record_type: type.rawValue,
                        id: model.id.uuidString.lowercased(),
                        payload: try Self.contentPayload(model),
                        is_deleted: model.isDeleted
                    ),
                    stampKey: Self.recordStampKey(type, model.id),
                    lastModifiedAt: model.lastModifiedAt
                ))
            }
        }
        try gather(.budgetCategory, BudgetCategory.self)
        try gather(.categorizationRule, CategorizationRule.self)
        try gather(.monthlySnapshot, MonthlySnapshot.self)
        try gather(.bankProfile, BankProfile.self)
        try gather(.importedFile, ImportedFile.self)
        return out
    }

    // MARK: - Apply

    struct ServerRecordApplyOutcome {
        var applied = 0
        var skipped = 0
        /// Server stamps applied this batch, keyed "type/id" — push uses
        /// these to recognize round-trips and skip re-sending them.
        var appliedStamps: [String: Date] = [:]
    }

    /// Fold one page of server record changes into the local DB in a single
    /// write transaction. Per-type merge rules ported from the retired
    /// upsertFromPeer family, with one deliberate change: when two distinct
    /// UUIDs collide on a content key (e.g. same category name created on
    /// two devices), the **lexicographically smaller UUID survives on every
    /// device** — a deterministic rule both sides compute identically, so
    /// merges converge instead of ping-ponging. The losing id is remapped
    /// (where references exist) and tombstoned with a fresh local stamp so
    /// the resolution pushes back to the server.
    func applyServerRecords(_ changes: [PlaidService.RecordChange]) throws -> ServerRecordApplyOutcome {
        var outcome = ServerRecordApplyOutcome()
        guard !changes.isEmpty else { return outcome }

        try dbQueue.write { db in
            for change in changes {
                guard let type = ServerRecordType(rawValue: change.record_type) else {
                    outcome.skipped += 1
                    continue
                }
                let serverStamp = Self.parseServerTimestamp(change.updated_at) ?? Date()
                do {
                    let result: Bool
                    switch type {
                    case .budgetCategory:
                        result = try Self.applyOne(BudgetCategory.self, change, serverStamp, db,
                            contentMatch: { db, incoming in
                                try BudgetCategory
                                    .filter(sql: "LOWER(name) = LOWER(?)", arguments: [incoming.name])
                                    .filter(BudgetCategory.Columns.isDeleted == false)
                                    .fetchOne(db)
                            },
                            remapReferences: { db, loser, survivor in
                                try Self.remapCategoryId(from: loser, to: survivor, in: db)
                            })
                    case .categorizationRule:
                        result = try Self.applyOne(CategorizationRule.self, change, serverStamp, db,
                            contentMatch: { db, incoming in
                                try CategorizationRule
                                    .filter(sql: "LOWER(keyword) = LOWER(?)", arguments: [incoming.keyword])
                                    .filter(CategorizationRule.Columns.categoryId == incoming.categoryId)
                                    .filter(CategorizationRule.Columns.isDeleted == false)
                                    .fetchOne(db)
                            },
                            remapReferences: nil)
                    case .monthlySnapshot:
                        result = try Self.applyOne(MonthlySnapshot.self, change, serverStamp, db,
                            contentMatch: { db, incoming in
                                try MonthlySnapshot
                                    .filter(MonthlySnapshot.Columns.month == incoming.month)
                                    .filter(MonthlySnapshot.Columns.isDeleted == false)
                                    .fetchOne(db)
                            },
                            remapReferences: nil)
                    case .bankProfile:
                        result = try Self.applyOne(BankProfile.self, change, serverStamp, db,
                            contentMatch: { db, incoming in
                                try BankProfile
                                    .filter(sql: "LOWER(name) = LOWER(?)", arguments: [incoming.name])
                                    .filter(BankProfile.Columns.isDeleted == false)
                                    .fetchOne(db)
                            },
                            remapReferences: nil)
                    case .importedFile:
                        result = try Self.applyOne(ImportedFile.self, change, serverStamp, db,
                            contentMatch: { db, incoming in
                                try ImportedFile
                                    .filter(ImportedFile.Columns.fileName == incoming.fileName)
                                    .filter(ImportedFile.Columns.fileSize == incoming.fileSize)
                                    .filter(ImportedFile.Columns.isDeleted == false)
                                    .fetchOne(db)
                            },
                            remapReferences: { db, loser, survivor in
                                // Transactions reference files; a hard FK
                                // means the loser's rows must move BEFORE
                                // the loser can ever be purged.
                                try db.execute(
                                    sql: "UPDATE \"transaction\" SET importedFileId = ? WHERE importedFileId = ?",
                                    arguments: [survivor, loser]
                                )
                            })
                    }
                    if result {
                        outcome.applied += 1
                        if let id = UUID(uuidString: change.id) {
                            outcome.appliedStamps[Self.recordStampKey(type, id)] = serverStamp
                        }
                    } else {
                        outcome.skipped += 1
                    }
                } catch {
                    // One malformed payload must not poison the page.
                    outcome.skipped += 1
                }
            }
        }
        return outcome
    }

    /// Generic single-record apply. Returns true if anything was written.
    private static func applyOne<M: ServerSyncableModel>(
        _ kind: M.Type,
        _ change: PlaidService.RecordChange,
        _ serverStamp: Date,
        _ db: Database,
        contentMatch: (Database, M) throws -> M?,
        remapReferences: ((Database, UUID, UUID) throws -> Void)?
    ) throws -> Bool {
        var incoming = try recordPayloadDecoder.decode(M.self, from: Data(change.payload.utf8))
        incoming.isDeleted = change.is_deleted

        // 1. Exact id match — the common case: plain LWW on the server stamp.
        if let existing = try M.fetchOne(db, key: incoming.id) {
            guard serverStamp > existing.lastModifiedAt else { return false }
            var merged = incoming
            merged.lastModifiedAt = serverStamp                 // echo prevention
            merged.cloudKitRecordName = existing.cloudKitRecordName
            merged.cloudKitSystemFields = existing.cloudKitSystemFields
            try merged.save(db)
            return true
        }

        // 2. Content-key collision with a different UUID (live rows only).
        if !incoming.isDeleted, var localDupe = try contentMatch(db, incoming) {
            let incomingKey = incoming.id.uuidString.lowercased()
            let localKey = localDupe.id.uuidString.lowercased()
            if incomingKey < localKey {
                // Incoming id survives everywhere. The survivor row MUST
                // exist before any references move onto it (FK), so: land
                // the incoming row at the server stamp (round-trips
                // silently), THEN move references, THEN tombstone the local
                // duplicate with a FRESH stamp so the resolution pushes back.
                var winner = incoming
                winner.lastModifiedAt = serverStamp
                try winner.save(db)
                try remapReferences?(db, localDupe.id, incoming.id)
                localDupe.isDeleted = true
                localDupe.lastModifiedAt = Date()
                try localDupe.save(db)
            } else {
                // Local id survives. Adopt the newer content under the local
                // id (fresh stamp → pushes), and record a tombstone under the
                // incoming id (fresh stamp → pushes) so the loser dies on the
                // server and on its originating device.
                if serverStamp > localDupe.lastModifiedAt {
                    var merged = incoming
                    merged.id = localDupe.id
                    merged.lastModifiedAt = Date()
                    merged.cloudKitRecordName = localDupe.cloudKitRecordName
                    merged.cloudKitSystemFields = localDupe.cloudKitSystemFields
                    try merged.save(db)
                }
                var loserTombstone = incoming
                loserTombstone.isDeleted = true
                loserTombstone.lastModifiedAt = Date()
                try loserTombstone.save(db)
            }
            return true
        }

        // 3. Brand new (or a tombstone for a row we never had — still record
        // it so it can't resurrect later).
        var fresh = incoming
        fresh.lastModifiedAt = serverStamp
        try fresh.save(db)
        return true
    }
}
