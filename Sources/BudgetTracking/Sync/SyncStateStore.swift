import CloudKit
import Foundation

/// Persists CKSyncEngine state serialization across app launches.
final class SyncStateStore {
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("BudgetTracking", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true
        )

        fileURL = appSupport.appendingPathComponent("sync-engine-state.json")
    }

    func load() -> CKSyncEngine.State.Serialization? {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL)
        else { return nil }
        return try? JSONDecoder().decode(
            CKSyncEngine.State.Serialization.self, from: data
        )
    }

    func save(_ state: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
