import Foundation
import PDFKit

struct PDFStatementParser: StatementParser {
    func parse(fileURL: URL, bankProfile: BankProfile?) throws -> [ParsedRow] {
        guard fileURL.startAccessingSecurityScopedResource() || true else {
            throw ParserError.parseFailure("Cannot access file")
        }
        defer { fileURL.stopAccessingSecurityScopedResource() }

        guard let document = PDFDocument(url: fileURL) else {
            throw ParserError.parseFailure("Could not open PDF")
        }

        var allText = ""
        for i in 0..<document.pageCount {
            if let page = document.page(at: i), let text = page.string {
                allText += text + "\n"
            }
        }

        guard !allText.isEmpty else {
            throw ParserError.noData
        }

        // Detect statement year from header (e.g., "January 27, 2026 through February 24, 2026")
        let year = detectYear(from: allText)

        return parseTransactionsFromText(allText, year: year)
    }

    private func detectYear(from text: String) -> Int {
        // Look for "through ... YYYY" or "January ... YYYY" etc.
        let yearPattern = #"(?:through|thru|ending)\s+\w+\s+\d{1,2},?\s+(\d{4})"#
        if let regex = try? NSRegularExpression(pattern: yearPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text),
           let year = Int(text[range])
        {
            return year
        }
        // Fallback: look for any 4-digit year in the first 500 chars
        let header = String(text.prefix(500))
        let fallbackPattern = #"\b(20\d{2})\b"#
        if let regex = try? NSRegularExpression(pattern: fallbackPattern),
           let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
           let range = Range(match.range(at: 1), in: header),
           let year = Int(header[range])
        {
            return year
        }
        return Calendar.current.component(.year, from: Date())
    }

    private func parseTransactionsFromText(_ text: String, year: Int) -> [ParsedRow] {
        let lines = text.components(separatedBy: .newlines)
        var rows: [ParsedRow] = []

        // Pattern 1: "MM/DD DESCRIPTION AMOUNT BALANCE" (Chase checking)
        // The amount and balance are at the end, both are decimal numbers
        // Amount can be negative. Balance follows amount.
        let chasePattern = #"^(\d{1,2}/\d{1,2})\s+(.+?)\s+(-?[\d,]+\.\d{2})\s+(-?[\d,]+\.\d{2})\s*$"#

        // Pattern 2: "MM/DD/YYYY DESCRIPTION AMOUNT" (generic 3-column)
        let genericPattern = #"^(\d{1,2}/\d{1,2}/\d{2,4})\s+(.+?)\s+(-?\$?[\d,]+\.\d{2})\s*$"#

        // Pattern 3: "MM/DD MM/DD DESCRIPTION AMOUNT BALANCE" (some banks show post date + txn date)
        let dualDatePattern = #"^(\d{1,2}/\d{1,2})\s+\d{1,2}/\d{1,2}\s+(.+?)\s+(-?[\d,]+\.\d{2})\s+(-?[\d,]+\.\d{2})\s*$"#

        let chaseRegex = try? NSRegularExpression(pattern: chasePattern)
        let genericRegex = try? NSRegularExpression(pattern: genericPattern)
        let dualDateRegex = try? NSRegularExpression(pattern: dualDatePattern)

        // Track whether we're in the transaction section
        var inTransactionSection = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Detect start/end of transaction sections
            let upper = trimmed.uppercased()
            if upper.contains("TRANSACTION DETAIL") || upper.contains("TRANSACTIONS") {
                inTransactionSection = true
                continue
            }
            if upper.contains("IN CASE OF ERRORS") ||
               upper.contains("THIS PAGE INTENTIONALLY") ||
               upper.contains("MONTHLY SERVICE FEE WAS") {
                inTransactionSection = false
                continue
            }

            // Skip non-transaction lines
            if upper.contains("BEGINNING BALANCE") ||
               upper.contains("ENDING BALANCE") ||
               upper.contains("DATE") && upper.contains("DESCRIPTION") && upper.contains("AMOUNT") {
                continue
            }

            let range = NSRange(trimmed.startIndex..., in: trimmed)

            // Try dual-date pattern first (e.g., "01/30 01/30 Payment To Chase...")
            if let regex = dualDateRegex,
               let match = regex.firstMatch(in: trimmed, range: range)
            {
                if let row = extractRow(from: trimmed, match: match, dateGroup: 1, descGroup: 2, amountGroup: 3, year: year) {
                    rows.append(row)
                    continue
                }
            }

            // Try Chase 4-column pattern: DATE DESC AMOUNT BALANCE
            if let regex = chaseRegex,
               let match = regex.firstMatch(in: trimmed, range: range)
            {
                if let row = extractRow(from: trimmed, match: match, dateGroup: 1, descGroup: 2, amountGroup: 3, year: year) {
                    rows.append(row)
                    continue
                }
            }

            // Try generic 3-column pattern: DATE DESC AMOUNT
            if let regex = genericRegex,
               let match = regex.firstMatch(in: trimmed, range: range)
            {
                if let row = extractRow(from: trimmed, match: match, dateGroup: 1, descGroup: 2, amountGroup: 3, year: 0) {
                    rows.append(row)
                    continue
                }
            }
        }

        return rows
    }

    private func extractRow(
        from text: String,
        match: NSTextCheckingResult,
        dateGroup: Int,
        descGroup: Int,
        amountGroup: Int,
        year: Int
    ) -> ParsedRow? {
        guard let dateRange = Range(match.range(at: dateGroup), in: text),
              let descRange = Range(match.range(at: descGroup), in: text),
              let amtRange = Range(match.range(at: amountGroup), in: text)
        else { return nil }

        let dateStr = String(text[dateRange])
        let desc = String(text[descRange]).trimmingCharacters(in: .whitespaces)
        let amtStr = String(text[amtRange])

        // Skip summary/header lines that look like transactions
        let upperDesc = desc.uppercased()
        if upperDesc.hasPrefix("TOTAL") ||
           upperDesc.hasPrefix("BEGINNING") ||
           upperDesc.hasPrefix("ENDING") ||
           upperDesc.hasPrefix("CHECK NUMBER") {
            return nil
        }

        var date: Date?

        // Try MM/DD format (append year)
        if dateStr.count <= 5 && year > 0 {
            let fullDate = "\(dateStr)/\(year)"
            date = DateHelpers.parseDate(fullDate, format: "MM/dd/yyyy")
                ?? DateHelpers.parseDate(fullDate, format: "M/d/yyyy")
        }

        // Try full date formats
        if date == nil {
            for format in DateHelpers.commonDateFormats {
                if let d = DateHelpers.parseDate(dateStr, format: format) {
                    date = d
                    break
                }
            }
        }

        let amount = ColumnMapper.parseAmount(amtStr)

        return ParsedRow(
            date: date,
            description: desc.isEmpty ? nil : desc,
            amount: amount,
            rawColumns: ["Date": dateStr, "Description": desc, "Amount": amtStr]
        )
    }
}
