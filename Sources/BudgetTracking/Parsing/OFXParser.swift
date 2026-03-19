import Foundation

struct OFXStatementParser: StatementParser {
    func parse(fileURL: URL, bankProfile: BankProfile?) throws -> [ParsedRow] {
        guard fileURL.startAccessingSecurityScopedResource() || true else {
            throw ParserError.parseFailure("Cannot access file")
        }
        defer { fileURL.stopAccessingSecurityScopedResource() }

        let content = try String(contentsOf: fileURL, encoding: .utf8)

        // OFX can be SGML (v1) or XML (v2)
        // Extract transaction blocks between <STMTTRN> and </STMTTRN>
        var rows: [ParsedRow] = []
        let pattern = "<STMTTRN>[\\s\\S]*?</STMTTRN>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            throw ParserError.parseFailure("Failed to create OFX regex")
        }

        let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))

        for match in matches {
            guard let range = Range(match.range, in: content) else { continue }
            let block = String(content[range])

            let date = extractOFXValue(block, tag: "DTPOSTED")
                .flatMap { parseOFXDate($0) }
            let amount = extractOFXValue(block, tag: "TRNAMT")
                .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            let name = extractOFXValue(block, tag: "NAME")
            let memo = extractOFXValue(block, tag: "MEMO")

            let description = [name, memo]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " - ")

            var rawCols: [String: String] = [:]
            if let d = extractOFXValue(block, tag: "DTPOSTED") { rawCols["DTPOSTED"] = d }
            if let a = extractOFXValue(block, tag: "TRNAMT") { rawCols["TRNAMT"] = a }
            if let n = name { rawCols["NAME"] = n }
            if let m = memo { rawCols["MEMO"] = m }

            rows.append(ParsedRow(
                date: date,
                description: description.isEmpty ? nil : description,
                amount: amount,
                rawColumns: rawCols
            ))
        }

        guard !rows.isEmpty else {
            throw ParserError.noData
        }

        return rows
    }

    private func extractOFXValue(_ block: String, tag: String) -> String? {
        // Handle both SGML style (<TAG>value) and XML style (<TAG>value</TAG>)
        let patterns = [
            "<\(tag)>([^<\\n]+)",
            "<\(tag)>\\s*([^<]+?)\\s*</\(tag)>"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
               let range = Range(match.range(at: 1), in: block)
            {
                return String(block[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func parseOFXDate(_ string: String) -> Date? {
        // OFX dates: YYYYMMDD or YYYYMMDDHHMMSS or YYYYMMDDHHMMSS.XXX[TZ]
        let cleaned = String(string.prefix(8))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: cleaned)
    }
}
