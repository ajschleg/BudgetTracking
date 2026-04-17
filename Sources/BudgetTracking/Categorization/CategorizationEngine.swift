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

    /// Categorize with Plaid category hints as the first pass, falling
    /// back to keyword rules when Plaid has nothing mappable.
    ///
    /// Plaid's `personal_finance_category` is ML-derived and trained on
    /// a huge corpus — it's usually a better signal than a one-word
    /// keyword match. We try the `detailed` code first (most specific,
    /// e.g. FOOD_AND_DRINK_GROCERIES → Groceries), then the `primary`
    /// bucket, then fall through to existing keyword/learned rules.
    ///
    /// `plaidPrimaryCategories` / `plaidDetailedCategories` are parallel
    /// to `transactions`; pass nil entries for non-Plaid rows. User
    /// manually-categorized transactions are skipped as usual.
    func categorizeAllWithPlaid(
        transactions: inout [Transaction],
        plaidPrimaryCategories: [String?],
        plaidDetailedCategories: [String?]
    ) {
        for i in 0..<transactions.count {
            guard !transactions[i].isManuallyCategorized else { continue }

            // 1. Plaid detailed code (most specific)
            if let detailed = plaidDetailedCategories[safe: i] ?? nil,
               let categoryId = SourceCategoryMapper.mapToCategory(
                sourceCategory: detailed,
                categories: categories
               ) {
                transactions[i].categoryId = categoryId
                continue
            }

            // 2. Plaid primary bucket
            if let primary = plaidPrimaryCategories[safe: i] ?? nil,
               let categoryId = SourceCategoryMapper.mapToCategory(
                sourceCategory: primary,
                categories: categories
               ) {
                transactions[i].categoryId = categoryId
                continue
            }

            // 3. Keyword rules (merchant first, then description)
            if let rule = categorize(
                description: transactions[i].description,
                merchant: transactions[i].merchant
            ) {
                transactions[i].categoryId = rule.categoryId
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
