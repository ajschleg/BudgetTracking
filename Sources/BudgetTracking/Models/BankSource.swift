import Foundation

struct BankSource: Identifiable, Codable {
    var id = UUID()
    let name: String
    let url: String
    let isDefault: Bool

    static let defaults: [BankSource] = [
        BankSource(name: "Chase", url: "https://www.chase.com/personal/checking/online-banking", isDefault: true),
        BankSource(name: "Bank of America", url: "https://www.bankofamerica.com/online-banking/", isDefault: true),
        BankSource(name: "Wells Fargo", url: "https://www.wellsfargo.com/online-banking/", isDefault: true),
        BankSource(name: "Citi", url: "https://online.citi.com/", isDefault: true),
        BankSource(name: "Capital One", url: "https://www.capitalone.com/sign-in/", isDefault: true),
        BankSource(name: "American Express", url: "https://www.americanexpress.com/en-us/account/login", isDefault: true),
        BankSource(name: "Discover", url: "https://www.discover.com/credit-cards/member/", isDefault: true),
        BankSource(name: "US Bank", url: "https://www.usbank.com/online-mobile-banking/", isDefault: true),
        BankSource(name: "PNC", url: "https://www.pnc.com/en/personal-banking/banking/online-banking.html", isDefault: true),
        BankSource(name: "TD Bank", url: "https://onlinebanking.tdbank.com/", isDefault: true),
    ]

    private static let storageKey = "bankSources"

    static func loadSaved() -> [BankSource] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([BankSource].self, from: data)
        else {
            return defaults
        }
        return saved
    }

    static func save(_ sources: [BankSource]) {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
