import XCTest
import GRDB
@testable import BudgetTracking

/// Regression tests for upsertFromPeer's transaction merge logic. Each
/// test maps to a real LAN-sync bug we hit during the iOS port:
///
/// - testDistinctSameContent_KeptAsSeparateRows is the headline fix
///   (commit f300d8a). Two real grocery runs of the same merchant /
///   day / amount used to merge into one row, costing ~45% of
///   transactions in some categories.
/// - testSameExternalId_Merged confirms the kept dedup path: same
///   Plaid transaction imported via two devices is the same payment
///   and should land as one row.
/// - testSameUUID_Updated confirms the primary key path that ongoing
///   sync relies on.
/// - testOlderIncoming_NotApplied confirms the lastModifiedAt
///   conflict-resolution rule.
final class LANSyncDedupTests: XCTestCase {

    private var db: DatabaseManager!
    private var importedFileId: UUID!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try DatabaseManager.makeInMemoryForTesting()

        // Most tests need a parent ImportedFile because Transaction
        // has a NOT NULL FK to it. Seed one and reuse the id.
        importedFileId = UUID()
        let file = ImportedFile(
            id: importedFileId,
            fileName: "test.csv",
            fileSize: 100,
            month: "2026-04",
            transactionCount: 0,
            importedAt: Date()
        )
        _ = try db.upsertFromPeer(file)
    }

    override func tearDownWithError() throws {
        db = nil
        try super.tearDownWithError()
    }

    // MARK: - Distinct same-content (regression for f300d8a)

    func testDistinctSameContent_KeptAsSeparateRows() throws {
        // Two grocery runs at the same store on the same day for the
        // same amount. Both real, both have unique UUIDs, neither has
        // an externalId. The previous content-based dedup squashed
        // these into one row.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = makeTxn(
            description: "WHOLE FOODS MKT",
            amount: -48.93,
            date: date,
            month: "2026-04"
        )
        let b = makeTxn(
            description: "WHOLE FOODS MKT",
            amount: -48.93,
            date: date,
            month: "2026-04"
        )
        XCTAssertNotEqual(a.id, b.id)

        XCTAssertTrue(try db.upsertFromPeer(a))
        XCTAssertTrue(try db.upsertFromPeer(b))

        let count = try fetchTransactionCount()
        XCTAssertEqual(count, 2, "distinct grocery runs must remain as separate rows")
    }

    // MARK: - Same externalId (kept dedup behavior)

    func testSameExternalId_Merged() throws {
        // Same Plaid transaction arriving via two paths (e.g., both
        // devices imported the same Plaid feed). Their UUIDs differ
        // but externalId is identical and non-empty, so they are the
        // same real-world payment.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let plaidId = "plaid_txn_xyz"
        let a = makeTxn(
            description: "WHOLE FOODS MKT",
            amount: -48.93,
            date: date,
            month: "2026-04",
            externalId: plaidId
        )
        let b = makeTxn(
            description: "WHOLE FOODS MKT",
            amount: -48.93,
            date: date,
            month: "2026-04",
            externalId: plaidId,
            // newer to win the lastModifiedAt race
            lastModifiedAt: a.lastModifiedAt.addingTimeInterval(60)
        )

        XCTAssertTrue(try db.upsertFromPeer(a))
        XCTAssertTrue(try db.upsertFromPeer(b))

        XCTAssertEqual(try fetchTransactionCount(), 1, "same externalId must merge")
    }

    // The empty-string externalId case is unreachable in practice:
    // the transaction.externalId column has a UNIQUE constraint, so the
    // schema itself rejects two empty-string externalIds at insert time.
    // The nil-externalId equivalent is already covered by
    // testDistinctSameContent_KeptAsSeparateRows above.

    // MARK: - UUID match (the common ongoing-sync path)

    func testSameUUID_UpdatesExisting() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let original = makeTxn(
            description: "OLD DESCRIPTION",
            amount: -10,
            date: date,
            month: "2026-04"
        )
        XCTAssertTrue(try db.upsertFromPeer(original))

        var updated = original
        updated.description = "NEW DESCRIPTION"
        updated.lastModifiedAt = original.lastModifiedAt.addingTimeInterval(60)
        XCTAssertTrue(try db.upsertFromPeer(updated))

        XCTAssertEqual(try fetchTransactionCount(), 1)
        let stored = try fetchTransaction(id: original.id)
        XCTAssertEqual(stored?.description, "NEW DESCRIPTION")
    }

    // MARK: - Conflict resolution

    func testOlderIncoming_NotApplied() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = makeTxn(
            description: "CURRENT",
            amount: -10,
            date: date,
            month: "2026-04",
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_001_000)
        )
        XCTAssertTrue(try db.upsertFromPeer(newer))

        // Older incoming with the same UUID — should be rejected.
        var older = newer
        older.description = "STALE"
        older.lastModifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(try db.upsertFromPeer(older))

        let stored = try fetchTransaction(id: newer.id)
        XCTAssertEqual(stored?.description, "CURRENT")
    }

    // MARK: - Helpers

    private func makeTxn(
        description: String,
        amount: Double,
        date: Date,
        month: String,
        externalId: String? = nil,
        lastModifiedAt: Date = Date()
    ) -> Transaction {
        Transaction(
            id: UUID(),
            date: date,
            description: description,
            merchant: nil,
            amount: amount,
            categoryId: nil,
            isManuallyCategorized: false,
            month: month,
            importedFileId: importedFileId,
            importedAt: date,
            externalId: externalId,
            lastModifiedAt: lastModifiedAt,
            cloudKitRecordName: nil,
            cloudKitSystemFields: nil,
            isDeleted: false
        )
    }

    private func fetchTransactionCount() throws -> Int {
        try db.dbQueue.read { db in
            try Transaction.filter(Transaction.Columns.isDeleted == false).fetchCount(db)
        }
    }

    private func fetchTransaction(id: UUID) throws -> Transaction? {
        try db.dbQueue.read { db in
            try Transaction.fetchOne(db, key: id)
        }
    }
}
