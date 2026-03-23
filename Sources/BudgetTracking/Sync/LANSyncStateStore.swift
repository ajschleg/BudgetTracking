import Foundation
import os.log

/// Persists per-peer sync timestamps so we only exchange records modified since the last sync.
final class LANSyncStateStore {

    private let fileURL: URL
    private var peerTimestamps: [String: Date] = [:]
    private let logger = Logger(subsystem: "BudgetTracking", category: "LANSync")

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
        guard let data = try? Data(contentsOf: fileURL) else {
            logger.debug("No existing state file at \(self.fileURL.path)")
            return
        }
        guard let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else {
            logger.error("Failed to decode state file at \(self.fileURL.path)")
            return
        }
        peerTimestamps = decoded
        logger.debug("Loaded sync state for \(decoded.count) peer(s) from \(self.fileURL.path)")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(peerTimestamps) else {
            logger.error("Failed to encode peer timestamps for save")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            logger.debug("Saved sync state for \(self.peerTimestamps.count) peer(s)")
        } catch {
            logger.error("Failed to write state file: \(error)")
        }
    }
}
