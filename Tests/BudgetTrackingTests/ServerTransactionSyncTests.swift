import XCTest
@testable import BudgetTracking

/// Exercises the server-hub client: pulling server changes into the local
/// GRDB cache (LWW, manual-categorization protection, tombstones, the
/// ImportedFile FK placeholders, echo prevention) and pushing local edits
/// back (round-trip filtering, watermark semantics, seed fast-forward).
/// Network is a mock; the database is the real in-memory DatabaseManager.
final class ServerTransactionSyncTests: XCTestCase {

    // MARK: - Infrastructure

    private final class MockStoreService: ServerTransactionStoring {
        var pages: [PlaidService.ChangesResponse] = []
        var createResponses: [PlaidService.CreateTransactionsResponse] = []
        /// Number of leading createTransactions calls that fail with 429.
        var rateLimitCreatesRemaining = 0
        private(set) var fetchCalls: [(since: Int, limit: Int)] = []
        private(set) var createdBatches: [[PlaidService.ServerTransactionUpload]] = []
        private(set) var patchedBatches: [[(id: String, patch: [String: Any])]] = []

        func fetchTransactionChanges(since: Int, limit: Int) async throws -> PlaidService.ChangesResponse {
            fetchCalls.append((since, limit))
            guard !pages.isEmpty else {
                return PlaidService.ChangesResponse(changes: [], next_seq: since, has_more: false)
            }
            return pages.removeFirst()
        }

        func createTransactions(_ rows: [PlaidService.ServerTransactionUpload]) async throws -> PlaidService.CreateTransactionsResponse {
            if rateLimitCreatesRemaining > 0 {
                rateLimitCreatesRemaining -= 1
                throw PlaidService.PlaidServiceError.rateLimited(retryAfter: 0.05)
            }
            createdBatches.append(rows)
            guard !createResponses.isEmpty else {
                return PlaidService.CreateTransactionsResponse(inserted: rows.count, skipped: 0, max_change_seq: 0)
            }
            return createResponses.removeFirst()
        }

        func batchPatchTransactions(_ ops: [(id: String, patch: [String: Any])]) async throws -> PlaidService.BatchPatchResponse {
            patchedBatches.append(ops)
            return PlaidService.BatchPatchResponse(updated: ops.count, not_found: [])
        }
    }

    private var database: DatabaseManager!
    private var mock: MockStoreService!
    private var sync: ServerTransactionSync!
    private var testDefaults: UserDefaults!

    override func setUpWithError() throws {
        database = try DatabaseManager.makeInMemoryForTesting()
        mock = MockStoreService()
        testDefaults = UserDefaults(suiteName: "ServerTransactionSyncTests-\(UUID().uuidString)")!
        sync = ServerTransactionSync(service: mock, database: database, defaults: testDefaults)
        sync.isEnabled = true
    }

    override func tearDown() {
        sync.cancelPendingPush()
    }

    private static func stamp(secondsAgo: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(-secondsAgo))
    }

    private static func change(
        id: UUID = UUID(),
        externalId: String? = nil,
        date: String = "2026-05-04",
        description: String = "Server Coffee",
        merchant: String? = "Server Cafe",
        amount: Double = -4.50,
        categoryId: UUID? = nil,
        isManual: Bool = false,
        plaidCategory: String? = nil,
        plaidDetailed: String? = nil,
        importedFileId: UUID? = nil,
        source: String = "plaid",
        isDeleted: Bool = false,
        updatedAt: String = stamp(secondsAgo: 0),
        seq: Int
    ) -> PlaidService.ServerTransactionChange {
        PlaidService.ServerTransactionChange(
            id: id.uuidString.lowercased(),
            external_id: externalId,
            account_id: nil,
            item_id: nil,
            date: date,
            month: String(date.prefix(7)),
            description: description,
            merchant: merchant,
            amount: amount,
            category_id: categoryId?.uuidString.lowercased(),
            is_manually_categorized: isManual,
            plaid_category: plaidCategory,
            plaid_category_detailed: plaidDetailed,
            imported_file_id: importedFileId?.uuidString.lowercased(),
            source: source,
            is_deleted: isDeleted,
            updated_at: updatedAt,
            change_seq: seq
        )
    }

    private func page(_ changes: [PlaidService.ServerTransactionChange], nextSeq: Int, hasMore: Bool) -> PlaidService.ChangesResponse {
        PlaidService.ChangesResponse(changes: changes, next_seq: nextSeq, has_more: hasMore)
    }

    private func fetchTransaction(_ id: UUID) throws -> Transaction? {
        try database.fetchAllTransactionsIncludingDeleted().first { $0.id == id }
    }

    // MARK: - Pull

    func testPullInsertsRowsPersistsCursorAndPreservesServerStamps() async throws {
        let rowId = UUID()
        let serverStamp = Self.stamp(secondsAgo: 120)
        mock.pages = [
            page([Self.change(id: rowId, updatedAt: serverStamp, seq: 7)], nextSeq: 7, hasMore: true),
            page([Self.change(seq: 9)], nextSeq: 9, hasMore: false),
        ]

        let result = await sync.pull()

        XCTAssertEqual(result?.applied, 2)
        XCTAssertEqual(sync.cursor, 9, "cursor must land on the last page's next_seq")
        XCTAssertEqual(mock.fetchCalls.map(\.since), [0, 7], "second page must resume from the first page's next_seq")

        let saved = try XCTUnwrap(fetchTransaction(rowId))
        let expectedStamp = try XCTUnwrap(DatabaseManager.parseServerTimestamp(serverStamp))
        XCTAssertEqual(saved.lastModifiedAt.timeIntervalSince1970,
                       expectedStamp.timeIntervalSince1970,
                       accuracy: 0.001,
                       "pulled rows must keep the SERVER stamp — a local Date() here would re-push every pulled row forever")

        // Server rows with no imported_file_id land under the fixed singleton.
        XCTAssertEqual(saved.importedFileId, DatabaseManager.serverSyncFileId)
    }

    func testPullLastWriteWinsAndManualCategorizationProtection() async throws {
        // Local row, manually categorized, modified just now.
        let id = UUID()
        let category = try makeCategory("Protected Category")
        let local = Transaction(
            id: id, date: Date(), description: "Local Edit", amount: -10,
            categoryId: category, isManuallyCategorized: true,
            month: "2026-05", importedFileId: DatabaseManager.serverSyncFileId
        )
        try ensureSingletonFile()
        try database.saveTransactions([local])

        // 1. Older incoming (server stamp in the past) → skipped.
        mock.pages = [page([Self.change(id: id, description: "Stale", updatedAt: Self.stamp(secondsAgo: 3600), seq: 1)], nextSeq: 1, hasMore: false)]
        _ = await sync.pull()
        XCTAssertEqual(try fetchTransaction(id)?.description, "Local Edit")

        // 2. Newer incoming but NOT manually categorized vs local manual → skipped.
        mock.pages = [page([Self.change(id: id, description: "Robot Rename", isManual: false, updatedAt: Self.stamp(secondsAgo: -3600), seq: 2)], nextSeq: 2, hasMore: false)]
        _ = await sync.pull()
        XCTAssertEqual(try fetchTransaction(id)?.description, "Local Edit")
        XCTAssertEqual(try fetchTransaction(id)?.categoryId, category)

        // 3. Newer incoming AND manually categorized (another device's manual edit) → applied.
        mock.pages = [page([Self.change(id: id, description: "Other Device Edit", isManual: true, updatedAt: Self.stamp(secondsAgo: -7200), seq: 3)], nextSeq: 3, hasMore: false)]
        _ = await sync.pull()
        XCTAssertEqual(try fetchTransaction(id)?.description, "Other Device Edit")
    }

    func testPullTombstoneAndExternalIdMatch() async throws {
        try ensureSingletonFile()
        let id = UUID()
        let local = Transaction(
            id: id, date: Date(), description: "Plaid Row", amount: -20,
            month: "2026-05", importedFileId: DatabaseManager.serverSyncFileId,
            externalId: "ext-123"
        )
        try database.saveTransactions([local])

        // Incoming tombstone arrives under a DIFFERENT row id but the same
        // external_id (server ingested it independently) — must match the
        // local row via externalId, not insert a duplicate.
        mock.pages = [page([Self.change(externalId: "ext-123", isDeleted: true, updatedAt: Self.stamp(secondsAgo: -60), seq: 4)], nextSeq: 4, hasMore: false)]
        _ = await sync.pull()

        let all = try database.fetchAllTransactionsIncludingDeleted().filter { $0.externalId == "ext-123" }
        XCTAssertEqual(all.count, 1, "externalId match must merge, never duplicate")
        XCTAssertEqual(all.first?.isDeleted, true)
        XCTAssertEqual(all.first?.id, id, "the local row id wins on externalId merges")
    }

    func testPullCreatesPlaceholderForUnknownImportedFile() async throws {
        let fileId = UUID()
        mock.pages = [page([Self.change(importedFileId: fileId, source: "import", seq: 5)], nextSeq: 5, hasMore: false)]

        let result = await sync.pull()

        XCTAssertEqual(result?.applied, 1)
        let file = try await database.dbQueue.read { try ImportedFile.fetchOne($0, key: fileId) }
        XCTAssertNotNil(file, "unknown imported_file_id must materialize a placeholder so the FK holds")
        XCTAssertEqual(file?.isDeleted, false)
    }

    func testPullSurfacesCategorizationCandidates() async throws {
        let unknownCategory = UUID()
        mock.pages = [page([
            Self.change(description: "Grocery Run", plaidCategory: "FOOD_AND_DRINK", plaidDetailed: "FOOD_AND_DRINK_GROCERIES", source: "plaid", seq: 6),
            Self.change(description: "CSV Row", source: "import", seq: 7),
            Self.change(description: "Pre-categorized", categoryId: unknownCategory, source: "plaid", seq: 8),
        ], nextSeq: 8, hasMore: false)]

        let result = await sync.pull()

        XCTAssertEqual(result?.needsCategorization.count, 1, "only new, uncategorized, live plaid rows need hints")
        XCTAssertEqual(result?.needsCategorization.first?.plaidPrimary, "FOOD_AND_DRINK")
        XCTAssertEqual(result?.needsCategorization.first?.plaidDetailed, "FOOD_AND_DRINK_GROCERIES")

        // The pre-categorized row referenced a category this device has
        // never seen (CloudKit lag) — a placeholder must exist with an
        // epoch stamp so the real CK record wins the merge later.
        let placeholder = try await database.dbQueue.read { try BudgetCategory.fetchOne($0, key: unknownCategory) }
        XCTAssertEqual(placeholder?.name, "(syncing…)")
        XCTAssertEqual(placeholder?.lastModifiedAt, Date(timeIntervalSince1970: 0))
    }

    // MARK: - Push

    func testPushSkipsRoundTrippedRowsButSendsLocalEdits() async throws {
        // Arrange: one row arrives via pull (round-trip candidate).
        let pulledId = UUID()
        mock.pages = [page([Self.change(id: pulledId, seq: 10)], nextSeq: 10, hasMore: false)]
        _ = await sync.pull()

        // Push right away: the only "dirty" row is the round-trip — no calls.
        await sync.push()
        XCTAssertTrue(mock.createdBatches.isEmpty, "round-tripped rows must not re-push")
        XCTAssertTrue(mock.patchedBatches.isEmpty)

        // Now a real local edit (saveTransactions restamps lastModifiedAt).
        var edited = try XCTUnwrap(fetchTransaction(pulledId))
        edited.categoryId = try makeCategory("Push Category")
        edited.isManuallyCategorized = true
        try database.saveTransactions([edited])

        await sync.push()

        XCTAssertEqual(mock.createdBatches.count, 1, "edited row inserts first (server skips known ids)")
        XCTAssertEqual(mock.patchedBatches.count, 1)
        let op = try XCTUnwrap(mock.patchedBatches.first?.first)
        XCTAssertEqual(op.id, pulledId.uuidString.lowercased())
        XCTAssertEqual(op.patch["is_manually_categorized"] as? Bool, true)

        // Watermark advanced: an immediate re-push sends nothing new.
        await sync.push()
        XCTAssertEqual(mock.createdBatches.count, 1)
        XCTAssertEqual(mock.patchedBatches.count, 1)
    }

    // MARK: - Seed

    func testSeedUploadsEverythingEnablesAndLeavesCursorForFullPull() async throws {
        sync.isEnabled = false
        try ensureSingletonFile()
        let live = Transaction(date: Date(), description: "Live", amount: -1, month: "2026-05", importedFileId: DatabaseManager.serverSyncFileId)
        var dead = Transaction(date: Date(), description: "Dead", amount: -2, month: "2026-05", importedFileId: DatabaseManager.serverSyncFileId)
        dead.isDeleted = true
        try database.saveTransactions([live, dead])
        mock.createResponses = [PlaidService.CreateTransactionsResponse(inserted: 2, skipped: 0, max_change_seq: 777)]

        let ok = await sync.seedAll()

        XCTAssertTrue(ok)
        XCTAssertTrue(sync.isEnabled, "completing the seed flips the mode switch")
        XCTAssertEqual(sync.cursor, 0, "cursor must NOT fast-forward — rows the server ingested before/during the seed sit at lower seqs and would be skipped forever (regression: 10 mid-seed Plaid rows lost)")
        XCTAssertEqual(mock.createdBatches.count, 1)
        XCTAssertEqual(mock.createdBatches.first?.count, 2, "tombstones seed too — deletions must propagate")
        let uploadedDeleted = mock.createdBatches.first?.first { $0.is_deleted }
        XCTAssertNotNil(uploadedDeleted)
    }

    func testSeedRetriesThroughRateLimiting() async throws {
        sync.isEnabled = false
        try ensureSingletonFile()
        let row = Transaction(date: Date(), description: "Rate Limited", amount: -3, month: "2026-05", importedFileId: DatabaseManager.serverSyncFileId)
        try database.saveTransactions([row])
        mock.rateLimitCreatesRemaining = 2  // first two attempts get 429
        mock.createResponses = [PlaidService.CreateTransactionsResponse(inserted: 1, skipped: 0, max_change_seq: 11)]

        let ok = await sync.seedAll()

        XCTAssertTrue(ok, "seed must wait out 429s, not fail")
        XCTAssertEqual(mock.createdBatches.count, 1, "the batch lands exactly once after retries")
    }

    // MARK: - Summary formatting

    func testStoreSyncSummaryFormatting() {
        XCTAssertEqual(PlaidSyncManager.formatStoreSyncSummary(pulled: 0, categorized: 0),
                       "Up to date — no new transactions")
        XCTAssertEqual(PlaidSyncManager.formatStoreSyncSummary(pulled: 12, categorized: 5),
                       "12 pulled from server · 5 auto-categorized")
        XCTAssertEqual(PlaidSyncManager.formatStoreSyncSummary(pulled: 3, categorized: 0),
                       "3 pulled from server")
    }

    // MARK: - Helpers

    /// Categories carry an FK from transaction.categoryId — local edits in
    /// tests must reference a real row, exactly like the app does.
    @discardableResult
    private func makeCategory(_ name: String) throws -> UUID {
        var category = BudgetCategory(name: name, monthlyBudget: 100)
        try database.dbQueue.write { db in
            try category.save(db)
        }
        return category.id
    }

    /// Local rows in these tests reference the singleton file id directly;
    /// create it the same way a pull would.
    private func ensureSingletonFile() throws {
        try database.dbQueue.write { db in
            if try ImportedFile.fetchOne(db, key: DatabaseManager.serverSyncFileId) == nil {
                var file = ImportedFile(
                    id: DatabaseManager.serverSyncFileId,
                    fileName: "Server Sync",
                    fileSize: 0
                )
                try file.save(db)
            }
        }
    }
}
