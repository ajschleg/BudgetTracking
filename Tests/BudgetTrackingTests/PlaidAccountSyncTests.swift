import XCTest
@testable import BudgetTracking

/// Verifies the plumbing that lets a peer Mac see Plaid-linked accounts
/// over LAN sync without ever receiving Plaid Identity PII. The host
/// keeps owner name / email / phone in its local DB; the wire format
/// strips them before the bytes leave the device.
final class PlaidAccountSyncTests: XCTestCase {

    private func sampleAccountWithPII() -> PlaidAccount {
        PlaidAccount(
            id: UUID(),
            plaidAccountId: "plaid-acct-123",
            plaidItemId: "plaid-item-abc",
            institutionName: "Chase",
            name: "Checking",
            officialName: "Chase Total Checking",
            type: "depository",
            subtype: "checking",
            mask: "1234",
            balanceCurrent: 2_500.42,
            balanceAvailable: 2_500.42,
            balanceLimit: nil,
            balanceCurrencyCode: "USD",
            balanceFetchedAt: Date(timeIntervalSince1970: 1_770_000_000),
            ownerName: "Austin Schlegel",
            ownerEmail: "austin@example.com",
            ownerPhone: "+1-555-0100",
            identityFetchedAt: Date(timeIntervalSince1970: 1_770_000_001)
        )
    }

    // MARK: - sanitizedForSync()

    func testSanitizedForSyncStripsOwnerIdentityFields() {
        let original = sampleAccountWithPII()
        let sanitized = original.sanitizedForSync()

        XCTAssertNil(sanitized.ownerName)
        XCTAssertNil(sanitized.ownerEmail)
        XCTAssertNil(sanitized.ownerPhone)
        XCTAssertNil(sanitized.identityFetchedAt)
    }

    func testSanitizedForSyncPreservesNonPIIFields() {
        let original = sampleAccountWithPII()
        let sanitized = original.sanitizedForSync()

        XCTAssertEqual(sanitized.id, original.id)
        XCTAssertEqual(sanitized.plaidAccountId, original.plaidAccountId)
        XCTAssertEqual(sanitized.plaidItemId, original.plaidItemId)
        XCTAssertEqual(sanitized.institutionName, original.institutionName)
        XCTAssertEqual(sanitized.name, original.name)
        XCTAssertEqual(sanitized.officialName, original.officialName)
        XCTAssertEqual(sanitized.type, original.type)
        XCTAssertEqual(sanitized.subtype, original.subtype)
        XCTAssertEqual(sanitized.mask, original.mask)
        XCTAssertEqual(sanitized.balanceCurrent, original.balanceCurrent)
        XCTAssertEqual(sanitized.balanceAvailable, original.balanceAvailable)
        XCTAssertEqual(sanitized.balanceLimit, original.balanceLimit)
        XCTAssertEqual(sanitized.balanceCurrencyCode, original.balanceCurrencyCode)
        XCTAssertEqual(sanitized.balanceFetchedAt, original.balanceFetchedAt)
        XCTAssertEqual(sanitized.lastModifiedAt, original.lastModifiedAt)
        XCTAssertEqual(sanitized.isDeleted, original.isDeleted)
    }

    func testSanitizedForSyncDoesNotMutateOriginal() {
        let original = sampleAccountWithPII()
        _ = original.sanitizedForSync()
        XCTAssertEqual(original.ownerName, "Austin Schlegel")
        XCTAssertEqual(original.ownerEmail, "austin@example.com")
        XCTAssertEqual(original.ownerPhone, "+1-555-0100")
    }

    // MARK: - JSON wire format (LAN sync uses JSONEncoder/Decoder)

    func testJSONEncodedSanitizedAccountContainsNoPII() throws {
        let sanitized = sampleAccountWithPII().sanitizedForSync()
        let data = try JSONEncoder().encode(sanitized)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8)?.lowercased())

        XCTAssertFalse(json.contains("austin schlegel"), "owner name leaked into LAN-sync JSON")
        XCTAssertFalse(json.contains("austin@example.com"), "owner email leaked into LAN-sync JSON")
        XCTAssertFalse(json.contains("+1-555-0100"), "owner phone leaked into LAN-sync JSON")
        XCTAssertFalse(json.contains("555-0100"), "partial owner phone leaked into LAN-sync JSON")

        // Sanity check: the metadata we DO want to flow is present.
        XCTAssertTrue(json.contains("chase"), "institution name should still flow")
        XCTAssertTrue(json.contains("plaid-acct-123"), "plaidAccountId should still flow")
    }

    // MARK: - DB round-trip via upsertFromPeer

    func testUpsertFromPeerStripsIncomingPII() throws {
        let db = try DatabaseManager.makeInMemoryForTesting()

        // A misbehaving peer pushes a record that still has owner fields
        // populated. The receiver must drop them at the boundary.
        let dirty = sampleAccountWithPII()
        let applied = try db.upsertFromPeer(dirty)
        XCTAssertTrue(applied)

        let stored = try XCTUnwrap(db.fetchPlaidAccounts().first)
        XCTAssertNil(stored.ownerName)
        XCTAssertNil(stored.ownerEmail)
        XCTAssertNil(stored.ownerPhone)
        XCTAssertNil(stored.identityFetchedAt)

        // Non-PII fields land normally.
        XCTAssertEqual(stored.institutionName, "Chase")
        XCTAssertEqual(stored.balanceCurrent, 2_500.42)
        XCTAssertEqual(stored.mask, "1234")
    }

    func testUpsertFromPeerDedupsByPlaidAccountId() throws {
        let db = try DatabaseManager.makeInMemoryForTesting()
        // Future-dated to dodge the last-writer-wins comparison: the
        // production savePlaidAccount stamps lastModifiedAt = Date(),
        // so to exercise the dedup path we seed via upsertFromPeer
        // (which preserves the timestamp).
        let baseTime = Date(timeIntervalSinceNow: 86_400)

        let original = PlaidAccount(
            id: UUID(),
            plaidAccountId: "plaid-acct-123",
            plaidItemId: "plaid-item-abc",
            institutionName: "Chase",
            balanceCurrent: 100.00,
            lastModifiedAt: baseTime
        )
        XCTAssertTrue(try db.upsertFromPeer(original))
        XCTAssertEqual(try db.fetchPlaidAccounts().count, 1)

        // Peer (with a different local UUID) reports the same Plaid
        // account at a later lastModifiedAt — should merge, not duplicate.
        let peerCopy = PlaidAccount(
            id: UUID(),                                      // different id!
            plaidAccountId: "plaid-acct-123",                // same Plaid id
            plaidItemId: "plaid-item-abc",
            institutionName: "Chase",
            balanceCurrent: 250.00,                          // newer balance
            lastModifiedAt: baseTime.addingTimeInterval(60)
        )

        let applied = try db.upsertFromPeer(peerCopy)
        XCTAssertTrue(applied)
        let accounts = try db.fetchPlaidAccounts()
        XCTAssertEqual(accounts.count, 1, "must dedupe on plaidAccountId, not local UUID")
        XCTAssertEqual(accounts[0].balanceCurrent, 250.00)
    }

    // MARK: - SyncConstants registration

    func testPlaidAccountIsRegisteredAsSyncRecordType() {
        XCTAssertEqual(SyncConstants.RecordType.plaidAccount, "PlaidAccount")
    }
}
