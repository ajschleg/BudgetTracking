import Foundation

/// Thin iOS-side wrapper around LANSyncEngine.sendPlaidRPC. Exposes
/// the same call surface PlaidService gives the macOS app, but with
/// every call going over the LAN sync channel instead of HTTP. The
/// iPhone therefore never needs the server URL or the X-App-Token in
/// its Keychain - the Mac is the only device that talks to /server/.
///
/// Lives in the shared sync module rather than under
/// Sources/BudgetTrackingIOS so it can be reused by tests and any
/// future "second Mac as backup peer" topology. The macOS app never
/// instantiates this in practice: its PlaidService talks to /server/
/// directly because the secrets and server URL are already there.
struct LANPlaidClient {
    let engine: LANSyncEngine

    /// Ask the Mac peer to call POST /api/link/create on our behalf
    /// and return the link_token. Throws LANPlaidRPCError on any
    /// non-success path (no peer, timeout, server error).
    func createLinkToken() async throws -> String {
        let result = try await engine.sendPlaidRPC(.createLinkToken)
        guard case .linkToken(let token) = result else {
            throw LANPlaidRPCError.mismatchedResult
        }
        return token
    }

    /// After LinkKit completes on the iPhone, hand the public_token +
    /// institution metadata to the Mac for the
    /// POST /api/link/exchange call. Returns the Mac's local item
    /// UUID and the count of accounts it persisted; the rows
    /// themselves arrive on the iPhone via the regular LAN
    /// record-sync push that fires after the Mac's upserts land.
    func exchangePublicToken(
        publicToken: String,
        institutionId: String,
        institutionName: String
    ) async throws -> (itemId: String, institution: String, accountCount: Int) {
        let params = PlaidExchangeParams(
            publicToken: publicToken,
            institutionId: institutionId,
            institutionName: institutionName
        )
        let result = try await engine.sendPlaidRPC(.exchangePublicToken(params))
        guard case .linkExchanged(let itemId, let institution, let count) = result else {
            throw LANPlaidRPCError.mismatchedResult
        }
        return (itemId: itemId, institution: institution, accountCount: count)
    }
}
