import Foundation

/// Persisted set of transaction IDs the user has dismissed as "not a
/// return" on the Insights page. A dismissed transaction no longer
/// offsets spending anywhere the return-netting query runs — the
/// dashboard bars, the Overall Budget headline, the History list, and
/// the Insights return detector all read from this one store so they
/// stay consistent with each other.
enum DismissedReturns {
    private static let key = "dismissedReturnIds"

    static func load() -> Set<UUID> {
        let data = UserDefaults.standard.data(forKey: key) ?? Data()
        return (try? JSONDecoder().decode(Set<UUID>.self, from: data)) ?? []
    }

    static func save(_ ids: Set<UUID>) {
        if let data = try? JSONEncoder().encode(ids) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
