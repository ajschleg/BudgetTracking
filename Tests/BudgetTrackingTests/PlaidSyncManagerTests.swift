import XCTest
@testable import BudgetTracking

/// Drives PlaidSyncManager.syncTransactions against an in-memory
/// DatabaseManager and a mock PlaidService. Verifies that the rows the
/// mock claims Plaid sent end up persisted as the right Transactions,
/// that duplicates are skipped, that pending rows are skipped, that
/// modifications and removals are honored, and that the lastSyncSummary
/// reflects what actually happened.
final class PlaidSyncManagerTests: XCTestCase {

    // MARK: - Test infrastructure

    /// Tiny mock that returns a canned SyncResponse and stubs everything
    /// else with a fatal — sync tests only exercise the sync method.
    private final class MockPlaidService: PlaidTransactionSyncing {
        var response: PlaidService.SyncResponse
        var error: Error?
        private(set) var syncCallCount = 0

        init(
            added: [PlaidService.PlaidTransaction] = [],
            modified: [PlaidService.PlaidTransaction] = [],
            removed: [PlaidService.RemovedTransaction] = [],
            error: Error? = nil
        ) {
            self.response = PlaidService.SyncResponse(added: added, modified: modified, removed: removed)
            self.error = error
        }

        func syncTransactions() async throws -> PlaidService.SyncResponse {
            syncCallCount += 1
            if let error { throw error }
            return response
        }

        // The methods below are not exercised by these tests; trapping
        // makes accidental coupling loud.
        func fetchAccounts() async throws -> [PlaidService.AccountListItem] { fatalError("not stubbed") }
        func removeItem(_ itemId: String) async throws { fatalError("not stubbed") }
        func removeAllItems() async throws -> PlaidService.BulkRemoveResponse { fatalError("not stubbed") }
        func refreshBalances(itemId: String?, minAgeSeconds: Int?) async throws -> PlaidService.BalancesRefreshResponse { fatalError("not stubbed") }
        func refreshIdentity(itemId: String?) async throws -> PlaidService.IdentityRefreshResponse { fatalError("not stubbed") }
        func fetchTransactionsStatus() async throws -> PlaidService.TransactionsStatusResponse { fatalError("not stubbed") }
        func fetchItems() async throws -> PlaidService.ItemsResponse { fatalError("not stubbed") }
        func createLinkToken() async throws -> String { fatalError("not stubbed") }
    }

    private static func plaidTxn(
        id: String,
        amount: Double,
        date: String = "2026-04-15",
        name: String = "Whole Foods Market",
        merchant: String? = "Whole Foods",
        pending: Bool = false,
        category: String? = nil,
        categoryDetailed: String? = nil
    ) -> PlaidService.PlaidTransaction {
        PlaidService.PlaidTransaction(
            transaction_id: id,
            account_id: "acct-1",
            item_id: "item-1",
            institution_name: "Test Bank",
            name: name,
            merchant_name: merchant,
            amount: amount,
            date: date,
            pending: pending,
            category: category,
            category_detailed: categoryDetailed
        )
    }

    /// Spin up a fresh in-memory DB + manager pair for each test so
    /// nothing leaks between cases.
    private func makeManager(
        added: [PlaidService.PlaidTransaction] = [],
        modified: [PlaidService.PlaidTransaction] = [],
        removed: [PlaidService.RemovedTransaction] = [],
        serviceError: Error? = nil
    ) throws -> (PlaidSyncManager, DatabaseManager, MockPlaidService) {
        let db = try DatabaseManager.makeInMemoryForTesting()
        let mock = MockPlaidService(added: added, modified: modified, removed: removed, error: serviceError)
        let manager = PlaidSyncManager(plaidService: mock, database: db)
        return (manager, db, mock)
    }

    private func activeTransactions(in db: DatabaseManager) throws -> [Transaction] {
        try db.fetchAllActiveTransactions()
    }

    // MARK: - Empty / no-op cases

    func testEmptyResponseDoesNotInsertAnything() async throws {
        let (manager, db, mock) = try makeManager()

        await manager.syncTransactions()

        XCTAssertEqual(mock.syncCallCount, 1)
        XCTAssertEqual(try activeTransactions(in: db).count, 0)
        XCTAssertEqual(manager.lastSyncSummary, "Up to date — no new transactions")
        XCTAssertNil(manager.errorMessage)
    }

    func testServiceErrorSurfacesAsErrorMessage() async throws {
        struct Boom: Error {}
        let (manager, db, _) = try makeManager(serviceError: Boom())

        await manager.syncTransactions()

        XCTAssertEqual(try activeTransactions(in: db).count, 0)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertNil(manager.lastSyncSummary)
    }

    // MARK: - Adds: data shape preservation

    func testAddedTransactionIsPersistedWithSignFlippedAndExternalIdSet() async throws {
        let (manager, db, _) = try makeManager(added: [
            Self.plaidTxn(id: "plaid-1", amount: 42.50, date: "2026-04-15", name: "Whole Foods", merchant: "Whole Foods"),
        ])

        await manager.syncTransactions()

        let stored = try activeTransactions(in: db)
        XCTAssertEqual(stored.count, 1)
        let txn = stored[0]
        XCTAssertEqual(txn.externalId, "plaid-1")
        XCTAssertEqual(txn.description, "Whole Foods")            // merchant_name preferred over name
        XCTAssertEqual(txn.merchant, "Whole Foods")
        XCTAssertEqual(txn.amount, -42.50, accuracy: 0.0001)      // Plaid + → app -
        XCTAssertEqual(txn.month, "2026-04")
        XCTAssertFalse(txn.isDeleted)
    }

    func testFallsBackToNameWhenMerchantNameIsNil() async throws {
        let (manager, db, _) = try makeManager(added: [
            Self.plaidTxn(id: "plaid-2", amount: 10, name: "RAW BANK MEMO LINE", merchant: nil),
        ])
        await manager.syncTransactions()
        let stored = try activeTransactions(in: db)
        XCTAssertEqual(stored.first?.description, "RAW BANK MEMO LINE")
        XCTAssertNil(stored.first?.merchant)
    }

    func testNegativePlaidAmountIsStoredAsPositiveIncome() async throws {
        // Plaid sends income/refunds as negative; app stores positive
        let (manager, db, _) = try makeManager(added: [
            Self.plaidTxn(id: "plaid-income", amount: -1500, name: "ACH PAYROLL"),
        ])
        await manager.syncTransactions()
        let stored = try activeTransactions(in: db)
        XCTAssertEqual(stored.first?.amount ?? 0, 1500, accuracy: 0.0001)
    }

    func testManyAddedTransactionsAllPersist() async throws {
        let plaidTxns = (1...50).map {
            Self.plaidTxn(id: "plaid-\($0)", amount: Double($0), date: "2026-04-\(String(format: "%02d", ($0 % 28) + 1))")
        }
        let (manager, db, _) = try makeManager(added: plaidTxns)
        await manager.syncTransactions()
        XCTAssertEqual(try activeTransactions(in: db).count, 50)
        XCTAssertEqual(manager.lastSyncSummary, "50 new")
    }

    // MARK: - Skipped cases

    func testPendingTransactionsAreSkipped() async throws {
        let (manager, db, _) = try makeManager(added: [
            Self.plaidTxn(id: "posted", amount: 10, pending: false),
            Self.plaidTxn(id: "pending-1", amount: 20, pending: true),
            Self.plaidTxn(id: "pending-2", amount: 30, pending: true),
        ])

        await manager.syncTransactions()

        let stored = try activeTransactions(in: db)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.externalId, "posted")
        XCTAssertEqual(manager.lastSyncSummary, "1 new · 2 pending")
    }

    func testDuplicateExternalIdsAreSkippedOnSecondSync() async throws {
        let (manager, db, mock) = try makeManager(added: [
            Self.plaidTxn(id: "plaid-1", amount: 25),
            Self.plaidTxn(id: "plaid-2", amount: 35),
        ])

        // First sync inserts both
        await manager.syncTransactions()
        XCTAssertEqual(try activeTransactions(in: db).count, 2)
        XCTAssertEqual(manager.lastSyncSummary, "2 new")

        // Plaid re-delivers the same batch (re-orgs, retries, etc.)
        mock.response = PlaidService.SyncResponse(
            added: [
                Self.plaidTxn(id: "plaid-1", amount: 25),
                Self.plaidTxn(id: "plaid-2", amount: 35),
                Self.plaidTxn(id: "plaid-3", amount: 99),  // genuinely new
            ],
            modified: [],
            removed: []
        )
        await manager.syncTransactions()

        XCTAssertEqual(try activeTransactions(in: db).count, 3)
        XCTAssertEqual(manager.lastSyncSummary, "1 new · 2 duplicates skipped")
    }

    func testDuplicatesArePerExternalId_NotPerAmount() async throws {
        // Two distinct Plaid IDs with the same amount should both persist
        let (manager, db, _) = try makeManager(added: [
            Self.plaidTxn(id: "plaid-A", amount: 10),
            Self.plaidTxn(id: "plaid-B", amount: 10),
        ])
        await manager.syncTransactions()
        XCTAssertEqual(try activeTransactions(in: db).count, 2)
    }

    // MARK: - Modifications

    func testModifiedTransactionUpdatesFieldsByExternalId() async throws {
        let (manager, db, mock) = try makeManager(added: [
            Self.plaidTxn(id: "plaid-1", amount: 10, name: "OLD NAME", merchant: "Old"),
        ])
        await manager.syncTransactions()

        // Plaid revises the same row
        mock.response = PlaidService.SyncResponse(
            added: [],
            modified: [
                Self.plaidTxn(id: "plaid-1", amount: 12.34, date: "2026-04-16", name: "NEW NAME", merchant: "New Merchant"),
            ],
            removed: []
        )
        await manager.syncTransactions()

        let stored = try activeTransactions(in: db)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].externalId, "plaid-1")
        XCTAssertEqual(stored[0].description, "New Merchant")
        XCTAssertEqual(stored[0].merchant, "New Merchant")
        XCTAssertEqual(stored[0].amount, -12.34, accuracy: 0.0001)
        XCTAssertEqual(manager.lastSyncSummary, "0 new · 1 updated")
    }

    func testPendingModificationsAreSkipped() async throws {
        let (manager, db, mock) = try makeManager(added: [
            Self.plaidTxn(id: "plaid-1", amount: 10, name: "ORIGINAL"),
        ])
        await manager.syncTransactions()

        mock.response = PlaidService.SyncResponse(
            added: [],
            modified: [Self.plaidTxn(id: "plaid-1", amount: 9999, name: "PENDING NEW", pending: true)],
            removed: []
        )
        await manager.syncTransactions()

        let stored = try activeTransactions(in: db)
        XCTAssertEqual(stored[0].description, "Whole Foods")  // unchanged from first sync
        XCTAssertEqual(stored[0].amount, -10, accuracy: 0.0001)
    }

    // MARK: - Removals

    func testRemovedTransactionIsSoftDeleted() async throws {
        let (manager, db, mock) = try makeManager(added: [
            Self.plaidTxn(id: "plaid-1", amount: 10),
            Self.plaidTxn(id: "plaid-2", amount: 20),
        ])
        await manager.syncTransactions()
        XCTAssertEqual(try activeTransactions(in: db).count, 2)

        mock.response = PlaidService.SyncResponse(
            added: [],
            modified: [],
            removed: [PlaidService.RemovedTransaction(transaction_id: "plaid-1", item_id: "item-1")]
        )
        await manager.syncTransactions()

        let active = try activeTransactions(in: db)
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.externalId, "plaid-2")
        XCTAssertEqual(manager.lastSyncSummary, "0 new · 1 removed")
    }

    // MARK: - Combined batches

    func testAddModifyRemoveAllInOneBatch() async throws {
        // Seed: two existing rows
        let (manager, db, mock) = try makeManager(added: [
            Self.plaidTxn(id: "keeper", amount: 10, name: "Keep"),
            Self.plaidTxn(id: "to-remove", amount: 15, name: "Goodbye"),
        ])
        await manager.syncTransactions()

        // Combined batch: 3 new, 1 modify, 1 remove, 1 duplicate
        mock.response = PlaidService.SyncResponse(
            added: [
                Self.plaidTxn(id: "new-1", amount: 1),
                Self.plaidTxn(id: "new-2", amount: 2),
                Self.plaidTxn(id: "new-3", amount: 3),
                Self.plaidTxn(id: "keeper", amount: 10),  // duplicate, skipped
            ],
            modified: [
                Self.plaidTxn(id: "keeper", amount: 12, name: "Keep But Updated", merchant: "Keep But Updated"),
            ],
            removed: [
                PlaidService.RemovedTransaction(transaction_id: "to-remove", item_id: "item-1"),
            ]
        )
        await manager.syncTransactions()

        let active = try activeTransactions(in: db)
        XCTAssertEqual(active.count, 4)  // 2 originals + 3 new − 1 removed = 4
        let externalIds = Set(active.compactMap(\.externalId))
        XCTAssertEqual(externalIds, ["keeper", "new-1", "new-2", "new-3"])
        XCTAssertEqual(manager.lastSyncSummary, "3 new · 1 duplicate skipped · 1 updated · 1 removed")

        // Confirm the modification took
        let keeper = try XCTUnwrap(active.first { $0.externalId == "keeper" })
        XCTAssertEqual(keeper.amount, -12, accuracy: 0.0001)
        XCTAssertEqual(keeper.description, "Keep But Updated")
    }

    // MARK: - Auto-categorization integration

    func testSyncedTransactionsRunThroughCategorizationRules() async throws {
        let (manager, db, _) = try makeManager(added: [
            Self.plaidTxn(id: "plaid-grocery", amount: 50, name: "Whole Foods", merchant: "Whole Foods"),
            Self.plaidTxn(id: "plaid-other", amount: 25, name: "Random Coffee Shop", merchant: "Random Coffee"),
        ])

        // Seed a category and a rule that matches "WHOLE FOODS"
        let groceries = BudgetCategory(name: "Groceries", monthlyBudget: 600)
        try db.saveCategory(groceries)
        try db.saveRule(CategorizationRule(keyword: "WHOLE FOODS", categoryId: groceries.id, priority: 1, isUserDefined: true))

        await manager.syncTransactions()

        let stored = try activeTransactions(in: db)
        let wholeFoodsRow = stored.first { $0.externalId == "plaid-grocery" }
        let coffeeRow = stored.first { $0.externalId == "plaid-other" }

        XCTAssertEqual(wholeFoodsRow?.categoryId, groceries.id, "Plaid txn matching WHOLE FOODS rule should be auto-categorized")
        XCTAssertNil(coffeeRow?.categoryId, "Unmatched Plaid txn must be left uncategorized")
    }

    // MARK: - Date parsing

    func testInvalidDateFallsBackToNowButStillStores() async throws {
        let before = Date()
        let (manager, db, _) = try makeManager(added: [
            Self.plaidTxn(id: "plaid-bad-date", amount: 10, date: "not-a-date"),
        ])
        await manager.syncTransactions()
        let after = Date()

        let stored = try activeTransactions(in: db)
        XCTAssertEqual(stored.count, 1)
        XCTAssertGreaterThanOrEqual(stored[0].date, before.addingTimeInterval(-1))
        XCTAssertLessThanOrEqual(stored[0].date, after.addingTimeInterval(1))
    }

    // MARK: - Idempotence + summary clearing

    func testSummaryIsClearedAtStartOfNewSyncEvenOnEmptyResponse() async throws {
        let (manager, _, mock) = try makeManager(added: [Self.plaidTxn(id: "x", amount: 1)])
        await manager.syncTransactions()
        XCTAssertEqual(manager.lastSyncSummary, "1 new")

        mock.response = PlaidService.SyncResponse(added: [], modified: [], removed: [])
        await manager.syncTransactions()
        XCTAssertEqual(manager.lastSyncSummary, "Up to date — no new transactions")
    }
}
