import CloudKit
import Foundation

/// Persists CKSyncEngine state serialization across app launches.
final class SyncStateStore {
    private let directory: URL

    init() {
        directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("BudgetTracking", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent("sync-engine-state-\(key).json")
    }

    func load(key: String = "private") -> CKSyncEngine.State.Serialization? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(
            CKSyncEngine.State.Serialization.self, from: data
        )
    }

    func save(_ state: CKSyncEngine.State.Serialization, key: String = "private") {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL(for: key), options: .atomic)
    }
}
