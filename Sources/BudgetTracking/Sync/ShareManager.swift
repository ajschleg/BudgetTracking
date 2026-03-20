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
    private(set) var participantNames: [String] = []

    private let container: CKContainer
    private let logger = Logger(subsystem: "BudgetTracking", category: "Share")

    init() {
        container = CKContainer(identifier: SyncConstants.containerIdentifier)
        Task { await checkExistingShare() }
    }

    // MARK: - Check Existing Share

    func checkExistingShare() async {
        do {
            let zones = try await container.privateCloudDatabase.allRecordZones()
            guard zones.contains(where: { $0.zoneID == SyncConstants.zoneID }) else {
                await MainActor.run { shareStatus = .notShared }
                return
            }

            let fetchedShare = try await fetchShare()
            if let fetchedShare {
                await MainActor.run {
                    share = fetchedShare
                    let participants = fetchedShare.participants
                    participantNames = participants.compactMap {
                        if $0.role == .owner { return nil }
                        return $0.userIdentity.nameComponents.flatMap {
                            PersonNameComponentsFormatter().string(from: $0)
                        } ?? $0.userIdentity.lookupInfo?.emailAddress ?? "Unknown"
                    }
                    shareStatus = participants.count > 1
                        ? .shared(participantCount: participants.count)
                        : .notShared
                }
            }
        } catch {
            logger.error("Failed to check existing share: \(error)")
        }
    }

    private func fetchShare() async throws -> CKShare? {
        let zone = CKRecordZone(zoneID: SyncConstants.zoneID)
        let results = try await container.privateCloudDatabase.recordZones(
            for: [zone.zoneID]
        )
        guard let zoneResult = results[zone.zoneID] else { return nil }
        let fetchedZone = try zoneResult.get()

        guard let shareRef = fetchedZone.share else { return nil }
        let shareRecord = try await container.privateCloudDatabase.record(
            for: shareRef.recordID
        )
        return shareRecord as? CKShare
    }

    // MARK: - Create Share and Invite by Email

    /// Creates a zone-wide share and invites a participant by email address.
    func shareWithEmail(_ email: String) async throws {
        await MainActor.run { shareStatus = .sharing }

        do {
            // Get or create the share
            var ckShare: CKShare
            if let existingShare = try await fetchShare() {
                ckShare = existingShare
            } else {
                ckShare = CKShare(recordZoneID: SyncConstants.zoneID)
                ckShare[CKShare.SystemFieldKey.title] = "Budget Tracking"
                ckShare.publicPermission = .none
            }

            // Look up the participant by email
            let participant = try await container.shareParticipant(
                forEmailAddress: email
            )
            participant.permission = .readWrite

            ckShare.addParticipant(participant)

            // Save the share
            let operation = CKModifyRecordsOperation(
                recordsToSave: [ckShare],
                recordIDsToDelete: nil
            )

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                self.container.privateCloudDatabase.add(operation)
            }

            await MainActor.run {
                share = ckShare
                shareStatus = .shared(participantCount: ckShare.participants.count)
            }
            await checkExistingShare()

            logger.info("Successfully shared with \(email)")
        } catch {
            logger.error("Failed to share with \(email): \(error)")
            await MainActor.run {
                shareStatus = .error(error.localizedDescription)
            }
            throw error
        }
    }

    // MARK: - Reset Status

    func resetStatus() {
        shareStatus = .notShared
    }

    // MARK: - Accept Share

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
                        self.participantNames = []
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
