import XCTest
@testable import BudgetTracking

final class ColumnMapperTests: XCTestCase {
    func testParseAmount() {
        XCTAssertEqual(ColumnMapper.parseAmount("$1,234.56"), 1234.56)
        XCTAssertEqual(ColumnMapper.parseAmount("-$50.00"), -50.0)
        XCTAssertEqual(ColumnMapper.parseAmount("(123.45)"), -123.45)
        XCTAssertEqual(ColumnMapper.parseAmount("100.00"), 100.0)
    }

    func testDetectColumns() {
        let headers = ["Transaction Date", "Description", "Amount"]
        let sampleRows = [
            ["01/15/2026", "WHOLE FOODS MARKET", "-45.67"],
            ["01/16/2026", "SHELL GAS STATION", "-32.10"],
        ]

        let mapping = ColumnMapper.detectColumns(headers: headers, sampleRows: sampleRows)
        XCTAssertEqual(mapping.dateIndex, 0)
        XCTAssertEqual(mapping.descriptionIndex, 1)
        XCTAssertEqual(mapping.amountIndex, 2)
    }

    func testDetectDateFormat() {
        let samples = ["01/15/2026", "02/28/2026", "12/31/2025"]
        let format = ColumnMapper.detectDateFormat(samples: samples)
        XCTAssertEqual(format, "MM/dd/yyyy")
    }
}

final class CategorizationEngineTests: XCTestCase {
    func testBasicCategorization() {
        let groceryId = UUID()
        let gasId = UUID()

        let rules = [
            CategorizationRule(keyword: "WHOLE FOODS", categoryId: groceryId, priority: 1),
            CategorizationRule(keyword: "SHELL", categoryId: gasId, priority: 0),
        ]

        let engine = CategorizationEngine(rules: rules, categories: [])

        let match1 = engine.categorize(description: "WHOLE FOODS MARKET #1234")
        XCTAssertEqual(match1?.categoryId, groceryId)

        let match2 = engine.categorize(description: "SHELL GAS STATION")
        XCTAssertEqual(match2?.categoryId, gasId)

        let match3 = engine.categorize(description: "RANDOM MERCHANT")
        XCTAssertNil(match3)
    }

    func testCaseInsensitive() {
        let id = UUID()
        let rules = [CategorizationRule(keyword: "starbucks", categoryId: id)]
        let engine = CategorizationEngine(rules: rules, categories: [])

        let match = engine.categorize(description: "STARBUCKS COFFEE #4521")
        XCTAssertEqual(match?.categoryId, id)
    }
}

final class DateHelpersTests: XCTestCase {
    func testMonthString() {
        let str = DateHelpers.monthString()
        let regex = try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}$")
        let range = NSRange(str.startIndex..., in: str)
        XCTAssertNotNil(regex.firstMatch(in: str, range: range))
    }

    func testPreviousNextMonth() {
        XCTAssertEqual(DateHelpers.previousMonth(from: "2026-03"), "2026-02")
        XCTAssertEqual(DateHelpers.nextMonth(from: "2026-03"), "2026-04")
        XCTAssertEqual(DateHelpers.previousMonth(from: "2026-01"), "2025-12")
    }

    func testDisplayMonth() {
        let display = DateHelpers.displayMonth("2026-03")
        XCTAssertTrue(display.contains("March"))
        XCTAssertTrue(display.contains("2026"))
    }
}

final class RuleLearnerTests: XCTestCase {
    func testExtractMerchantFromAppleCardFormat() {
        // Apple Card: "STORE NAME ADDRESS CITY ZIP STATE USA"
        let m1 = RuleLearner.extractMerchantName(
            from: "TRADER JOE S #670 2902 W 86TH ST INDIANAPOLIS 46268 IN USA"
        )
        XCTAssertEqual(m1, "TRADER JOE S")

        let m2 = RuleLearner.extractMerchantName(
            from: "WHOLEFDS CRL 10404 14598 CLAY TERRACE BLVD CARMEL 46032 IN USA"
        )
        XCTAssertEqual(m2, "WHOLEFDS CRL 10404")

        let m3 = RuleLearner.extractMerchantName(
            from: "STARBUCKS 8007827282 2401 UTAH AVE S SEATTLE 98134 WA USA"
        )
        XCTAssertEqual(m3, "STARBUCKS")

        let m4 = RuleLearner.extractMerchantName(
            from: "BUYER'S MARKET KOKOMO 3754 S. REED ROAD (US31) KOKOMO 46902 IN USA"
        )
        XCTAssertEqual(m4, "BUYER'S MARKET KOKOMO")
    }

    func testExtractMerchantStripsReturn() {
        let m = RuleLearner.extractMerchantName(
            from: "MENARDS CARMEL IN 2150 E GREYHOUND PASS CARMEL 46033 IN USA (RETURN)"
        )
        XCTAssertEqual(m, "MENARDS CARMEL IN")
    }

    func testExtractMerchantSimple() {
        let m = RuleLearner.extractMerchantName(from: "NETFLIX")
        XCTAssertEqual(m, "NETFLIX")
    }
}
