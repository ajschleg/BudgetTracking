import Foundation

struct CategorizationEngine {
    let rules: [CategorizationRule]
    let categories: [BudgetCategory]

    /// Match against description and optionally a clean merchant name.
    /// Tries merchant first (more precise), then falls back to description.
    /// When multiple rules match, the longest keyword wins (most specific).
    func categorize(description: String, merchant: String? = nil) -> CategorizationRule? {
        // Try matching against merchant name first (if available)
        if let merchant, !merchant.isEmpty {
            let upperMerchant = merchant.uppercased()
            let merchantMatch = rules
                .filter { upperMerchant.contains($0.keyword.uppercased()) }
                .max(by: { $0.keyword.count < $1.keyword.count })
            if let match = merchantMatch {
                return match
            }
        }

        // Fall back to description matching — longest keyword wins
        let upperDesc = description.uppercased()
        return rules
            .filter { upperDesc.contains($0.keyword.uppercased()) }
            .max(by: { $0.keyword.count < $1.keyword.count })
    }

    func categorizeAll(transactions: inout [Transaction]) {
        for i in 0..<transactions.count {
            guard !transactions[i].isManuallyCategorized else { continue }
            if let rule = categorize(description: transactions[i].description) {
                transactions[i].categoryId = rule.categoryId
            }
        }
    }
}
