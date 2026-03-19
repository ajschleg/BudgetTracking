import Foundation

struct CategorizationEngine {
    let rules: [CategorizationRule]
    let categories: [BudgetCategory]

    /// Match against description and optionally a clean merchant name.
    /// Tries merchant first (more precise), then falls back to description.
    func categorize(description: String, merchant: String? = nil) -> CategorizationRule? {
        // Try matching against merchant name first (if available)
        if let merchant, !merchant.isEmpty {
            let upperMerchant = merchant.uppercased()
            if let match = rules.first(where: { upperMerchant.contains($0.keyword.uppercased()) }) {
                return match
            }
        }

        // Fall back to description matching
        let upperDesc = description.uppercased()
        return rules.first { rule in
            upperDesc.contains(rule.keyword.uppercased())
        }
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
