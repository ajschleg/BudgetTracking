import CloudKit
import Foundation
import os.log

/// Manages sharing the budget data zone with another iCloud user.
@Observable
final class ShareManager {

    enum ShareStatus: Equatable {
        case notShared
        case sharing
        case shared(participantCount: Int)
        case error(String)
    }

    private(set) var shareStatus: ShareStatus = .notShared
    private(set) var share: CKShare?

    private let container: CKContainer
    private let logger = Logger(subsystem: "BudgetTracking", category: "Share")

    init() {
        container = CKContainer(identifier: SyncConstants.containerIdentifier)
        Task { await checkExistingShare() }
    }

    // MARK: - Check Existing Share

    private func checkExistingShare() async {
        do {
            let zones = try await container.privateCloudDatabase.allRecordZones()
            guard zones.contains(where: { $0.zoneID == SyncConstants.zoneID }) else {
                await MainActor.run { shareStatus = .notShared }
                return
            }

            // Look for an existing share in our zone
            let fetchedShare = try await fetchShare()
            if let fetchedShare {
                await MainActor.run {
                    share = fetchedShare
                    let participantCount = fetchedShare.participants.count
                    shareStatus = participantCount > 1
                        ? .shared(participantCount: participantCount)
                        : .notShared
                }
            }
        } catch {
            logger.error("Failed to check existing share: \(error)")
        }
    }

    private func fetchShare() async throws -> CKShare? {
        // Fetch the zone's share
        let zone = CKRecordZone(zoneID: SyncConstants.zoneID)
        let results = try await container.privateCloudDatabase.recordZones(
            for: [zone.zoneID]
        )
        guard let zoneResult = results[zone.zoneID] else { return nil }
        let fetchedZone = try zoneResult.get()

        // Check if zone has a share
        guard let shareRef = fetchedZone.share else { return nil }
        let shareRecord = try await container.privateCloudDatabase.record(
            for: shareRef.recordID
        )
        return shareRecord as? CKShare
    }

    // MARK: - Create Share

    /// Creates a zone-wide share for the budget data.
    /// Returns the CKShare for presenting to the user via sharing UI.
    func createShare() async throws -> CKShare {
        await MainActor.run { shareStatus = .sharing }

        // Create a zone-wide share
        let zone = CKRecordZone(zoneID: SyncConstants.zoneID)
        let newShare = CKShare(recordZoneID: zone.zoneID)
        newShare[CKShare.SystemFieldKey.title] = "Budget Tracking"
        newShare.publicPermission = .none // Only invited participants

        let operation = CKModifyRecordsOperation(
            recordsToSave: [newShare],
            recordIDsToDelete: nil
        )

        return try await withCheckedThrowingContinuation { continuation in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    Task { @MainActor in
                        self.share = newShare
                        self.shareStatus = .shared(participantCount: newShare.participants.count)
                    }
                    continuation.resume(returning: newShare)
                case .failure(let error):
                    Task { @MainActor in
                        self.shareStatus = .error(error.localizedDescription)
                    }
                    continuation.resume(throwing: error)
                }
            }
            container.privateCloudDatabase.add(operation)
        }
    }

    // MARK: - Accept Share

    /// Accept a share invitation metadata.
    func acceptShare(_ metadata: CKShare.Metadata) async throws {
        try await container.accept(metadata)
        await checkExistingShare()
    }

    // MARK: - Stop Sharing

    func stopSharing() async throws {
        guard let share else { return }

        let operation = CKModifyRecordsOperation(
            recordsToSave: nil,
            recordIDsToDelete: [share.recordID]
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    Task { @MainActor in
                        self.share = nil
                        self.shareStatus = .notShared
                    }
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            container.privateCloudDatabase.add(operation)
        }
    }
}
