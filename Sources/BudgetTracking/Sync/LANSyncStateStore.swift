import Foundation

/// Persists per-peer sync timestamps so we only exchange records modified since the last sync.
final class LANSyncStateStore {

    private let fileURL: URL
    private var peerTimestamps: [String: Date] = [:]

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("BudgetTracking", isDirectory: true)

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        fileURL = appSupport.appendingPathComponent("lan_sync_state.json")
        load()
    }

    /// Get the last sync timestamp for a given peer.
    func lastSyncDate(forPeer peerId: String) -> Date? {
        peerTimestamps[peerId]
    }

    /// Update the last sync timestamp for a given peer.
    func setLastSyncDate(_ date: Date, forPeer peerId: String) {
        peerTimestamps[peerId] = date
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return
        }
        peerTimestamps = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(peerTimestamps) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
