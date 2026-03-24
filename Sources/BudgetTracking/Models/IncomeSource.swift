import Foundation

struct IncomeSource: Identifiable, Codable {
    var id = UUID()
    var name: String
    var keywords: [String]
    var isDefault: Bool

    static let defaults: [IncomeSource] = [
        IncomeSource(name: "Arthrex", keywords: ["ARTHREX"], isDefault: true),
        IncomeSource(name: "RCI", keywords: ["RCI"], isDefault: true),
        IncomeSource(name: "EBay", keywords: ["EBAY"], isDefault: true),
        IncomeSource(name: "Zelle", keywords: ["ZELLE"], isDefault: true),
    ]

    private static let storageKey = "incomeSources"
    private static let mappingsKey = "incomeSourceMappings"

    static func loadSaved() -> [IncomeSource] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([IncomeSource].self, from: data)
        else {
            return defaults
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
