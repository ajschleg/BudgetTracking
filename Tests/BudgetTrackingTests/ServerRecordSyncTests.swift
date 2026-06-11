import XCTest
import GRDB
@testable import BudgetTracking

/// Exercises the Phase 3 record sync: pull-first seeding, per-type apply,
/// the deterministic survivor rule for content-key collisions (the
/// anti-ping-pong guarantee), round-trip push filtering, tombstones, LWW,
/// and the placeholder-category upgrade. Mock network, real in-memory DB.
final class ServerRecordSyncTests: XCTestCase {

    private final class MockRecordService: ServerRecordStoring {
        var pages: [PlaidService.RecordChangesResponse] = []
        private(set) var fetchCalls: [(since: Int, limit: Int)] = []
        private(set) var pushedBatches: [[PlaidService.RecordUpload]] = []

        func fetchRecordChanges(since: Int, limit: Int) async throws -> PlaidService.RecordChangesResponse {
            fetchCalls.append((since, limit))
            guard !pages.isEmpty else {
                return PlaidService.RecordChangesResponse(changes: [], next_seq: since, has_more: false)
            }
            return pages.removeFirst()
        }

        func pushRecords(_ rows: [PlaidService.RecordUpload]) async throws -> PlaidService.RecordBulkResponse {
            pushedBatches.append(rows)
            return PlaidService.RecordBulkResponse(upserted: rows.count, skipped: 0)
        }
    }

    private var database: DatabaseManager!
    private var mock: MockRecordService!
    private var sync: ServerRecordSync!
    private var testDefaults: UserDefaults!

    override func setUpWithError() throws {
        database = try DatabaseManager.makeInMemoryForTesting()
        mock = MockRecordService()
        testDefaults = UserDefaults(suiteName: "ServerRecordSyncTests-\(UUID().uuidString)")!
        testDefaults.set(true, forKey: ServerTransactionSync.enabledKey)
        sync = ServerRecordSync(service: mock, database: database, defaults: testDefaults)
    }

    override func tearDown() {
        sync.cancelPendingPush()
        XCTAssertNil(sync.errorMessage, "record sync error: \(sync.errorMessage ?? "")")
    }

    // MARK: - Helpers

    private static func stamp(secondsAgo: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(-secondsAgo))
    }

    /// Content-only payload, exactly as production encodes it.
    private func payload<M: ServerSyncableModel>(_ model: M) throws -> String {
        var copy = model
        copy.lastModifiedAt = Date(timeIntervalSince1970: 0)
        copy.cloudKitRecordName = nil
        copy.cloudKitSystemFields = nil
        copy.isDeleted = false
        return String(decoding: try DatabaseManager.recordPayloadEncoder.encode(copy), as: UTF8.self)
    }

    private func change<M: ServerSyncableModel>(
        _ type: ServerRecordType, _ model: M,
        isDeleted: Bool = false, updatedAt: String = stamp(secondsAgo: 0), seq: Int
    ) throws -> PlaidService.RecordChange {
        PlaidService.RecordChange(
            record_type: type.rawValue,
            id: model.id.uuidString.lowercased(),
            payload: try payload(model),
            is_deleted: isDeleted,
            updated_at: updatedAt,
            change_seq: seq
        )
    }

    private func page(_ changes: [PlaidService.RecordChange], nextSeq: Int, hasMore: Bool = false) -> PlaidService.RecordChangesResponse {
        PlaidService.RecordChangesResponse(changes: changes, next_seq: nextSeq, has_more: hasMore)
    }

    private func liveCategories() throws -> [BudgetCategory] {
        try database.dbQueue.read {
            try BudgetCategory.filter(BudgetCategory.Columns.isDeleted == false).fetchAll($0)
        }
    }

    private func uuid(_ hexPrefix: String) -> UUID {
        UUID(uuidString: "\(hexPrefix)-0000-4000-8000-000000000000")!
    }

    // MARK: - Apply basics

    func testPullAppliesEachTypeAndPersistsCursor() async throws {
        let cat = BudgetCategory(name: "Pulled Cat", monthlyBudget: 100)
        let profile = BankProfile(name: "Chase CSV", fileType: "csv", dateFormat: "MM/dd/yyyy", headerRowIndex: 0)
        let file = ImportedFile(fileName: "may.csv", fileSize: 123)
        let snapshot = MonthlySnapshot(month: "2026-04", totalBudget: 1000, totalSpent: 800, categoryBreakdown: [])
        mock.pages = [
            page([try change(.budgetCategory, cat, seq: 1),
                  try change(.bankProfile, profile, seq: 2)], nextSeq: 2, hasMore: true),
            page([try change(.importedFile, file, seq: 3),
                  try change(.monthlySnapshot, snapshot, seq: 4)], nextSeq: 4),
        ]

        let result = await sync.pull()

        XCTAssertEqual(result?.applied, 4)
        XCTAssertEqual(sync.cursor, 4)
        XCTAssertEqual(mock.fetchCalls.map(\.since), [0, 2])
        XCTAssertEqual(try liveCategories().first?.name, "Pulled Cat")
        let savedProfile = try await database.dbQueue.read { try BankProfile.fetchOne($0, key: profile.id) }
        XCTAssertEqual(savedProfile?.dateFormat, "MM/dd/yyyy")
    }

    func testRuleApplyAfterItsCategoryExists() async throws {
        let cat = BudgetCategory(name: "Food", monthlyBudget: 100)
        let rule = CategorizationRule(keyword: "wholefds", categoryId: cat.id, priority: 1, isUserDefined: true)
        mock.pages = [page([try change(.budgetCategory, cat, seq: 1),
                            try change(.categorizationRule, rule, seq: 2)], nextSeq: 2)]

        let result = await sync.pull()

        XCTAssertEqual(result?.applied, 2)
        let saved = try await database.dbQueue.read { try CategorizationRule.fetchOne($0, key: rule.id) }
        XCTAssertEqual(saved?.keyword, "wholefds")
    }

    func testLWWOlderIncomingSkippedAndTombstoneApplies() async throws {
        var local = BudgetCategory(name: "Keep Me", monthlyBudget: 50)
        try await database.dbQueue.write { try local.save($0) }   // lastModifiedAt = now

        var renamed = local
        renamed.name = "Stale Rename"
        mock.pages = [page([try change(.budgetCategory, renamed, updatedAt: Self.stamp(secondsAgo: 3600), seq: 1)], nextSeq: 1)]
        _ = await sync.pull()
        XCTAssertEqual(try liveCategories().first?.name, "Keep Me", "older server stamp must lose LWW")

        mock.pages = [page([try change(.budgetCategory, local, isDeleted: true, updatedAt: Self.stamp(secondsAgo: -60), seq: 2)], nextSeq: 2)]
        _ = await sync.pull()
        XCTAssertTrue(try liveCategories().isEmpty, "newer tombstone must apply")
    }

    // MARK: - Survivor rule

    func testCategoryNameMergeSurvivorSymmetry() async throws {
        // Direction 1: local has the BIGGER uuid; incoming smaller → incoming survives.
        let small = uuid("11111111")
        let big = uuid("99999999")

        var localBig = BudgetCategory(id: big, name: "Groceries", monthlyBudget: 500)
        try await database.dbQueue.write { try localBig.save($0) }
        // a transaction referencing the local (losing) category
        try ensureSingletonFile()
        let txn = Transaction(date: Date(), description: "Ref", amount: -5, categoryId: big,
                              month: "2026-05", importedFileId: DatabaseManager.serverSyncFileId)
        try database.saveTransactions([txn])

        let incomingSmall = BudgetCategory(id: small, name: "groceries", monthlyBudget: 600)
        mock.pages = [page([try change(.budgetCategory, incomingSmall, seq: 1)], nextSeq: 1)]
        _ = await sync.pull()

        let live = try liveCategories()
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.id, small, "lexicographically smaller UUID survives")
        let remapped = try database.fetchAllTransactionsIncludingDeleted().first { $0.id == txn.id }
        XCTAssertEqual(remapped?.categoryId, small, "references remap to the survivor")
        let tombstoned = try await database.dbQueue.read { try BudgetCategory.fetchOne($0, key: big) }
        XCTAssertEqual(tombstoned?.isDeleted, true)
        XCTAssertGreaterThan(tombstoned!.lastModifiedAt, Date().addingTimeInterval(-30),
                             "loser tombstone restamped fresh so the resolution pushes back")

        // Direction 2 (new DB): local has the SMALLER uuid; incoming bigger → local survives.
        database = try DatabaseManager.makeInMemoryForTesting()
        mock = MockRecordService()
        testDefaults.set(true, forKey: ServerTransactionSync.enabledKey)
        sync = ServerRecordSync(service: mock, database: database, defaults: testDefaults)

        var localSmall = BudgetCategory(id: small, name: "Groceries", monthlyBudget: 500)
        try await database.dbQueue.write { try localSmall.save($0) }
        let incomingBig = BudgetCategory(id: big, name: "GROCERIES", monthlyBudget: 700)
        mock.pages = [page([try change(.budgetCategory, incomingBig, updatedAt: Self.stamp(secondsAgo: -60), seq: 1)], nextSeq: 1)]
        _ = await sync.pull()

        let live2 = try liveCategories()
        XCTAssertEqual(live2.count, 1)
        XCTAssertEqual(live2.first?.id, small, "same survivor regardless of merge direction")
        XCTAssertEqual(live2.first?.monthlyBudget, 700, "newer incoming content adopted under surviving id")
        let loser = try await database.dbQueue.read { try BudgetCategory.fetchOne($0, key: big) }
        XCTAssertEqual(loser?.isDeleted, true, "losing id tombstoned so it dies server-side too")
    }

    func testSnapshotMonthDedup() async throws {
        var local = MonthlySnapshot(month: "2026-05", totalBudget: 1000, totalSpent: 900, categoryBreakdown: [])
        try await database.dbQueue.write { try local.save($0) }
        var incoming = MonthlySnapshot(month: "2026-05", totalBudget: 1000, totalSpent: 950, categoryBreakdown: [])
        // force a deterministic survivor: make the incoming id smaller/larger is irrelevant —
        // month-match must converge to ONE live snapshot either way.
        mock.pages = [page([try change(.monthlySnapshot, incoming, updatedAt: Self.stamp(secondsAgo: -60), seq: 1)], nextSeq: 1)]

        _ = await sync.pull()

        let liveSnapshots = try await database.dbQueue.read {
            try MonthlySnapshot.filter(MonthlySnapshot.Columns.isDeleted == false).fetchAll($0)
        }
        XCTAssertEqual(liveSnapshots.count, 1, "one live snapshot per month after merge")
    }

    // MARK: - Push / round-trips / seed

    func testPushSkipsRoundTripsButSendsLocalEdits() async throws {
        let cat = BudgetCategory(name: "RoundTrip", monthlyBudget: 10)
        mock.pages = [page([try change(.budgetCategory, cat, seq: 1)], nextSeq: 1)]
        _ = await sync.pull()

        await sync.push()
        XCTAssertTrue(mock.pushedBatches.isEmpty, "pulled rows must not re-push")

        var edited = try await database.dbQueue.read { try BudgetCategory.fetchOne($0, key: cat.id) }!
        edited.monthlyBudget = 25
        try await database.dbQueue.write { db in
            edited.lastModifiedAt = Date()
            try edited.save(db)
        }
        await sync.push()

        XCTAssertEqual(mock.pushedBatches.count, 1)
        XCTAssertEqual(mock.pushedBatches.first?.count, 1)
        XCTAssertEqual(mock.pushedBatches.first?.first?.record_type, "budget_category")

        await sync.push()
        XCTAssertEqual(mock.pushedBatches.count, 1, "watermark advanced — nothing re-sends")
    }

    func testSeedPullsFirstThenPushesOnlyNonRoundTrips() async throws {
        // Server already has one category (from another device).
        let serverCat = BudgetCategory(name: "From Other Device", monthlyBudget: 40)
        mock.pages = [page([try change(.budgetCategory, serverCat, seq: 7)], nextSeq: 7)]
        // Local has one rule of its own (plus the category will land via pull).
        var localProfile = BankProfile(name: "Local Bank", fileType: "csv", dateFormat: "MM/dd/yyyy", headerRowIndex: 0)
        try await database.dbQueue.write { try localProfile.save($0) }

        await sync.syncIfNeeded()

        XCTAssertTrue(sync.hasSeeded)
        XCTAssertEqual(sync.cursor, 7)
        // Pull happened BEFORE push: the pulled category is filtered as a
        // round-trip; only the local profile uploads.
        let uploaded = mock.pushedBatches.flatMap { $0 }
        XCTAssertEqual(uploaded.count, 1)
        XCTAssertEqual(uploaded.first?.record_type, "bank_profile")

        // Idempotence: a second launch pushes nothing new.
        mock.pages = []
        await sync.syncIfNeeded()
        XCTAssertEqual(mock.pushedBatches.flatMap { $0 }.count, 1)
    }

    func testPlaceholderCategoryUpgradedByRealRecord() async throws {
        // The transactions feed materializes epoch-stamped placeholders.
        let placeholderId = UUID()
        try await database.dbQueue.write { db in
            var placeholder = BudgetCategory(
                id: placeholderId, name: "(syncing…)", monthlyBudget: 0,
                lastModifiedAt: Date(timeIntervalSince1970: 0)
            )
            try placeholder.save(db)
        }
        let real = BudgetCategory(id: placeholderId, name: "Dining Out", monthlyBudget: 200)
        mock.pages = [page([try change(.budgetCategory, real, seq: 1)], nextSeq: 1)]

        _ = await sync.pull()

        let upgraded = try await database.dbQueue.read { try BudgetCategory.fetchOne($0, key: placeholderId) }
        XCTAssertEqual(upgraded?.name, "Dining Out", "epoch placeholder always loses LWW to the real record")
        XCTAssertEqual(try liveCategories().count, 1)
    }

    // MARK: - Payload determinism

    func testPayloadEncodingIsDeterministicAndContentOnly() throws {
        var a = BudgetCategory(name: "Same", monthlyBudget: 1)
        var b = a
        a.lastModifiedAt = Date()
        b.lastModifiedAt = Date().addingTimeInterval(-9999)
        a.cloudKitRecordName = "ck-name"
        b.isDeleted = true
        XCTAssertEqual(try payload(a), try payload(b),
                       "sync fields must not leak into payload bytes — no-op detection depends on it")
    }

    // MARK: - Infra

    private func ensureSingletonFile() throws {
        try database.dbQueue.write { db in
            if try ImportedFile.fetchOne(db, key: DatabaseManager.serverSyncFileId) == nil {
                var file = ImportedFile(id: DatabaseManager.serverSyncFileId, fileName: "Server Sync", fileSize: 0)
                try file.save(db)
            }
        }
    }
}
