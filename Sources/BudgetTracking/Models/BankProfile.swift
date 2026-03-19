import Foundation
import GRDB

struct BankProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var fileType: String // "csv", "tsv", "ofx", etc.
    var dateColumn: String?
    var descriptionColumn: String?
    var amountColumn: String?
    var debitColumn: String?
    var creditColumn: String?
    var dateFormat: String
    var headerRowIndex: Int
    var amountSignConvention: AmountSignConvention

    enum AmountSignConvention: String, Codable {
        case negativeIsDebit // Most common: negative = money out
        case positiveIsDebit // Some banks flip the sign
    }

    init(
        id: UUID = UUID(),
        name: String,
        fileType: String = "csv",
        dateColumn: String? = nil,
        descriptionColumn: String? = nil,
        amountColumn: String? = nil,
        debitColumn: String? = nil,
        creditColumn: String? = nil,
        dateFormat: String = "MM/dd/yyyy",
        headerRowIndex: Int = 0,
        amountSignConvention: AmountSignConvention = .negativeIsDebit
    ) {
        self.id = id
        self.name = name
        self.fileType = fileType
        self.dateColumn = dateColumn
        self.descriptionColumn = descriptionColumn
        self.amountColumn = amountColumn
        self.debitColumn = debitColumn
        self.creditColumn = creditColumn
        self.dateFormat = dateFormat
        self.headerRowIndex = headerRowIndex
        self.amountSignConvention = amountSignConvention
    }
}

extension BankProfile: FetchableRecord, PersistableRecord {
    static let databaseTableName = "bankProfile"

    enum Columns: String, ColumnExpression {
        case id, name, fileType, dateColumn, descriptionColumn
        case amountColumn, debitColumn, creditColumn
        case dateFormat, headerRowIndex, amountSignConvention
    }
}
