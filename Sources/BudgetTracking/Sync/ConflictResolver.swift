import CloudKit
import Foundation

/// Resolves conflicts between local and server records.
enum ConflictResolver {

    /// Resolve a conflict between the local record and the server record.
    /// Returns the winning CKRecord to save, or nil to accept the server version.
    static func resolve(
        clientRecord: CKRecord,
        serverRecord: CKRecord
    ) -> CKRecord? {
        let clientModified = clientRecord["lastModifiedAt"] as? Date ?? .distantPast
        let serverModified = serverRecord["lastModifiedAt"] as? Date ?? .distantPast

        // For transactions with manual categorization, prefer the manually categorized version
        if clientRecord.recordType == SyncConstants.RecordType.transaction {
            let clientManual = clientRecord["isManuallyCategorized"] as? Bool ?? false
            let serverManual = serverRecord["isManuallyCategorized"] as? Bool ?? false

            if clientManual && !serverManual {
                // Client has manual categorization — keep client version
                applyClientFields(from: clientRecord, to: serverRecord)
                return serverRecord
            } else if serverManual && !clientManual {
                // Server has manual categorization — accept server version
                return nil
            }
        }

        // Default: last-writer-wins
        if clientModified > serverModified {
            applyClientFields(from: clientRecord, to: serverRecord)
            return serverRecord
        }

        // Server wins — accept server version
        return nil
    }

    /// Copy all non-system fields from the client record onto the server record
    /// (which has the correct system fields / change tag).
    private static func applyClientFields(from client: CKRecord, to server: CKRecord) {
        for key in client.allKeys() {
            server[key] = client[key]
        }
    }
}
