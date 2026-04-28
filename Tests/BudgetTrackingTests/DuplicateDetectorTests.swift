import XCTest
@testable import BudgetTracking

final class DuplicateDetectorTests: XCTestCase {

    // MARK: - Fixtures

    private let importedFileId = UUID()

    private func tx(
        amount: Double,
        date: String = "2026-04-22T04:00:00Z",
        description: String,
        externalId: String? = nil,
        importedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Transaction {
        Transaction(
            id: UUID(),
            date: ISO8601DateFormatter().date(from: date) ?? Date(),
            description: description,
            merchant: nil,
            amount: amount,
            month: String(date.prefix(7)),
            importedFileId: importedFileId,
            importedAt: importedAt,
            externalId: externalId
        )
    }

    // MARK: - normalize()

    func testNormalize_StripsAppleCardCashbackSuffix() {
        XCTAssertEqual(
            DuplicateDetector.normalize(
                "WHOLEFDS CRL 10404 14598 CLAY TERRACE BLVD CARMEL 46032 IN USA 2% $3.78"
            ),
            "WHOLEFDS CRL 10404 14598 CLAY TERRACE BLVD CARMEL 46032 IN USA"
        )
    }

    func testNormalize_StripsCashbackWithoutDecimal() {
        XCTAssertEqual(
            DuplicateDetector.normalize("KROGER #980 14800 HAZEL DELL 2% $1"),
            "KROGER #980 14800 HAZEL DELL"
        )
    }

    func testNormalize_DoesNotStripWhenSuffixMidString() {
        // "2% $3.78" elsewhere in the description must not be touched
        let s = "WEIRD MERCHANT 2% $3.78 SOMETHING"
        XCTAssertEqual(DuplicateDetector.normalize(s), s.trimmingCharacters(in: .whitespaces))
    }

    func testNormalize_PassThroughForNoSuffix() {
        XCTAssertEqual(DuplicateDetector.normalize("Whole Foods"), "Whole Foods")
        XCTAssertEqual(DuplicateDetector.normalize("  Whole Foods  "), "Whole Foods")
    }

    // MARK: - findDuplicates()

    func testEmptyInputYieldsNoGroups() {
        XCTAssertTrue(DuplicateDetector.findDuplicates(in: []).isEmpty)
    }

    func testNoDuplicatesAcrossDistinctTransactions() {
        let txns = [
            tx(amount: -10, description: "A"),
            tx(amount: -20, description: "B"),
            tx(amount: -10, description: "C"),  // same amount, different desc
        ]
        XCTAssertTrue(DuplicateDetector.findDuplicates(in: txns).isEmpty)
    }

    func testDifferentAmountSameDescription_NotADuplicate() {
        let txns = [
            tx(amount: -10, description: "Whole Foods"),
            tx(amount: -11, description: "Whole Foods"),
        ]
        XCTAssertTrue(DuplicateDetector.findDuplicates(in: txns).isEmpty)
    }

    func testDifferentDaySameAmountAndDescription_NotADuplicate() {
        let txns = [
            tx(amount: -10, date: "2026-04-22T04:00:00Z", description: "Whole Foods"),
            tx(amount: -10, date: "2026-04-23T04:00:00Z", description: "Whole Foods"),
        ]
        XCTAssertTrue(DuplicateDetector.findDuplicates(in: txns).isEmpty)
    }

    func testAppleCardCashbackPair_DetectedAsDuplicate() {
        let plain = tx(amount: -189.14, description: "WHOLEFDS CRL 10404 14598 CLAY TERRACE BLVD CARMEL 46032 IN USA")
        let withSuffix = tx(amount: -189.14, description: "WHOLEFDS CRL 10404 14598 CLAY TERRACE BLVD CARMEL 46032 IN USA 2% $3.78")
        let groups = DuplicateDetector.findDuplicates(in: [plain, withSuffix])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].transactions.count, 2)
        XCTAssertEqual(groups[0].dollarOvercount, 189.14, accuracy: 0.001)
    }

    func testIdenticalDescriptionsOnSameDay_DetectedAsDuplicate() {
        let a = tx(amount: -29, description: "LATE FEE")
        let b = tx(amount: -29, description: "LATE FEE")
        let groups = DuplicateDetector.findDuplicates(in: [a, b])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].transactions.count, 2)
    }

    func testThreeWayDuplicate_OneGroupTwoRowsToRemove() {
        let txns = (0..<3).map { _ in tx(amount: -100, description: "TARGET STORE") }
        let groups = DuplicateDetector.findDuplicates(in: txns)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].removableTransactions.count, 2)
        XCTAssertEqual(groups[0].dollarOvercount, 200, accuracy: 0.001)
    }

    // MARK: - pickKeeper() priority

    func testKeeperPriority_PlaidExternalIdWins() {
        let manual = tx(
            amount: -50, description: "AMAZON",
            importedAt: Date(timeIntervalSince1970: 1_000_000_000) // very early
        )
        let plaid = tx(
            amount: -50, description: "AMAZON",
            externalId: "plaid-tx-123",
            importedAt: Date(timeIntervalSince1970: 2_000_000_000) // later
        )
        let groups = DuplicateDetector.findDuplicates(in: [manual, plaid])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].keeperId, plaid.id, "Plaid-synced row must win even when imported later")
    }

    func testKeeperPriority_EarlierImportedAtWinsAmongManual() {
        let early = tx(
            amount: -50, description: "AMAZON",
            importedAt: Date(timeIntervalSince1970: 1_000_000_000)
        )
        let late = tx(
            amount: -50, description: "AMAZON",
            importedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let groups = DuplicateDetector.findDuplicates(in: [late, early])
        XCTAssertEqual(groups[0].keeperId, early.id)
    }

    // MARK: - summarize()

    func testSummary_ZeroGroupsZeroEverything() {
        let s = DuplicateDetector.summarize([])
        XCTAssertEqual(s, .init(groupCount: 0, duplicateRowCount: 0, dollarOvercount: 0))
    }

    func testSummary_AggregatesAcrossMultipleGroups() {
        let g1 = DuplicateDetector.findDuplicates(in: [
            tx(amount: -100, description: "X"),
            tx(amount: -100, description: "X"),
        ])
        let g2 = DuplicateDetector.findDuplicates(in: [
            tx(amount: -50, description: "Y"),
            tx(amount: -50, description: "Y"),
            tx(amount: -50, description: "Y"),
        ])
        let s = DuplicateDetector.summarize(g1 + g2)
        XCTAssertEqual(s.groupCount, 2)
        XCTAssertEqual(s.duplicateRowCount, 1 + 2)        // 1 extra in g1, 2 extras in g2
        XCTAssertEqual(s.dollarOvercount, 100 + 100, accuracy: 0.001)  // 100 + (50 × 2)
    }

    // MARK: - Real-world regression sample

    /// Mirrors the user's actual DB sample where the dashboard's
    /// Groceries section showed back-to-back Apple Card-style pairs.
    func testRegression_RealAppleCardSamplePairsAreCaught() {
        let txns: [Transaction] = [
            tx(amount: -189.14, description: "WHOLEFDS CRL 10404 14598 CLAY TERRACE BLVD CARMEL 46032 IN USA"),
            tx(amount: -189.14, description: "WHOLEFDS CRL 10404 14598 CLAY TERRACE BLVD CARMEL 46032 IN USA 2% $3.78"),
            tx(amount: -126.89, description: "TRADER JOE S #670 2902 W 86TH ST INDIANAPOLIS 46268 IN USA"),
            tx(amount: -126.89, description: "TRADER JOE S #670 2902 W 86TH ST INDIANAPOLIS 46268 IN USA 2% $2.54"),
            tx(amount: -19.25, description: "KROGER #980 14800 HAZEL DELL XING NOBLESVILLE 46062 IN USA"),
            tx(amount: -19.25, description: "KROGER #980 14800 HAZEL DELL XING NOBLESVILLE 46062 IN USA 2% $0.39"),
        ]
        let groups = DuplicateDetector.findDuplicates(in: txns)
        let summary = DuplicateDetector.summarize(groups)

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(summary.duplicateRowCount, 3)
        XCTAssertEqual(summary.dollarOvercount, 189.14 + 126.89 + 19.25, accuracy: 0.001)
    }
}
