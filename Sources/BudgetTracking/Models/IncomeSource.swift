import Foundation

enum IncomeSourceType: String, Codable {
    case employment
    case sideHustle
}

struct IncomeSource: Identifiable, Codable {
    var id = UUID()
    var name: String
    var keywords: [String]
    var isDefault: Bool
    var type: IncomeSourceType = .employment

    var isEbay: Bool {
        keywords.contains { $0.uppercased() == "EBAY" }
    }

    static let defaults: [IncomeSource] = [
        IncomeSource(name: "Arthrex", keywords: ["ARTHREX"], isDefault: true, type: .employment),
        IncomeSource(name: "RCI", keywords: ["RCI"], isDefault: true, type: .employment),
        IncomeSource(name: "EBay", keywords: ["EBAY"], isDefault: true, type: .sideHustle),
        IncomeSource(name: "Zelle", keywords: ["ZELLE"], isDefault: true, type: .employment),
    ]

    private static let storageKey = "incomeSources"
    private static let mappingsKey = "incomeSourceMappings"

    static func loadSaved() -> [IncomeSource] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var saved = try? JSONDecoder().decode([IncomeSource].self, from: data)
        else {
            return defaults
        }
        // Migrate: ensure eBay sources are marked as sideHustle
        var migrated = false
        for i in saved.indices {
            if saved[i].isEbay && saved[i].type == .employment {
                saved[i].type = .sideHustle
                migrated = true
            }
        }
        if migrated {
            save(saved)
        }
        return saved
    }

    static func save(_ sources: [IncomeSource]) {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: - Source-to-Transaction Mappings

    static func loadMappings() -> [UUID: UUID] {
        guard let data = UserDefaults.standard.data(forKey: mappingsKey),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        var result: [UUID: UUID] = [:]
        for (txnKey, sourceKey) in dict {
            if let txnId = UUID(uuidString: txnKey), let sourceId = UUID(uuidString: sourceKey) {
                result[txnId] = sourceId
            }
        }
        return result
    }

    static func saveMappings(_ mappings: [UUID: UUID]) {
        var dict: [String: String] = [:]
        for (txnId, sourceId) in mappings {
            dict[txnId.uuidString] = sourceId.uuidString
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: mappingsKey)
        }
    }

    static func sourceId(for transactionId: UUID) -> UUID? {
        loadMappings()[transactionId]
    }

    static func setSource(_ sourceId: UUID?, for transactionId: UUID) {
        var mappings = loadMappings()
        if let sourceId {
            mappings[transactionId] = sourceId
        } else {
            mappings.removeValue(forKey: transactionId)
        }
        saveMappings(mappings)
    }
}
