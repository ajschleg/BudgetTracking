import XCTest
@testable import BudgetTracking

/// Store-mode PlaidSyncManager tests. Since the legacy local-apply path
/// died with the CK/LAN engines, syncTransactions() is an orchestrator:
/// ask the server to ingest from Plaid, pull the deltas, categorize new
/// rows with the riding Plaid hints, push the assignments back. The
/// behaviors the old legacy tests covered live elsewhere now: sign
/// flipping/pending-skipping/external-id dedup are server-side
/// (transactionsStore curl gate), and pull-apply mechanics are pinned by
/// ServerTransactionSyncTests.
final class PlaidSyncManagerTests: XCTestCase {

    // MARK: - Mocks

    private final class MockPlaidService: PlaidTransactionSyncing {
        var response = PlaidService.SyncResponse(added: nil, modified: nil, removed: nil, ingested: nil)
        var error: Error?
        private(set) var syncCallCount = 0

        func syncTransactions() async throws -> PlaidService.SyncResponse {
            syncCallCount += 1
            if let error { throw error }
            return response
        }

        func fetchAccounts() async throws -> [PlaidService.AccountListItem] { fatalError("not stubbed") }
        func removeItem(_ itemId: String) async throws { fatalError("not stubbed") }
        func removeAllItems() async throws -> PlaidService.BulkRemoveResponse { fatalError("not stubbed") }
        func refreshBalances(itemId: String?, minAgeSeconds: Int?) async throws -> PlaidService.BalancesRefreshResponse { fatalError("not stubbed") }
        func refreshIdentity(itemId: String?) async throws -> PlaidService.IdentityRefreshResponse { fatalError("not stubbed") }
        func fetchTransactionsStatus() async throws -> PlaidService.TransactionsStatusResponse { fatalError("not stubbed") }
        func fetchItems() async throws -> PlaidService.ItemsResponse { fatalError("not stubbed") }
        func createLinkToken() async throws -> String { fatalError("not stubbed") }
    }

    private final class MockStoreService: ServerTransactionStoring {
        var pages: [PlaidService.ChangesResponse] = []
        private(set) var createdBatches: [[PlaidService.ServerTransactionUpload]] = []
        private(set) var patchedBatches: [[(id: String, patch: [String: Any])]] = []

        func fetchTransactionChanges(since: Int, limit: Int) async throws -> PlaidService.ChangesResponse {
            guard !pages.isEmpty else {
                return PlaidService.ChangesResponse(changes: [], next_seq: since, has_more: false)
            }
            return pages.removeFirst()
        }

        func createTransactions(_ rows: [PlaidService.ServerTransactionUpload]) async throws -> PlaidService.CreateTransactionsResponse {
            createdBatches.append(rows)
            return PlaidService.CreateTransactionsResponse(inserted: rows.count, skipped: 0, max_change_seq: 0)
        }

        func batchPatchTransactions(_ ops: [(id: String, patch: [String: Any])]) async throws -> PlaidService.BatchPatchResponse {
            patchedBatches.append(ops)
            return PlaidService.BatchPatchResponse(updated: ops.count, not_found: [])
        }
    }

    private var database: DatabaseManager!
    private var mockPlaid: MockPlaidService!
    private var mockStore: MockStoreService!
    private var serverSync: ServerTransactionSync!
    private var manager: PlaidSyncManager!

    override func setUpWithError() throws {
        database = try DatabaseManager.makeInMemoryForTesting()
        mockPlaid = MockPlaidService()
        mockStore = MockStoreService()
        let defaults = UserDefaults(suiteName: "PlaidSyncManagerTests-\(UUID().uuidString)")!
        defaults.set(true, forKey: ServerTransactionSync.enabledKey)
        serverSync = ServerTransactionSync(service: mockStore, database: database, defaults: defaults)
        manager = PlaidSyncManager(plaidService: mockPlaid, database: database, serverSync: serverSync)
    }

    override func tearDown() {
        serverSync.cancelPendingPush()
    }

    private static func stamp(secondsAgo: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(-secondsAgo))
    }

    private func storeChange(
        id: UUID = UUID(),
        description: String,
        plaidCategory: String? = nil,
        plaidDetailed: String? = nil,
        seq: Int
    ) -> PlaidService.ServerTransactionChange {
        PlaidService.ServerTransactionChange(
            id: id.uuidString.lowercased(),
            external_id: "ext-\(seq)",
            account_id: nil,
            item_id: nil,
            date: "2026-06-01",
            month: "2026-06",
            description: description,
            merchant: description,
            amount: -12.5,
            category_id: nil,
            is_manually_categorized: false,
            plaid_category: plaidCategory,
            plaid_category_detailed: plaidDetailed,
            imported_file_id: nil,
            source: "plaid",
            is_deleted: false,
            updated_at: Self.stamp(secondsAgo: 60),
            change_seq: seq
        )
    }

    // MARK: - Orchestration

    func testSyncIngestsThenPullsAndReportsSummary() async throws {
        mockStore.pages = [PlaidService.ChangesResponse(
            changes: [storeChange(description: "New Row", seq: 1)],
            next_seq: 1, has_more: false
        )]

        await manager.syncTransactions()

        XCTAssertEqual(mockPlaid.syncCallCount, 1, "the server ingest is always requested first")
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.lastSyncSummary, "1 pulled from server")
        let rows = try database.fetchAllTransactionsIncludingDeleted()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.amount, -12.5)
    }

    func testNewRowsAreCategorizedViaPlaidHintsAndPushedBack() async throws {
        // A rule-matching category for the engine to assign.
        var groceries = BudgetCategory(name: "Groceries", monthlyBudget: 500)
        try await database.dbQueue.write { try groceries.save($0) }
        var rule = CategorizationRule(keyword: "whole foods", categoryId: groceries.id, priority: 1, isUserDefined: true)
        try await database.dbQueue.write { try rule.save($0) }

        mockStore.pages = [PlaidService.ChangesResponse(
            changes: [storeChange(description: "WHOLE FOODS MARKET", seq: 1)],
            next_seq: 1, has_more: false
        )]

        await manager.syncTransactions()

        XCTAssertEqual(manager.lastSyncSummary, "1 pulled from server · 1 auto-categorized")
        let row = try XCTUnwrap(database.fetchAllTransactionsIncludingDeleted().first)
        XCTAssertEqual(row.categoryId, groceries.id, "keyword rule should assign via the hint flow")
        // The assignment is a local edit — it must push back to the server.
        XCTAssertFalse(mockStore.patchedBatches.isEmpty, "categorization pushes to the store")
    }

    func testServiceErrorSurfacesAsErrorMessage() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        mockPlaid.error = Boom()

        await manager.syncTransactions()

        XCTAssertEqual(manager.errorMessage, "boom")
        XCTAssertNil(manager.lastSyncSummary)
    }

    func testSummaryIsClearedAtStartOfNewSyncEvenOnEmptyResponse() async throws {
        mockStore.pages = []
        await manager.syncTransactions()
        XCTAssertEqual(manager.lastSyncSummary, "Up to date — no new transactions")

        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        mockPlaid.error = Boom()
        await manager.syncTransactions()
        XCTAssertNil(manager.lastSyncSummary, "stale summary must clear when the next sync starts")
    }

    // MARK: - Wire-shape tolerance

    func testSyncResponseDecodesBothWireShapes() throws {
        let legacy = #"{"added":[],"modified":[],"removed":[]}"#
        let modern = #"{"ingested":{"added":3,"modified":1,"removed":0,"skipped":2}}"#
        let l = try JSONDecoder().decode(PlaidService.SyncResponse.self, from: Data(legacy.utf8))
        XCTAssertNotNil(l.added)
        XCTAssertNil(l.ingested)
        let m = try JSONDecoder().decode(PlaidService.SyncResponse.self, from: Data(modern.utf8))
        XCTAssertNil(m.added)
        XCTAssertEqual(m.ingested?.added, 3)
    }

    // MARK: - Summary formatting (pure)

    func testLegacySummaryFormatting() {
        XCTAssertEqual(
            PlaidSyncManager.formatSyncSummary(added: 0, duplicates: 0, modified: 0, removed: 0, pending: 0),
            "Up to date — no new transactions"
        )
        XCTAssertEqual(
            PlaidSyncManager.formatSyncSummary(added: 5, duplicates: 2, modified: 1, removed: 1, pending: 3),
            "5 new · 2 duplicates skipped · 1 updated · 1 removed · 3 pending"
        )
    }
}
