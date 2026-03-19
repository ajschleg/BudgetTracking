import Foundation

enum RuleLearner {
    /// Learn from a manual override: create/update a rule AND bulk-update
    /// all similar transactions in the same month.
    /// Returns the number of additional transactions updated.
    @discardableResult
    static func learnFromOverride(
        transaction: Transaction,
        newCategoryId: UUID
    ) -> Int {
        // Prefer the clean merchant name if available, otherwise extract from description
        let merchant = transaction.merchant
            ?? extractMerchantName(from: transaction.description)
        guard !merchant.isEmpty else { return 0 }

        do {
            let existingRules = try DatabaseManager.shared.fetchRules()

            // Create or update rule
            if let existing = existingRules.first(where: {
                $0.keyword.uppercased() == merchant.uppercased()
            }) {
                var updated = existing
                updated.categoryId = newCategoryId
                updated.matchCount += 1
                try DatabaseManager.shared.saveRule(updated)
            } else {
                let maxPriority = existingRules.map(\.priority).max() ?? 0
                let rule = CategorizationRule(
                    keyword: merchant,
                    categoryId: newCategoryId,
                    priority: maxPriority + 1,
                    isUserDefined: false,
                    matchCount: 1
                )
                try DatabaseManager.shared.saveRule(rule)
            }

            // Bulk-update all similar transactions in the same month
            let updated = try DatabaseManager.shared.bulkUpdateCategory(
                matching: merchant,
                inMonth: transaction.month,
                toCategoryId: newCategoryId,
                excludingTransactionId: transaction.id
            )
            return updated

        } catch {
            print("RuleLearner error: \(error)")
            return 0
        }
    }

    /// Extract the merchant/store name from a transaction description,
    /// stripping the address portion.
    ///
    /// Apple Card format: "TRADER JOE S #670 2902 W 86TH ST INDIANAPOLIS 46268 IN USA"
    /// → "TRADER JOE S"
    ///
    /// Strategy: find where the street address starts (a number followed by
    /// address-like words) and take everything before it as the merchant name.
    static func extractMerchantName(from description: String) -> String {
        let text = description
            .trimmingCharacters(in: .whitespaces)

        // Remove trailing "(RETURN)" or "(CREDIT)" etc.
        let withoutSuffix = text.replacingOccurrences(
            of: #"\s*\((?:RETURN|CREDIT|REFUND)\)\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Try to find where the address starts:
        // Look for a pattern like "1234 STREET" or "1234 N/S/E/W"
        // Common: a number with 3+ digits followed by a word (street address)
        let addressPattern = #"\s+\d{3,}\s+(?:[NSEW]\s+|[A-Z])"#
        if let regex = try? NSRegularExpression(pattern: addressPattern, options: .caseInsensitive),
           let match = regex.firstMatch(
               in: withoutSuffix,
               range: NSRange(withoutSuffix.startIndex..., in: withoutSuffix)
           ),
           let range = Range(match.range, in: withoutSuffix)
        {
            let merchant = String(withoutSuffix[..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if !merchant.isEmpty {
                return cleanMerchantName(merchant)
            }
        }

        // Fallback: try splitting at a 5-digit zip code
        let zipPattern = #"\s+\d{5}(?:\s|-)"#
        if let regex = try? NSRegularExpression(pattern: zipPattern),
           let match = regex.firstMatch(
               in: withoutSuffix,
               range: NSRange(withoutSuffix.startIndex..., in: withoutSuffix)
           ),
           let range = Range(match.range, in: withoutSuffix)
        {
            // Walk backwards from the zip to find the address start
            let beforeZip = String(withoutSuffix[..<range.lowerBound])
            // Look for address start in this substring
            let addrStart = #"\s+\d{1,}\s+[A-Z]"#
            if let addrRegex = try? NSRegularExpression(pattern: addrStart, options: .caseInsensitive),
               let addrMatch = addrRegex.firstMatch(
                   in: beforeZip,
                   range: NSRange(beforeZip.startIndex..., in: beforeZip)
               ),
               let addrRange = Range(addrMatch.range, in: beforeZip)
            {
                let merchant = String(beforeZip[..<addrRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                if !merchant.isEmpty {
                    return cleanMerchantName(merchant)
                }
            }
        }

        // Last fallback: take first 3 words (skip store numbers and short tokens)
        return cleanMerchantName(withoutSuffix)
    }

    private static func cleanMerchantName(_ raw: String) -> String {
        raw
            // Remove store/location numbers like #670, #980
            .replacingOccurrences(of: #"\s*#\d+\s*"#, with: "", options: .regularExpression)
            // Remove long digit sequences (phone numbers, reference numbers)
            .replacingOccurrences(of: #"\s*\d{7,}\s*"#, with: "", options: .regularExpression)
            // Collapse whitespace
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
