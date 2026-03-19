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

        return parseTransactionsFromText(allText)
    }

    private func parseTransactionsFromText(_ text: String) -> [ParsedRow] {
        let lines = text.components(separatedBy: .newlines)
        var rows: [ParsedRow] = []

        // Common pattern: date at start, amount at end, description in middle
        // Try multiple date patterns
        let datePattern = #"(\d{1,2}/\d{1,2}/\d{2,4})"#
        let amountPattern = #"(-?\$?[\d,]+\.\d{2})"#
        let linePattern = #"^(\d{1,2}/\d{1,2}/\d{2,4})\s+(.+?)\s+(-?\$?[\d,]+\.\d{2})\s*$"#

        guard let lineRegex = try? NSRegularExpression(pattern: linePattern) else {
            return rows
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = lineRegex.firstMatch(in: trimmed, range: range) {
                guard let dateRange = Range(match.range(at: 1), in: trimmed),
                      let descRange = Range(match.range(at: 2), in: trimmed),
                      let amtRange = Range(match.range(at: 3), in: trimmed)
                else { continue }

                let dateStr = String(trimmed[dateRange])
                let desc = String(trimmed[descRange]).trimmingCharacters(in: .whitespaces)
                let amtStr = String(trimmed[amtRange])

                var date: Date?
                for format in DateHelpers.commonDateFormats {
                    if let d = DateHelpers.parseDate(dateStr, format: format) {
                        date = d
                        break
                    }
                }

                let amount = ColumnMapper.parseAmount(amtStr)

                rows.append(ParsedRow(
                    date: date,
                    description: desc.isEmpty ? nil : desc,
                    amount: amount,
                    rawColumns: ["Date": dateStr, "Description": desc, "Amount": amtStr]
                ))
            }
        }

        return rows
    }
}
