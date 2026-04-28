import Foundation

/// Pure logic for finding likely duplicate transactions in an import set.
/// A "duplicate" is two or more rows with the same calendar day, the
/// same amount, and the same description after stripping common noise
/// suffixes (currently the Apple Card cash-back annotation).
///
/// Kept free of GRDB / SwiftUI so the detector can be unit-tested
/// against synthetic transactions without spinning up a database or
/// a view hierarchy.
enum DuplicateDetector {

    struct Group: Identifiable {
        let id: String                          // composite key, stable within a scan
        let date: Date                          // canonical day for display
        let amount: Double
        let normalizedDescription: String
        let transactions: [Transaction]
        var keeperId: UUID                      // mutable so a UI can override the heuristic

        var removableTransactions: [Transaction] {
            transactions.filter { $0.id != keeperId }
        }

        var dollarOvercount: Double {
            // |amount| × (count − 1). The duplicates are double-counted
            // exactly once per extra row.
            abs(amount) * Double(transactions.count - 1)
        }
    }

    /// Strip Apple Card cash-back tail like " 2% $3.78" from a description.
    /// Matches a literal " 2% $" followed by a decimal number at the END
    /// of the string. Leaves the rest of the description intact.
    static func normalize(_ description: String) -> String {
        let trimmed = description.trimmingCharacters(in: .whitespaces)
        // Conservative regex anchored to end-of-string. Decimal optional.
        if let range = trimmed.range(
            of: #" 2% \$\d+(\.\d+)?$"#,
            options: .regularExpression
        ) {
            return String(trimmed[..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    /// Find groups of duplicate transactions. Each group has 2+ rows
    /// with matching `(day, amount, normalize(description))`.
    static func findDuplicates(in transactions: [Transaction]) -> [Group] {
        let buckets = Dictionary(grouping: transactions) { txn in
            "\(dayKey(txn.date))|\(txn.amount)|\(normalize(txn.description))"
        }

        return buckets
            .compactMap { (key, txns) -> Group? in
                guard txns.count > 1 else { return nil }
                let keeper = pickKeeper(txns)
                let canonical = txns.first!
                return Group(
                    id: key,
                    date: canonical.date,
                    amount: canonical.amount,
                    normalizedDescription: normalize(canonical.description),
                    transactions: txns,
                    keeperId: keeper.id
                )
            }
            .sorted { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date > rhs.date }
                return lhs.normalizedDescription < rhs.normalizedDescription
            }
    }

    /// Pick which transaction to keep when duplicates are detected.
    /// Priority:
    ///   1. Has externalId (Plaid-synced — most reliable, stable id).
    ///   2. Earliest importedAt (original import wins over re-import).
    ///   3. Lexicographically earliest UUID (deterministic tiebreak).
    static func pickKeeper(_ transactions: [Transaction]) -> Transaction {
        if let withExternal = transactions.first(where: { $0.externalId != nil }) {
            return withExternal
        }
        return transactions.min { lhs, rhs in
            if lhs.importedAt != rhs.importedAt { return lhs.importedAt < rhs.importedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        } ?? transactions[0]
    }

    /// Aggregate stats for the scanner UI's header.
    struct Summary: Equatable {
        let groupCount: Int
        let duplicateRowCount: Int      // rows that would be removed if every group keeps one
        let dollarOvercount: Double     // signed sum of dup amounts; abs() at display time
    }

    static func summarize(_ groups: [Group]) -> Summary {
        let groupCount = groups.count
        let duplicateRowCount = groups.reduce(0) { $0 + ($1.transactions.count - 1) }
        let dollarOvercount = groups.reduce(0.0) { $0 + $1.dollarOvercount }
        return Summary(
            groupCount: groupCount,
            duplicateRowCount: duplicateRowCount,
            dollarOvercount: dollarOvercount
        )
    }

    // MARK: - Helpers

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC") ?? .current
        return f
    }()

    private static func dayKey(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }
}
