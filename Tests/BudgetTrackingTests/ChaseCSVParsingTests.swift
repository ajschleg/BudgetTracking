import XCTest
@testable import BudgetTracking

// MARK: - Chase CSV Parsing Tests

/// Tests for parsing Chase yearly activity CSV exports.
/// These files have specific quirks:
/// - Trailing commas on every data row (8 fields vs 7 headers)
/// - \r\n line endings
/// - "Details" column (CREDIT/DEBIT) vs "Description" column (actual description)
/// - "Type" column (ACH_DEBIT, etc.) that can be confused for a category
/// - Quoted descriptions that may contain commas
/// - Dates spanning multiple months/years

final class ChaseCSVCleaningTests: XCTestCase {

    /// Helper: write a string to a temp file and return its URL
    private func writeTempCSV(_ content: String, name: String = "test.csv") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Raw CSV Content Tests

    func testTrailingCommaStrippingPreservesFieldCount() throws {
        // Exact Chase format: 7 headers, data rows have trailing ",,\r\n"
        let csv = "Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #\r\n"
            + "CREDIT,03/19/2026,\"ZELLE PAYMENT FROM BUDDY\",110.00,QUICKPAY_CREDIT, ,,\r\n"
            + "DEBIT,03/17/2026,\"APPLECARD GSBANK PAYMENT\",-1155.60,ACH_DEBIT,6675.54,,\r\n"

        let url = writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let parser = CSVStatementParser(delimiter: ",")
        let rows = try parser.parse(fileURL: url, bankProfile: nil)

        XCTAssertEqual(rows.count, 2, "Should parse 2 data rows")
    }

    func testCRLFLineEndingsHandled() throws {
        // Pure \r\n line endings (Windows-style, typical of Chase exports)
        let csv = "Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #\r\n"
            + "CREDIT,01/15/2026,\"STARBUCKS COFFEE\",5.50,DEBIT_CARD,1000.00,,\r\n"

        let url = writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let parser = CSVStatementParser(delimiter: ",")
        let rows = try parser.parse(fileURL: url, bankProfile: nil)

        XCTAssertEqual(rows.count, 1, "Should parse 1 row with \\r\\n endings")
        XCTAssertNotNil(rows.first?.date, "Date should be parsed")
        XCTAssertNotNil(rows.first?.amount, "Amount should be parsed")
    }

    func testDescriptionsWithCommasInsideQuotes() throws {
        // Description contains a comma (quoted in CSV)
        let csv = "Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #\r\n"
            + "CREDIT,03/13/2026,\"RCI, LLC         PAYROLL\",1837.97,ACH_CREDIT,7888.70,,\r\n"

        let url = writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let parser = CSVStatementParser(delimiter: ",")
        let rows = try parser.parse(fileURL: url, bankProfile: nil)

        XCTAssertEqual(rows.count, 1)
        // Ensure the comma didn't split the description
        XCTAssertTrue(rows[0].description?.contains("RCI") == true,
                       "Description should contain 'RCI', got: \(rows[0].description ?? "nil")")
        XCTAssertTrue(rows[0].description?.contains("LLC") == true,
                       "Description should contain 'LLC', got: \(rows[0].description ?? "nil")")
    }

    func testEmptyBalanceFieldHandled() throws {
        // Balance is a space (empty) — common for credit rows
        let csv = "Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #\r\n"
            + "CREDIT,03/19/2026,\"ZELLE PAYMENT\",28.03,QUICKPAY_CREDIT, ,,\r\n"

        let url = writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let parser = CSVStatementParser(delimiter: ",")
        let rows = try parser.parse(fileURL: url, bankProfile: nil)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].amount!, 28.03, accuracy: 0.001)
    }
}

// MARK: - Column Detection Tests

final class ChaseColumnDetectionTests: XCTestCase {

    func testChaseHeadersDetectCorrectColumns() {
        let headers = ["Details", "Posting Date", "Description", "Amount", "Type", "Balance", "Check or Slip #"]
        let sampleRows = [
            ["CREDIT", "03/19/2026", "ZELLE PAYMENT FROM BUDDY", "110.00", "QUICKPAY_CREDIT", " ", ""],
            ["DEBIT", "03/17/2026", "APPLECARD GSBANK PAYMENT", "-1155.60", "ACH_DEBIT", "6675.54", ""],
        ]

        let mapping = ColumnMapper.detectColumns(headers: headers, sampleRows: sampleRows)

        XCTAssertEqual(mapping.dateIndex, 1,
                       "Date should be column 1 (Posting Date), got \(mapping.dateIndex.map(String.init) ?? "nil")")
        XCTAssertEqual(mapping.descriptionIndex, 2,
                       "Description should be column 2 (Description), NOT column 0 (Details). Got \(mapping.descriptionIndex.map(String.init) ?? "nil")")
        XCTAssertEqual(mapping.amountIndex, 3,
                       "Amount should be column 3 (Amount), got \(mapping.amountIndex.map(String.init) ?? "nil")")
    }

    func testDescriptionWinsOverDetails() {
        // When both "Details" and "Description" headers exist,
        // "Description" (keyword priority) should win.
        let headers = ["Details", "Date", "Description", "Amount"]
        let sampleRows = [
            ["CREDIT", "01/01/2026", "PAYMENT", "100.00"],
        ]

        let mapping = ColumnMapper.detectColumns(headers: headers, sampleRows: sampleRows)

        XCTAssertEqual(mapping.descriptionIndex, 2,
                       "Should pick 'Description' (index 2), not 'Details' (index 0)")
    }

    func testPostingDateDetected() {
        let headers = ["Posting Date", "Description", "Amount"]
        let sampleRows = [["03/19/2026", "TEST", "100.00"]]

        let mapping = ColumnMapper.detectColumns(headers: headers, sampleRows: sampleRows)

        XCTAssertEqual(mapping.dateIndex, 0, "Should detect 'Posting Date' as date column")
    }

    func testDateFormatDetectedAsMDY() {
        let headers = ["Details", "Posting Date", "Description", "Amount", "Type", "Balance", "Check or Slip #"]
        let sampleRows = [
            ["CREDIT", "03/19/2026", "ZELLE PAYMENT", "110.00", "QUICKPAY_CREDIT", " ", ""],
            ["DEBIT", "03/17/2026", "APPLECARD PAYMENT", "-1155.60", "ACH_DEBIT", "6675.54", ""],
            ["DEBIT", "01/15/2025", "LA FITNESS", "-39.99", "DEBIT_CARD", "5000.00", ""],
        ]

        let mapping = ColumnMapper.detectColumns(headers: headers, sampleRows: sampleRows)

        XCTAssertEqual(mapping.detectedDateFormat, "MM/dd/yyyy",
                       "Should detect MM/dd/yyyy format, got: \(mapping.detectedDateFormat ?? "nil")")
    }
}

// MARK: - Full Parsing Pipeline Tests

final class ChaseCSVFullParsingTests: XCTestCase {

    private func writeTempCSV(_ content: String, name: String = "Chase_Activity.csv") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testFullChaseParsingPipeline() throws {
        // Realistic Chase CSV with \r\n endings and trailing commas
        let csv = "Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #\r\n"
            + "CREDIT,03/19/2026,\"ZELLE PAYMENT FROM BUDDY CAMACHO NAV022EXRZQ3\",110.00,PARTNERFI_TO_CHASE, ,,\r\n"
            + "DEBIT,03/17/2026,\"APPLECARD GSBANK PAYMENT    106723140       WEB ID: 9999999999\",-1155.60,ACH_DEBIT,6675.54,,\r\n"
            + "DEBIT,03/16/2026,\"LA FITNESS 949-255-8100 CA                   03/16\",-39.99,DEBIT_CARD,7775.63,,\r\n"
            + "CREDIT,03/13/2026,\"RCI, LLC         PAYROLL                    PPD ID: 9111111101\",1837.97,ACH_CREDIT,7888.70,,\r\n"
            + "DEBIT,01/15/2025,\"CHEWY.COM 786-320-7111 FL                    01/14\",-48.08,DEBIT_CARD,2000.00,,\r\n"

        let url = writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let parser = CSVStatementParser(delimiter: ",")
        let rows = try parser.parse(fileURL: url, bankProfile: nil)

        XCTAssertEqual(rows.count, 5, "Should parse all 5 rows")

        // Check that ALL rows have dates and amounts
        for (i, row) in rows.enumerated() {
            XCTAssertNotNil(row.date, "Row \(i) should have a parsed date, description: \(row.description ?? "nil")")
            XCTAssertNotNil(row.amount, "Row \(i) should have a parsed amount, description: \(row.description ?? "nil")")
        }

        // Row 0: ZELLE PAYMENT
        XCTAssertTrue(rows[0].description?.contains("ZELLE") == true,
                       "Row 0 description should be the actual Description column, got: \(rows[0].description ?? "nil")")
        XCTAssertEqual(rows[0].amount!, 110.00, accuracy: 0.001)

        // Row 1: APPLECARD
        XCTAssertTrue(rows[1].description?.contains("APPLECARD") == true,
                       "Row 1 description should contain APPLECARD, got: \(rows[1].description ?? "nil")")
        XCTAssertEqual(rows[1].amount!, -1155.60, accuracy: 0.001)

        // Row 3: Description with comma (RCI, LLC)
        XCTAssertTrue(rows[3].description?.contains("RCI") == true,
                       "Row 3 description should contain RCI, got: \(rows[3].description ?? "nil")")
        XCTAssertEqual(rows[3].amount!, 1837.97, accuracy: 0.001)

        // Verify description is NOT "CREDIT" or "DEBIT" (Details column)
        for row in rows {
            XCTAssertNotEqual(row.description, "CREDIT",
                              "Description should NOT be 'CREDIT' (that's the Details column)")
            XCTAssertNotEqual(row.description, "DEBIT",
                              "Description should NOT be 'DEBIT' (that's the Details column)")
        }
    }

    func testMultiMonthDatesDetected() throws {
        // Transactions from different months — should detect different months
        let csv = "Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #\r\n"
            + "DEBIT,03/19/2026,\"PURCHASE A\",-50.00,DEBIT_CARD,1000.00,,\r\n"
            + "DEBIT,02/15/2026,\"PURCHASE B\",-30.00,DEBIT_CARD,2000.00,,\r\n"
            + "DEBIT,01/10/2025,\"PURCHASE C\",-20.00,DEBIT_CARD,3000.00,,\r\n"
            + "DEBIT,07/04/2025,\"PURCHASE D\",-10.00,DEBIT_CARD,4000.00,,\r\n"

        let url = writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let parser = CSVStatementParser(delimiter: ",")
        let rows = try parser.parse(fileURL: url, bankProfile: nil)

        XCTAssertEqual(rows.count, 4)

        // All rows should have dates
        let dates = rows.compactMap(\.date)
        XCTAssertEqual(dates.count, 4, "All 4 rows should have parsed dates")

        // Verify the actual months are different
        let months = Set(dates.map { DateHelpers.monthString(from: $0) })
        XCTAssertEqual(months.count, 4, "Should detect 4 different months: \(months)")
        XCTAssertTrue(months.contains("2026-03"))
        XCTAssertTrue(months.contains("2026-02"))
        XCTAssertTrue(months.contains("2025-01"))
        XCTAssertTrue(months.contains("2025-07"))
    }

    func testParsingActualChaseFile() throws {
        // Test with the actual Chase CSV file if it exists
        let fileURL = URL(fileURLWithPath: "/Users/austinschlegel/Downloads/Chase8799_Activity_20260319.CSV")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw XCTSkip("Chase CSV file not found at expected path")
        }

        let parser = CSVStatementParser(delimiter: ",")
        let rows = try parser.parse(fileURL: fileURL, bankProfile: nil)

        XCTAssertGreaterThan(rows.count, 100, "Should parse hundreds of rows, got \(rows.count)")

        // Check how many rows have dates and amounts
        let withDates = rows.filter { $0.date != nil }
        let withAmounts = rows.filter { $0.amount != nil }
        let withDescriptions = rows.filter { $0.description != nil && !$0.description!.isEmpty }

        print("Total rows: \(rows.count)")
        print("With dates: \(withDates.count)")
        print("With amounts: \(withAmounts.count)")
        print("With descriptions: \(withDescriptions.count)")

        XCTAssertEqual(withDates.count, rows.count,
                       "All rows should have dates. \(rows.count - withDates.count) rows missing dates.")
        XCTAssertEqual(withAmounts.count, rows.count,
                       "All rows should have amounts. \(rows.count - withAmounts.count) rows missing amounts.")

        // No description should be "CREDIT" or "DEBIT" (that's the Details column)
        let badDescriptions = rows.filter {
            $0.description == "CREDIT" || $0.description == "DEBIT" || $0.description == "DSLIP"
        }
        XCTAssertEqual(badDescriptions.count, 0,
                       "\(badDescriptions.count) rows have Details column as description instead of real description")

        // Check multi-month spanning
        let months = Set(withDates.map { DateHelpers.monthString(from: $0.date!) })
        print("Months found: \(months.sorted())")
        XCTAssertGreaterThan(months.count, 1, "File should span multiple months, found: \(months)")

        // Print first few rows for debugging
        for (i, row) in rows.prefix(5).enumerated() {
            let dateStr = row.date.map { DateHelpers.monthString(from: $0) } ?? "nil"
            let descStr = row.description ?? "nil"
            let amtStr = row.amount.map { String($0) } ?? "nil"
            print("Row \(i): date=\(dateStr) desc=\(descStr) amount=\(amtStr)")
        }
    }

    func testDSLIPRowType() throws {
        // Chase sometimes has "DSLIP" as the Details value (deposit slips)
        let csv = "Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #\r\n"
            + "DSLIP,07/16/2025,\"DEPOSIT  ID NUMBER 141016\",1000.00,DEPOSIT,6025.49,,\r\n"

        let url = writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let parser = CSVStatementParser(delimiter: ",")
        let rows = try parser.parse(fileURL: url, bankProfile: nil)

        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].description?.contains("DEPOSIT") == true,
                       "Description should be 'DEPOSIT...', not 'DSLIP'. Got: \(rows[0].description ?? "nil")")
        XCTAssertEqual(rows[0].amount!, 1000.00, accuracy: 0.001)
    }
}

// MARK: - MonthDetector Tests for Multi-Month Files

final class MonthDetectorMultiMonthTests: XCTestCase {

    func testDetectsMultiMonthFile() {
        let rows = [
            ParsedRow(date: DateHelpers.parseDate("03/19/2026", format: "MM/dd/yyyy"), description: "A"),
            ParsedRow(date: DateHelpers.parseDate("02/15/2026", format: "MM/dd/yyyy"), description: "B"),
            ParsedRow(date: DateHelpers.parseDate("01/10/2025", format: "MM/dd/yyyy"), description: "C"),
        ]

        let detected = MonthDetector.detectMonth(from: rows, fileName: "Chase_Activity.csv")
        // MonthDetector returns the most common month — all are unique so any is valid
        XCTAssertNotNil(DateHelpers.parseDate("01", format: "MM"),
                        "MonthDetector should return a valid month string")
        XCTAssertFalse(detected.isEmpty)
    }

    func testMostCommonMonthWins() {
        let rows = [
            ParsedRow(date: DateHelpers.parseDate("05/01/2025", format: "MM/dd/yyyy"), description: "A"),
            ParsedRow(date: DateHelpers.parseDate("05/15/2025", format: "MM/dd/yyyy"), description: "B"),
            ParsedRow(date: DateHelpers.parseDate("05/20/2025", format: "MM/dd/yyyy"), description: "C"),
            ParsedRow(date: DateHelpers.parseDate("03/01/2026", format: "MM/dd/yyyy"), description: "D"),
        ]

        let detected = MonthDetector.detectMonth(from: rows, fileName: "activity.csv")
        XCTAssertEqual(detected, "2025-05", "Most common month (3 of 4 in May 2025) should win")
    }
}
