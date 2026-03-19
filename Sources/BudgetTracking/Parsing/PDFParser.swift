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

        let year = detectYear(from: allText)
        return parseTransactionsFromText(allText, year: year)
    }

    private func detectYear(from text: String) -> Int {
        let yearPattern = #"(?:through|thru|ending)\s+\w+\s+\d{1,2},?\s+(\d{4})"#
        if let regex = try? NSRegularExpression(pattern: yearPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text),
           let year = Int(text[range])
        {
            return year
        }
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

        // Collect "floating amounts" — standalone decimal numbers that PDFKit
        // extracts separately from the AMOUNT column (common in Chase PDFs).
        var floatingAmounts: [Double] = []

        // Phase 1: Collect floating amounts (lines that are just a number)
        let standaloneNumberPattern = #"^\s*(-?[\d,]+\.\d{2})\s*$"#
        let standaloneRegex = try? NSRegularExpression(pattern: standaloneNumberPattern)

        // Phase 2: Parse transaction lines
        // Pattern A: "MM/DD DESC AMOUNT BALANCE" (2 numbers at end)
        let twoNumPattern = #"^(\d{1,2}/\d{1,2})\s+(.+?)\s+(-?[\d,]+\.\d{2})\s+(-?[\d,]+\.\d{2})\s*$"#
        // Pattern B: "MM/DD MM/DD DESC AMOUNT BALANCE" (dual date, 2 numbers)
        let dualDateTwoNumPattern = #"^(\d{1,2}/\d{1,2})\s+\d{1,2}/\d{1,2}\s+(.+?)\s+(-?[\d,]+\.\d{2})\s+(-?[\d,]+\.\d{2})\s*$"#
        // Pattern C: "MM/DD DESC BALANCE" (1 number — amount was extracted separately)
        let oneNumPattern = #"^(\d{1,2}/\d{1,2})\s+(.+?)\s+(-?[\d,]+\.\d{2})\s*$"#
        // Pattern D: "MM/DD/YYYY DESC AMOUNT" (generic with full date)
        let fullDatePattern = #"^(\d{1,2}/\d{1,2}/\d{2,4})\s+(.+?)\s+(-?\$?[\d,]+\.\d{2})\s*$"#

        let twoNumRegex = try? NSRegularExpression(pattern: twoNumPattern)
        let dualDateRegex = try? NSRegularExpression(pattern: dualDateTwoNumPattern)
        let oneNumRegex = try? NSRegularExpression(pattern: oneNumPattern)
        let fullDateRegex = try? NSRegularExpression(pattern: fullDatePattern)

        // First pass: find floating amounts (before transaction section)
        var inTransactionSection = false
        var floatingAmountsDone = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let upper = trimmed.uppercased()
            if upper.contains("TRANSACTION DETAIL") {
                inTransactionSection = true
                floatingAmountsDone = true
                continue
            }

            // Collect standalone numbers before and within transaction section
            if !floatingAmountsDone {
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if let regex = standaloneRegex,
                   regex.firstMatch(in: trimmed, range: range) != nil,
                   let amount = ColumnMapper.parseAmount(trimmed)
                {
                    floatingAmounts.append(amount)
                }
            }
        }

        // Second pass: extract transactions
        var floatingIndex = 0
        inTransactionSection = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let upper = trimmed.uppercased()
            if upper.contains("TRANSACTION DETAIL") {
                inTransactionSection = true
                continue
            }
            if upper.contains("IN CASE OF ERRORS") ||
               upper.contains("THIS PAGE INTENTIONALLY") {
                inTransactionSection = false
                continue
            }

            // Skip headers and summaries
            if shouldSkipLine(upper) { continue }

            let range = NSRange(trimmed.startIndex..., in: trimmed)

            // Try dual-date with 2 numbers first
            if let regex = dualDateRegex,
               let match = regex.firstMatch(in: trimmed, range: range),
               let row = extractRow(from: trimmed, match: match, dateGroup: 1, descGroup: 2, amountGroup: 3, year: year)
            {
                rows.append(row)
                continue
            }

            // Try 2-number pattern (DATE DESC AMOUNT BALANCE)
            if let regex = twoNumRegex,
               let match = regex.firstMatch(in: trimmed, range: range),
               let row = extractRow(from: trimmed, match: match, dateGroup: 1, descGroup: 2, amountGroup: 3, year: year)
            {
                rows.append(row)
                continue
            }

            // Try full-date pattern (MM/DD/YYYY DESC AMOUNT)
            if let regex = fullDateRegex,
               let match = regex.firstMatch(in: trimmed, range: range),
               let row = extractRow(from: trimmed, match: match, dateGroup: 1, descGroup: 2, amountGroup: 3, year: 0)
            {
                rows.append(row)
                continue
            }

            // Try 1-number pattern (DATE DESC BALANCE) — use floating amount if available
            if let regex = oneNumRegex,
               let match = regex.firstMatch(in: trimmed, range: range)
            {
                guard let dateRange = Range(match.range(at: 1), in: trimmed),
                      let descRange = Range(match.range(at: 2), in: trimmed)
                else { continue }

                let dateStr = String(trimmed[dateRange])
                let desc = String(trimmed[descRange]).trimmingCharacters(in: .whitespaces)

                if shouldSkipDescription(desc) { continue }

                var date: Date?
                if dateStr.count <= 5 && year > 0 {
                    let fullDate = "\(dateStr)/\(year)"
                    date = DateHelpers.parseDate(fullDate, format: "MM/dd/yyyy")
                        ?? DateHelpers.parseDate(fullDate, format: "M/d/yyyy")
                }

                // Use the next floating amount for this transaction
                var amount: Double?
                if floatingIndex < floatingAmounts.count {
                    amount = floatingAmounts[floatingIndex]
                    floatingIndex += 1
                }

                rows.append(ParsedRow(
                    date: date,
                    description: desc.isEmpty ? nil : desc,
                    amount: amount,
                    rawColumns: ["Date": dateStr, "Description": desc, "Amount": amount.map { String($0) } ?? ""]
                ))
                continue
            }
        }

        return rows
    }

    private func shouldSkipLine(_ upper: String) -> Bool {
        upper.contains("BEGINNING BALANCE") ||
        upper.contains("ENDING BALANCE") ||
        upper.contains("TOTAL CHECKS") ||
        upper.contains("CHECK NUMBER") ||
        upper.contains("CHECKING SUMMARY") ||
        upper.contains("CHECKS PAID") ||
        upper.contains("DEPOSITS AND ADDITIONS") ||
        upper.contains("ATM & DEBIT") ||
        upper.contains("ELECTRONIC WITHDRAWALS") ||
        upper.contains("MONTHLY SERVICE FEE") ||
        upper.contains("HAVE ELECTRONIC DEPOSITS") ||
        upper.contains("KEEP A BALANCE") ||
        upper.contains("KEEP AN AVERAGE") ||
        upper.contains("YOUR TOTAL ELECTRONIC") ||
        (upper.hasPrefix("DATE") && upper.contains("DESCRIPTION") && upper.contains("AMOUNT")) ||
        (upper.hasPrefix("PAGE") && upper.contains("OF"))
    }

    private func shouldSkipDescription(_ desc: String) -> Bool {
        let upper = desc.uppercased()
        return upper.hasPrefix("TOTAL") ||
               upper.hasPrefix("BEGINNING") ||
               upper.hasPrefix("ENDING") ||
               upper.hasPrefix("CHECK NUMBER")
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

        if shouldSkipDescription(desc) { return nil }

        var date: Date?
        if dateStr.count <= 5 && year > 0 {
            let fullDate = "\(dateStr)/\(year)"
            date = DateHelpers.parseDate(fullDate, format: "MM/dd/yyyy")
                ?? DateHelpers.parseDate(fullDate, format: "M/d/yyyy")
        }
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
