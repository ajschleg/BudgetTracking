import XCTest
@testable import BudgetTracking

/// Verifies the core dashboard invariant:
///   The "Overall Budget" number shown at the top of the dashboard must
///   equal the sum of the monthly budgets of the categories actually
///   rendered as bars below it. Any drift here means a user can hide
///   (or fail to hide) a category and end up with a total that doesn't
///   match what they're looking at.
final class DashboardBudgetInvariantTests: XCTestCase {

    // MARK: - Fixtures

    private func cat(_ name: String, _ budget: Double, hidden: Bool = false) -> BudgetCategory {
        BudgetCategory(
            id: UUID(),
            name: name,
            monthlyBudget: budget,
            colorHex: "#000000",
            sortOrder: 0,
            isHiddenFromDashboard: hidden,
            lastModifiedAt: Date(),
            isDeleted: false
        )
    }

    // MARK: - Empty / boundary cases

    func testEmptyCategoryListYieldsZeroTotal() {
        let split = DashboardViewModel.splitForDashboard([])
        XCTAssertEqual(split.totalBudget, 0)
        XCTAssertTrue(split.visible.isEmpty)
        XCTAssertTrue(split.hiddenIds.isEmpty)
    }

    func testAllVisibleCategoriesSumToTotal() {
        let cats = [
            cat("Groceries", 600),
            cat("Gas", 150),
            cat("Utilities", 300),
        ]
        let split = DashboardViewModel.splitForDashboard(cats)
        XCTAssertEqual(split.visible.count, 3)
        XCTAssertEqual(split.totalBudget, 1050)
        XCTAssertTrue(split.hiddenIds.isEmpty)
    }

    func testAllHiddenYieldsZeroTotal() {
        let cats = [
            cat("Credit Card Payments", 11_552, hidden: true),
            cat("Money Transfers", 2_500, hidden: true),
        ]
        let split = DashboardViewModel.splitForDashboard(cats)
        XCTAssertTrue(split.visible.isEmpty)
        XCTAssertEqual(split.totalBudget, 0)
        XCTAssertEqual(split.hiddenIds.count, 2)
    }

    // MARK: - Mixed visible / hidden

    func testHiddenBudgetsAreExcludedFromTotal() {
        let creditCard = cat("Credit Card Payments", 11_552, hidden: true)
        let transfers = cat("Money Transfers", 2_500, hidden: true)
        let groceries = cat("Groceries", 1_088)
        let mortgage = cat("Mortgage", 1_514)
        let split = DashboardViewModel.splitForDashboard([creditCard, transfers, groceries, mortgage])

        XCTAssertEqual(split.visible.map(\.name), ["Groceries", "Mortgage"])
        XCTAssertEqual(split.totalBudget, 2_602)
        XCTAssertEqual(split.hiddenIds, [creditCard.id, transfers.id])
    }

    func testHiddenIdsAreExposedSoTransactionsCanBeFiltered() {
        let visible = cat("Groceries", 600)
        let hidden1 = cat("Income", 0, hidden: true)
        let hidden2 = cat("Savings Transfer", 0, hidden: true)
        let split = DashboardViewModel.splitForDashboard([visible, hidden1, hidden2])

        XCTAssertEqual(split.hiddenIds, [hidden1.id, hidden2.id])
        XCTAssertFalse(split.hiddenIds.contains(visible.id))
    }

    /// `visibleIds` is what the dashboard's spending query uses as an
    /// allow-list. It must contain exactly the visible categories'
    /// IDs and no others, otherwise the dashboard total either drops
    /// real spending or includes spending from hidden / uncategorized
    /// rows.
    func testVisibleIdsExposesExactlyTheVisibleCategories() {
        let groceries = cat("Groceries", 600)
        let mortgage = cat("Mortgage", 1_500)
        let income = cat("Income", 0, hidden: true)
        let transfers = cat("Money Transfers", 2_500, hidden: true)
        let split = DashboardViewModel.splitForDashboard([groceries, income, mortgage, transfers])

        XCTAssertEqual(split.visibleIds, [groceries.id, mortgage.id])
        XCTAssertTrue(split.visibleIds.isDisjoint(with: split.hiddenIds))
    }

    // MARK: - The invariant itself

    /// Brute-force property check: across many randomly-shaped inputs,
    /// `totalBudget` must always equal the sum of the visible categories'
    /// `monthlyBudget`. This is the invariant the dashboard depends on.
    func testInvariantTotalAlwaysEqualsVisibleSum() {
        let names = ["Groceries", "Gas", "Utilities", "Travel", "Dining Out",
                     "Insurance", "Subscriptions", "Healthcare", "Shopping"]

        for trial in 0..<100 {
            var rng = SeededRNG(seed: UInt64(trial) &* 2_654_435_761)
            let count = Int.random(in: 0...20, using: &rng)
            let cats: [BudgetCategory] = (0..<count).map { _ in
                let name = names.randomElement(using: &rng) ?? "X"
                let budget = Double(Int.random(in: 0...5_000, using: &rng))
                let hidden = Bool.random(using: &rng)
                return cat(name, budget, hidden: hidden)
            }

            let split = DashboardViewModel.splitForDashboard(cats)
            let visibleSum = split.visible.reduce(0) { $0 + $1.monthlyBudget }

            XCTAssertEqual(
                split.totalBudget,
                visibleSum,
                "trial \(trial): totalBudget (\(split.totalBudget)) drifted from visible sum (\(visibleSum))"
            )

            // And every hidden category's budget must NOT contribute
            let hiddenSum = cats
                .filter { $0.isHiddenFromDashboard }
                .reduce(0) { $0 + $1.monthlyBudget }
            XCTAssertEqual(
                split.totalBudget + hiddenSum,
                cats.reduce(0) { $0 + $1.monthlyBudget },
                "trial \(trial): visible + hidden does not equal full input"
            )
        }
    }

    // MARK: - Regression: the $28k bug

    /// Direct regression for the case that motivated this test file:
    /// 21 visible categories totaling $8,120 and 8 hidden ones totaling
    /// $16,572 must produce a dashboard total of $8,120 — never $24k+.
    func testRegression_HiddenBudgetsDoNotLeakIntoDashboardTotal() {
        let visibleBudgets = [1_000.0, 330, 1_088, 800, 450, 250, 45, 79, 300, 201,
                              1_514, 42, 650, 600, 25, 238, 60, 28, 120, 200, 100]
        let hiddenBudgets = [11_552.0, 2_500, 0, 0, 0, 1_020, 1_500, 0]

        let visibleCats = visibleBudgets.enumerated().map { cat("v\($0.offset)", $0.element) }
        let hiddenCats = hiddenBudgets.enumerated().map { cat("h\($0.offset)", $0.element, hidden: true) }

        let split = DashboardViewModel.splitForDashboard(visibleCats + hiddenCats)

        XCTAssertEqual(split.totalBudget, 8_120)
        XCTAssertEqual(split.visible.count, 21)
        XCTAssertEqual(split.hiddenIds.count, 8)
    }
}

// MARK: - Deterministic RNG

/// Tiny seeded RNG so the property test is reproducible. Uses splitmix64.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0xDEADBEEF : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z &>> 31)
    }
}

// MARK: - Income Section

/// Verifies the dashboard's Income section computation. The behavior we
/// pin down here:
///   - Income is scoped to user-designated "income categories" (the $
///     toggle in Categories settings). Refunds, transfers, and Zelle
///     reimbursements never count, even when positive.
///   - Transactions with NULL `categoryId` never count as income.
///   - Negative amounts and soft-deleted rows are always excluded.
///   - Multiple categories can be marked as income (e.g. Employment +
///     Side Hustle); transactions in any of them count.
final class DashboardIncomeTests: XCTestCase {

    private let april = "2026-04"
    private let importedFileId = UUID()

    private func tx(
        amount: Double,
        month: String,
        categoryId: UUID? = nil,
        isDeleted: Bool = false,
        date: Date = Date()
    ) -> Transaction {
        Transaction(
            id: UUID(),
            date: date,
            description: "txn",
            merchant: nil,
            amount: amount,
            categoryId: categoryId,
            month: month,
            importedFileId: importedFileId,
            isDeleted: isDeleted
        )
    }

    // MARK: - Boundary cases

    func testEmptyTransactionsYieldsZero() {
        let snap = DashboardViewModel.incomeSnapshot(from: [], forMonth: april, incomeCategoryIds: [UUID()])
        XCTAssertEqual(snap.total, 0)
        XCTAssertTrue(snap.transactions.isEmpty)
    }

    /// If the user hasn't marked any category as income, the dashboard
    /// must report $0 — better to show nothing than to roll up
    /// transfers/refunds/Zelle as income.
    func testNoIncomeCategoriesMarkedYieldsZero() {
        let someCategory = UUID()
        let txns = [
            tx(amount: 1_000, month: april, categoryId: someCategory),
            tx(amount: 500, month: april, categoryId: someCategory),
        ]
        let snap = DashboardViewModel.incomeSnapshot(from: txns, forMonth: april, incomeCategoryIds: [])
        XCTAssertEqual(snap.total, 0)
        XCTAssertTrue(snap.transactions.isEmpty)
    }

    func testNegativeAmountsNeverCountEvenInIncomeCategory() {
        let incomeCat = UUID()
        let txns = [
            tx(amount: -100, month: april, categoryId: incomeCat),
            tx(amount: -42.50, month: april, categoryId: incomeCat),
            tx(amount: 500, month: april, categoryId: incomeCat),
        ]
        let snap = DashboardViewModel.incomeSnapshot(from: txns, forMonth: april, incomeCategoryIds: [incomeCat])
        XCTAssertEqual(snap.total, 500)
        XCTAssertEqual(snap.transactions.count, 1)
    }

    func testOtherMonthsAreExcluded() {
        let incomeCat = UUID()
        let txns = [
            tx(amount: 1_000, month: "2026-03", categoryId: incomeCat),
            tx(amount: 2_000, month: "2026-05", categoryId: incomeCat),
            tx(amount: 500, month: april, categoryId: incomeCat),
        ]
        let snap = DashboardViewModel.incomeSnapshot(from: txns, forMonth: april, incomeCategoryIds: [incomeCat])
        XCTAssertEqual(snap.total, 500)
        XCTAssertEqual(snap.transactions.count, 1)
    }

    func testSoftDeletedAreExcluded() {
        let incomeCat = UUID()
        let txns = [
            tx(amount: 1_000, month: april, categoryId: incomeCat, isDeleted: true),
            tx(amount: 500, month: april, categoryId: incomeCat),
        ]
        let snap = DashboardViewModel.incomeSnapshot(from: txns, forMonth: april, incomeCategoryIds: [incomeCat])
        XCTAssertEqual(snap.total, 500)
        XCTAssertEqual(snap.transactions.count, 1)
    }

    func testNullCategoryIdNeverCountsAsIncome() {
        let incomeCat = UUID()
        let txns = [
            tx(amount: 1_000, month: april, categoryId: nil),
            tx(amount: 500, month: april, categoryId: incomeCat),
        ]
        let snap = DashboardViewModel.incomeSnapshot(from: txns, forMonth: april, incomeCategoryIds: [incomeCat])
        XCTAssertEqual(snap.total, 500)
        XCTAssertEqual(snap.transactions.count, 1)
    }

    // MARK: - The user-reported bug

    /// Direct regression for the case the user reported: April 2026 had
    /// $29k of positive transactions, of which only ~$13k was actual
    /// employment income (Arthrex + RCI tagged to the "Income" category).
    /// The rest was Zelle reimbursements, ACH transfers, refund returns,
    /// and credit-card payment reversals — none of which is income. The
    /// dashboard had been showing them all (total $29k) after a previous
    /// fix; this test pins the new behavior down to exactly the income
    /// category amounts.
    func testRegression_OnlyTransactionsTaggedToIncomeCategoryCount() {
        let incomeCat = UUID()                  // user has marked "Income" with $
        let transfersCat = UUID()               // user has NOT marked "Money Transfers"
        let creditCardCat = UUID()              // user has NOT marked "Credit Card Payments"
        let groceriesCat = UUID()               // visible spending bucket; not income

        let txns = [
            tx(amount: 3_521.18, month: april, categoryId: incomeCat),     // Arthrex paycheck
            tx(amount: 7_429.89, month: april, categoryId: incomeCat),     // RCI paycheck
            tx(amount: 595.81, month: april, categoryId: incomeCat),       // Arthrex bonus
            tx(amount: 1_879.55, month: april, categoryId: transfersCat),  // ACH transfer in — NOT income
            tx(amount: 11_790.16, month: april, categoryId: creditCardCat),// CC payment-in — NOT income
            tx(amount: 342.38, month: april, categoryId: groceriesCat),    // IKEA refund — NOT income
            tx(amount: 17.00, month: april, categoryId: nil),              // Zelle, uncategorized — NOT income
            tx(amount: -300, month: april, categoryId: groceriesCat),      // spending — NOT income
        ]

        let snap = DashboardViewModel.incomeSnapshot(
            from: txns,
            forMonth: april,
            incomeCategoryIds: [incomeCat]
        )

        XCTAssertEqual(snap.total, 11_546.88, accuracy: 0.001)
        XCTAssertEqual(snap.transactions.count, 3)
        XCTAssertTrue(snap.transactions.allSatisfy { $0.categoryId == incomeCat })
    }

    func testMultipleIncomeCategories_BothCount() {
        let employment = UUID()
        let sideHustle = UUID()
        let transfers = UUID()

        let txns = [
            tx(amount: 5_000, month: april, categoryId: employment),
            tx(amount: 800, month: april, categoryId: sideHustle),
            tx(amount: 1_500, month: april, categoryId: transfers),  // not in income set
        ]

        let snap = DashboardViewModel.incomeSnapshot(
            from: txns,
            forMonth: april,
            incomeCategoryIds: [employment, sideHustle]
        )

        XCTAssertEqual(snap.total, 5_800)
        XCTAssertEqual(snap.transactions.count, 2)
    }

    // MARK: - Sort order

    func testTransactionsAreSortedMostRecentFirst() {
        let incomeCat = UUID()
        let day1 = ISO8601DateFormatter().date(from: "2026-04-01T12:00:00Z")!
        let day15 = ISO8601DateFormatter().date(from: "2026-04-15T12:00:00Z")!
        let day28 = ISO8601DateFormatter().date(from: "2026-04-28T12:00:00Z")!

        let txns = [
            tx(amount: 100, month: april, categoryId: incomeCat, date: day1),
            tx(amount: 200, month: april, categoryId: incomeCat, date: day28),
            tx(amount: 150, month: april, categoryId: incomeCat, date: day15),
        ]

        let snap = DashboardViewModel.incomeSnapshot(from: txns, forMonth: april, incomeCategoryIds: [incomeCat])
        XCTAssertEqual(snap.transactions.map(\.date), [day28, day15, day1])
    }

    // MARK: - Invariant

    /// Across any input, the snapshot's total must equal the sum of the
    /// transactions it returned, and every returned transaction must be
    /// in the income-category set, in the right month, positive, and not
    /// deleted. If this ever drifts, the dashboard's
    /// "Net (Income − Spending)" line silently lies to the user.
    func testInvariantTotalEqualsSumOfReturnedTransactions() {
        let incomeCats = [UUID(), UUID()]
        let nonIncomeCats = [UUID(), UUID(), UUID()]
        let allCats: [UUID?] = (incomeCats + nonIncomeCats).map { $0 as UUID? } + [nil]
        let incomeSet = Set(incomeCats)

        for trial in 0..<100 {
            var rng = SeededRNG(seed: UInt64(trial) &* 0xA5A5_A5A5_A5A5_A5A5)
            let count = Int.random(in: 0...30, using: &rng)
            let months = ["2026-03", "2026-04", "2026-05"]

            let txns: [Transaction] = (0..<count).map { _ in
                let month = months.randomElement(using: &rng) ?? april
                let amount = Double(Int.random(in: -1_000...1_000, using: &rng))
                let cat = allCats.randomElement(using: &rng) ?? nil
                let deleted = Bool.random(using: &rng)
                return tx(amount: amount, month: month, categoryId: cat, isDeleted: deleted)
            }

            let snap = DashboardViewModel.incomeSnapshot(from: txns, forMonth: april, incomeCategoryIds: incomeSet)
            let computedSum = snap.transactions.reduce(0) { $0 + $1.amount }
            XCTAssertEqual(snap.total, computedSum, accuracy: 0.0001,
                           "trial \(trial): total drifted from sum of returned transactions")

            for t in snap.transactions {
                XCTAssertEqual(t.month, april, "trial \(trial): wrong-month txn leaked through")
                XCTAssertGreaterThan(t.amount, 0, "trial \(trial): non-positive txn leaked through")
                XCTAssertFalse(t.isDeleted, "trial \(trial): deleted txn leaked through")
                XCTAssertNotNil(t.categoryId, "trial \(trial): NULL-category txn leaked through")
                XCTAssertTrue(incomeSet.contains(t.categoryId!),
                              "trial \(trial): non-income-category txn leaked through")
            }
        }
    }
}
