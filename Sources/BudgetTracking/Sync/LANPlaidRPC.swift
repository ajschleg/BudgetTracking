import Foundation

// MARK: - Plaid RPC wire types
//
// Small request/response shapes that ride on the existing LAN sync
// channel. The point of these is that iOS never needs the server URL
// or the X-App-Token to participate in the Plaid Link flow - the Mac
// is the only device that talks to /server/. iOS asks the Mac to
// create a link_token, opens LinkKit locally, then asks the Mac to
// exchange the resulting public_token. The new PlaidAccount rows and
// initial transactions land on iOS via the regular SyncRecord push.
//
// SECURITY_POLICY §10: nothing here ships Plaid PII (owner_name /
// _email / _phone) - the only response that returns Plaid metadata
// is `exchanged`, which carries only the institution name and the
// account display fields (name, mask, type) that already cross the
// LAN boundary via the sanitized PlaidAccount record sync.

/// Request body for SyncMessage.plaidRPCRequest. Correlated with the
/// matching response via the same requestId.
struct PlaidRPCRequest: Codable {
    let requestId: UUID
    let method: PlaidRPCMethod
}

/// Response body for SyncMessage.plaidRPCResponse. The Mac always
/// answers, even on error - silence after a request means the channel
/// is broken, not that the call is still in flight.
struct PlaidRPCResponse: Codable {
    let requestId: UUID
    let result: PlaidRPCResult
}

/// Methods iOS can invoke on the Mac peer. Adding a method requires
/// matching changes in PlaidRPCResult so the Mac handler can return
/// the right payload shape.
enum PlaidRPCMethod: Codable {
    /// Ask the Mac to call POST /api/link/create and return the
    /// link_token. The token is short-lived (Plaid expires it after
    /// ~4 hours) so iOS doesn't cache it.
    case createLinkToken

    /// After LinkKit succeeds on iOS, hand the public_token + the
    /// institution metadata to the Mac for the
    /// POST /api/link/exchange call. The Mac saves the access_token
    /// (encrypted, server-side) and runs the initial transactions
    /// pull; iOS picks up the new PlaidAccount + transaction rows via
    /// the regular LAN record-sync push that fires after the upserts.
    case exchangePublicToken(PlaidExchangeParams)

    /// Short identifier for logs; never includes the public_token.
    var methodName: String {
        switch self {
        case .createLinkToken: return "createLinkToken"
        case .exchangePublicToken: return "exchangePublicToken"
        }
    }
}

struct PlaidExchangeParams: Codable {
    /// One-time public_token from LinkKit. NEVER log this value - it
    /// is short-lived but still grants access to the user's bank
    /// session until exchanged.
    let publicToken: String
    let institutionId: String
    let institutionName: String
}

/// Result variant carried by every PlaidRPCResponse. The Mac always
/// returns a concrete case - even failure paths use `.failure` rather
/// than dropping the response, so iOS callers can resume their
/// continuation deterministically.
enum PlaidRPCResult: Codable {
    /// The peer is reporting a failure for this RPC. `message` is a
    /// user-displayable string sanitized by the Mac side (no raw
    /// Plaid error payloads per SECURITY_POLICY §4 / §8); `code` is
    /// an optional stable identifier for branches the UI cares about
    /// ("noHandler", "rpcTimeout", "linkExchangeFailed", etc.).
    case failure(message: String, code: String?)

    /// Successful PlaidRPCMethod.createLinkToken.
    case linkToken(String)

    /// Successful PlaidRPCMethod.exchangePublicToken. itemId is the
    /// Mac's local UUID for the new PlaidAccount item; institution is
    /// the display name. accountCount is purely informational (the
    /// real account rows arrive over the record-sync push).
    case linkExchanged(itemId: String, institution: String, accountCount: Int)

    /// Compact label for log lines.
    var shortDescription: String {
        switch self {
        case .failure(_, let code): return "failure(\(code ?? "unknown"))"
        case .linkToken: return "linkToken"
        case .linkExchanged(_, let institution, let n): return "linkExchanged(\(institution), \(n) accounts)"
        }
    }
}

// MARK: - Errors raised on the iOS caller side

enum LANPlaidRPCError: Error, LocalizedError {
    /// iOS tried to send an RPC but no Mac peer is connected over LAN.
    /// Surfaces in Settings as "Open BudgetTracking on your Mac and
    /// try again", same wording the Refresh button uses.
    case noPeerConnected
    /// The Mac never responded within the per-call timeout. Almost
    /// always means the Mac app was suspended or the network dropped
    /// mid-call; LinkKit on iOS can be retried safely.
    case timeout
    /// The Mac responded with a PlaidRPCResult.failure. Carries the
    /// peer's user-displayable message plus an optional stable code.
    case peerFailure(message: String, code: String?)
    /// The Mac responded with a result variant that doesn't match the
    /// method iOS invoked (e.g. createLinkToken request returned
    /// linkExchanged). Indicates a protocol mismatch; rebuild both
    /// sides and retry.
    case mismatchedResult

    var errorDescription: String? {
        switch self {
        case .noPeerConnected:
            return "Open BudgetTracking on your Mac and make sure it's on the same Wi-Fi, then try again."
        case .timeout:
            return "Your Mac didn't respond. Make sure it's open and try again."
        case .peerFailure(let message, _):
            return message
        case .mismatchedResult:
            return "Unexpected response from your Mac. Update both apps to the same version."
        }
    }
}
