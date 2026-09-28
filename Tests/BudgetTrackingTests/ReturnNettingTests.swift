import XCTest
import GRDB
@testable import BudgetTracking

/// Covers how detected returns net against spending on the dashboard.
///
/// Regression: a refund larger than the month's purchases in its
/// category (typically a return of something bought last month) used
/// to make `fetchSpendingByCategory` drop the category entirely, so the
/// dashboard bar read $0 with no way to recover it. Dismissing the
/// return on the Insights page didn't help because the dashboard never
/// passed the dismissed set through.
final class ReturnNettingTests: XCTestCase {

    private var database: DatabaseManager!
    private var shopping: BudgetCategory!
    private var groceries: BudgetCategory!

    override func setUpWithError() throws {
        database = try DatabaseManager.makeInMemoryForTesting()
        shopping = BudgetCategory(name: "Shopping", monthlyBudget: 200, colorHex: "#000000", sortOrder: 0)
        groceries = BudgetCategory(name: "Groceries", monthlyBudget: 600, colorHex: "#000000", sortOrder: 1)
        try database.saveCategory(shopping)
        try database.saveCategory(groceries)
        // transaction.importedFileId is a foreign key; give the fixtures a file to hang off.
        try database.saveImportedFile(ImportedFile(id: fileId, fileName: "fixture.csv", fileSize: 0, month: "2026-09"))
    }

    private let fileId = UUID()

    private func txn(_ amount: Double, _ description: String, category: BudgetCategory, month: String = "2026-09") -> Transaction {
        Transaction(
            date: Date(),
            description: description,
            amount: amount,
            categoryId: category.id,
            month: month,
            importedFileId: fileId
        )
    }

    // MARK: - Per-category

    func testSameMonthReturnOffsetsPurchases() throws {
        try database.saveTransactions([
            txn(-100, "TJMAXX", category: shopping),
            txn(-50, "HOMEGOODS", category: shopping),
            txn(30, "TJMAXX (RETURN)", category: shopping),
        ])
        let spending = try database.fetchSpendingByCategory(forMonth: "2026-09")
        XCTAssertEqual(spending[shopping.id] ?? -1, 120, accuracy: 0.001)
    }

    func testRefundLargerThanPurchasesClampsToZeroInsteadOfDroppingCategory() throws {
        try database.saveTransactions([
            txn(-100, "TJMAXX", category: shopping),
            txn(1283.99, "WWW COSTCO COM (RETURN)", category: shopping),
            txn(-40, "KROGER", category: groceries),
        ])
        let spending = try database.fetchSpendingByCategory(forMonth: "2026-09")
        XCTAssertNotNil(spending[shopping.id], "net-positive category must still be present")
        XCTAssertEqual(spending[shopping.id]!, 0, accuracy: 0.001)
        XCTAssertEqual(spending[groceries.id]!, 40, accuracy: 0.001)
    }

    func testDismissedReturnStopsOffsettingSpending() throws {
        let refund = txn(1283.99, "WWW COSTCO COM (RETURN)", category: shopping)
        try database.saveTransactions([
            txn(-100, "TJMAXX", category: shopping),
            txn(30, "TJMAXX (RETURN)", category: shopping),
            refund,
        ])
        let spending = try database.fetchSpendingByCategory(
            forMonth: "2026-09", excludeReturnIds: [refund.id]
        )
        // Only the same-month TJ Maxx return nets; the dismissed Costco refund is ignored.
        XCTAssertEqual(spending[shopping.id]!, 70, accuracy: 0.001)
    }

    // MARK: - Headline total invariant

    func testTotalSpendingEqualsSumOfClampedCategoryNets() throws {
        let refund = txn(1283.99, "WWW COSTCO COM (RETURN)", category: shopping)
        try database.saveTransactions([
            txn(-100, "TJMAXX", category: shopping),
            refund,
            txn(-40, "KROGER", category: groceries),
            txn(-60, "ALDI", category: groceries),
        ])
        let ids: Set<UUID> = [shopping.id, groceries.id]

        // Refund exceeds Shopping purchases: Shopping clamps to 0, so the
        // headline must be Groceries alone, not 100 - 1283.99 + 100.
        let byCategory = try database.fetchSpendingByCategory(forMonth: "2026-09")
        let total = try database.fetchTotalSpending(forMonth: "2026-09", inCategoryIds: ids)
        XCTAssertEqual(total, 100, accuracy: 0.001)
        XCTAssertEqual(total, ids.reduce(0) { $0 + (byCategory[$1] ?? 0) }, accuracy: 0.001)

        // With the refund dismissed, both views agree again at 200.
        let byCategoryDismissed = try database.fetchSpendingByCategory(forMonth: "2026-09", excludeReturnIds: [refund.id])
        let totalDismissed = try database.fetchTotalSpending(forMonth: "2026-09", excludeReturnIds: [refund.id], inCategoryIds: ids)
        XCTAssertEqual(totalDismissed, 200, accuracy: 0.001)
        XCTAssertEqual(totalDismissed, ids.reduce(0) { $0 + (byCategoryDismissed[$1] ?? 0) }, accuracy: 0.001)
    }

    func testTotalSpendingRespectsCategoryFilter() throws {
        try database.saveTransactions([
            txn(-100, "TJMAXX", category: shopping),
            txn(-40, "KROGER", category: groceries),
        ])
        XCTAssertEqual(try database.fetchTotalSpending(forMonth: "2026-09", inCategoryIds: [groceries.id]), 40, accuracy: 0.001)
        XCTAssertEqual(try database.fetchTotalSpending(forMonth: "2026-09", inCategoryIds: []), 0, accuracy: 0.001)
        XCTAssertEqual(try database.fetchTotalSpending(forMonth: "2026-10", inCategoryIds: [shopping.id, groceries.id]), 0, accuracy: 0.001)
    }
}
