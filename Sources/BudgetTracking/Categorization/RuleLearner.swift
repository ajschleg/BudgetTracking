import Foundation

enum RuleLearner {
    static func learnFromOverride(
        transaction: Transaction,
        newCategoryId: UUID
    ) {
        let description = transaction.description
        let keywords = extractKeywords(from: description)

        guard let bestKeyword = keywords.first else { return }

        do {
            let existingRules = try DatabaseManager.shared.fetchRules()

            // Check if a rule already exists for this keyword
            if let existing = existingRules.first(where: {
                $0.keyword.uppercased() == bestKeyword.uppercased()
            }) {
                // Update existing rule to point to new category
                var updated = existing
                updated.categoryId = newCategoryId
                updated.matchCount += 1
                try DatabaseManager.shared.saveRule(updated)
            } else {
                // Create a new learned rule with high priority
                let maxPriority = existingRules.map(\.priority).max() ?? 0
                let rule = CategorizationRule(
                    keyword: bestKeyword,
                    categoryId: newCategoryId,
                    priority: maxPriority + 1,
                    isUserDefined: false,
                    matchCount: 1
                )
                try DatabaseManager.shared.saveRule(rule)
            }
        } catch {
            print("RuleLearner error: \(error)")
        }
    }

    static func extractKeywords(from description: String) -> [String] {
        let cleaned = description
            .replacingOccurrences(of: #"[#\d]{4,}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let words = cleaned.components(separatedBy: " ")
            .filter { $0.count > 2 }

        // Return progressively longer keyword candidates
        var candidates: [String] = []

        // Full cleaned description (most specific)
        if !cleaned.isEmpty {
            candidates.append(cleaned)
        }

        // First 3 words (usually merchant name)
        if words.count >= 3 {
            candidates.append(words.prefix(3).joined(separator: " "))
        }

        // First 2 words
        if words.count >= 2 {
            candidates.append(words.prefix(2).joined(separator: " "))
        }

        // First word
        if let first = words.first {
            candidates.append(first)
        }

        return candidates
    }
}
