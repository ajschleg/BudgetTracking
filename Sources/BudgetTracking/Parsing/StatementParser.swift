import Foundation

struct ParsedRow {
    var date: Date?
    var description: String?
    var amount: Double?
    var merchant: String?       // Clean merchant name (e.g., from Apple Card "Merchant" column)
    var sourceCategory: String? // Category from the bank (e.g., Apple Card "Category" column)
    var rawColumns: [String: String]

    init(
        date: Date? = nil,
        description: String? = nil,
        amount: Double? = nil,
        merchant: String? = nil,
        sourceCategory: String? = nil,
        rawColumns: [String: String] = [:]
    ) {
        self.date = date
        self.description = description
        self.amount = amount
        self.merchant = merchant
        self.sourceCategory = sourceCategory
        self.rawColumns = rawColumns
    }
}

protocol StatementParser {
    func parse(fileURL: URL, bankProfile: BankProfile?) throws -> [ParsedRow]
}

enum StatementParserFactory {
    static func parser(for url: URL) throws -> StatementParser {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "csv":
            return CSVStatementParser(delimiter: ",")
        case "tsv":
            return CSVStatementParser(delimiter: "\t")
        case "ofx", "qfx":
            return OFXStatementParser()
        case "qif":
            return QIFStatementParser()
        case "pdf":
            return PDFStatementParser()
        case "xlsx":
            return XLSXStatementParser()
        default:
            throw ParserError.unsupportedFormat(ext)
        }
    }

    static var supportedExtensions: [String] {
        ["csv", "tsv", "ofx", "qfx", "qif", "pdf", "xlsx"]
    }
}

enum ParserError: LocalizedError {
    case unsupportedFormat(String)
    case parseFailure(String)
    case noData

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported file format: .\(ext)"
        case .parseFailure(let detail):
            return "Parse error: \(detail)"
        case .noData:
            return "No transaction data found in file"
        }
    }
}
