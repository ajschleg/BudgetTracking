import XCTest
@testable import BudgetTracking

/// Round-trip and corruption-resilience tests for the LAN sync wire
/// protocol. Each scenario maps to a real bug we shipped during the
/// iOS port and would have caught at commit time:
///
/// - `testDecode_rejects_implausibleLength` regresses the multi-MB
///   "buffer waits forever for billions of bytes" symptom that came
///   from a corrupted 4-byte length prefix.
/// - `testDecode_returnsNilForIncompleteBuffer` confirms the
///   "wait for more bytes" path so partial NWConnection chunks don't
///   throw and clobber the buffer.
/// - `testDecode_supportsFragmentedAppend` mirrors the real
///   path where NWConnection delivers a 21 MB syncResponse across many
///   1 MB callbacks.
final class SyncWireProtocolTests: XCTestCase {

    // MARK: - Round trip

    func testRoundTrip_handshake() throws {
        let original: SyncMessage = .handshake(
            PeerInfo(deviceId: "abc", deviceName: "Test", appVersion: "1.0")
        )
        var buffer = try SyncWireProtocol.encode(original)
        let decoded = try SyncWireProtocol.decode(from: &buffer)

        guard case .handshake(let info) = decoded else {
            return XCTFail("expected handshake, got \(String(describing: decoded))")
        }
        XCTAssertEqual(info.deviceId, "abc")
        XCTAssertEqual(info.deviceName, "Test")
        XCTAssertTrue(buffer.isEmpty, "buffer should be drained after a clean decode")
    }

    func testRoundTrip_syncRequest_withSinceDate() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let original: SyncMessage = .syncRequest(SyncRequest(sinceDate: date))
        var buffer = try SyncWireProtocol.encode(original)
        let decoded = try SyncWireProtocol.decode(from: &buffer)

        guard case .syncRequest(let req) = decoded else {
            return XCTFail("expected syncRequest")
        }
        XCTAssertEqual(req.sinceDate, date)
    }

    func testRoundTrip_syncRequest_nilSinceDate() throws {
        let original: SyncMessage = .syncRequest(SyncRequest(sinceDate: nil))
        var buffer = try SyncWireProtocol.encode(original)
        let decoded = try SyncWireProtocol.decode(from: &buffer)

        guard case .syncRequest(let req) = decoded else {
            return XCTFail("expected syncRequest")
        }
        XCTAssertNil(req.sinceDate)
    }

    // MARK: - Buffer framing

    func testDecode_returnsNilForIncompleteBuffer() throws {
        // Encode a message but only feed in the first 3 bytes (less
        // than the 4-byte length prefix). decode must return nil and
        // leave the buffer untouched so the caller waits for more.
        let original: SyncMessage = .syncRequest(SyncRequest(sinceDate: nil))
        let full = try SyncWireProtocol.encode(original)
        var partial = full.prefix(3) // < length prefix

        let decoded = try SyncWireProtocol.decode(from: &partial)
        XCTAssertNil(decoded)
        XCTAssertEqual(partial.count, 3, "partial bytes should be preserved for next attempt")
    }

    func testDecode_returnsNilWhenLengthOkButPayloadShort() throws {
        // 4-byte prefix saying "10 bytes follow" but we only have 5.
        // Should return nil to wait for more, not throw.
        var prefix = UInt32(10).bigEndian
        var buffer = Data(bytes: &prefix, count: 4)
        buffer.append(Data(repeating: 0x7B, count: 5)) // "{" filler

        let decoded = try SyncWireProtocol.decode(from: &buffer)
        XCTAssertNil(decoded)
    }

    func testDecode_supportsFragmentedAppend() throws {
        // Mirror the production path: NWConnection delivers the
        // payload in two separate chunks, the receiver calls decode
        // after each append, and the second call yields the full
        // message.
        let original: SyncMessage = .handshake(
            PeerInfo(deviceId: "abc", deviceName: "Test", appVersion: "1.0")
        )
        let full = try SyncWireProtocol.encode(original)
        let split = full.count / 2

        var buffer = full.prefix(split)
        var first = Data(buffer)
        XCTAssertNil(try SyncWireProtocol.decode(from: &first))

        buffer = full
        var combined = Data(buffer)
        let decoded = try SyncWireProtocol.decode(from: &combined)
        XCTAssertNotNil(decoded)
    }

    // MARK: - Plaid RPC

    func testRoundTrip_plaidRPCRequest_createLinkToken() throws {
        let requestId = UUID()
        let original: SyncMessage = .plaidRPCRequest(
            PlaidRPCRequest(requestId: requestId, method: .createLinkToken)
        )
        var buffer = try SyncWireProtocol.encode(original)
        let decoded = try SyncWireProtocol.decode(from: &buffer)

        guard case .plaidRPCRequest(let req) = decoded else {
            return XCTFail("expected plaidRPCRequest, got \(String(describing: decoded))")
        }
        XCTAssertEqual(req.requestId, requestId)
        guard case .createLinkToken = req.method else {
            return XCTFail("expected createLinkToken method")
        }
    }

    func testRoundTrip_plaidRPCRequest_exchangePublicToken() throws {
        let requestId = UUID()
        let original: SyncMessage = .plaidRPCRequest(
            PlaidRPCRequest(
                requestId: requestId,
                method: .exchangePublicToken(PlaidExchangeParams(
                    publicToken: "public-sandbox-abc",
                    institutionId: "ins_109508",
                    institutionName: "First Platypus Bank"
                ))
            )
        )
        var buffer = try SyncWireProtocol.encode(original)
        let decoded = try SyncWireProtocol.decode(from: &buffer)

        guard case .plaidRPCRequest(let req) = decoded else {
            return XCTFail("expected plaidRPCRequest, got \(String(describing: decoded))")
        }
        XCTAssertEqual(req.requestId, requestId)
        guard case .exchangePublicToken(let params) = req.method else {
            return XCTFail("expected exchangePublicToken method")
        }
        XCTAssertEqual(params.publicToken, "public-sandbox-abc")
        XCTAssertEqual(params.institutionId, "ins_109508")
        XCTAssertEqual(params.institutionName, "First Platypus Bank")
    }

    func testRoundTrip_plaidRPCResponse_linkToken() throws {
        let requestId = UUID()
        let original: SyncMessage = .plaidRPCResponse(
            PlaidRPCResponse(
                requestId: requestId,
                result: .linkToken("link-sandbox-12345")
            )
        )
        var buffer = try SyncWireProtocol.encode(original)
        let decoded = try SyncWireProtocol.decode(from: &buffer)

        guard case .plaidRPCResponse(let resp) = decoded else {
            return XCTFail("expected plaidRPCResponse")
        }
        XCTAssertEqual(resp.requestId, requestId)
        guard case .linkToken(let token) = resp.result else {
            return XCTFail("expected linkToken result, got \(resp.result)")
        }
        XCTAssertEqual(token, "link-sandbox-12345")
    }

    func testRoundTrip_plaidRPCResponse_linkExchanged() throws {
        let requestId = UUID()
        let original: SyncMessage = .plaidRPCResponse(
            PlaidRPCResponse(
                requestId: requestId,
                result: .linkExchanged(
                    itemId: "item-uuid-1",
                    institution: "First Platypus Bank",
                    accountCount: 3
                )
            )
        )
        var buffer = try SyncWireProtocol.encode(original)
        let decoded = try SyncWireProtocol.decode(from: &buffer)

        guard case .plaidRPCResponse(let resp) = decoded else {
            return XCTFail("expected plaidRPCResponse")
        }
        guard case .linkExchanged(let itemId, let institution, let count) = resp.result else {
            return XCTFail("expected linkExchanged result, got \(resp.result)")
        }
        XCTAssertEqual(itemId, "item-uuid-1")
        XCTAssertEqual(institution, "First Platypus Bank")
        XCTAssertEqual(count, 3)
    }

    func testRoundTrip_plaidRPCResponse_failure_withCode() throws {
        // Failures must preserve both the user-facing message and the
        // stable code; the iOS caller maps codes to retry behavior so
        // dropping the code field would silently demote a recoverable
        // error to an opaque one.
        let requestId = UUID()
        let original: SyncMessage = .plaidRPCResponse(
            PlaidRPCResponse(
                requestId: requestId,
                result: .failure(
                    message: "Couldn't connect bank.",
                    code: "linkExchangeFailed"
                )
            )
        )
        var buffer = try SyncWireProtocol.encode(original)
        let decoded = try SyncWireProtocol.decode(from: &buffer)

        guard case .plaidRPCResponse(let resp) = decoded else {
            return XCTFail("expected plaidRPCResponse")
        }
        guard case .failure(let message, let code) = resp.result else {
            return XCTFail("expected failure result, got \(resp.result)")
        }
        XCTAssertEqual(message, "Couldn't connect bank.")
        XCTAssertEqual(code, "linkExchangeFailed")
    }

    func testRoundTrip_plaidRPCResponse_failure_noCode() throws {
        // `code` is optional so legacy/unrecognized failure paths
        // still round-trip cleanly without nil-vs-missing-key issues
        // on the JSON layer.
        let original: SyncMessage = .plaidRPCResponse(
            PlaidRPCResponse(
                requestId: UUID(),
                result: .failure(message: "Generic failure", code: nil)
            )
        )
        var buffer = try SyncWireProtocol.encode(original)
        let decoded = try SyncWireProtocol.decode(from: &buffer)

        guard case .plaidRPCResponse(let resp) = decoded,
              case .failure(_, let code) = resp.result else {
            return XCTFail("expected plaidRPCResponse(failure)")
        }
        XCTAssertNil(code)
    }

    // MARK: - Corruption guard

    func testDecode_rejects_implausibleLength() {
        // Hand-craft a buffer whose 4-byte prefix decodes to a value
        // bigger than maxMessageBytes. Without the guard, decode would
        // sit waiting for those bytes forever and the buffer would
        // grow without bound (real symptom: 15+ MB endpoint-keyed
        // buffer on the Mac during the dual-connection race).
        var bogus = UInt32(SyncWireProtocol.maxMessageBytes + 1).bigEndian
        var buffer = Data(bytes: &bogus, count: 4)
        // Pad with junk so the buffer is "long enough" by some
        // arbitrary amount; decode should still reject on the prefix.
        buffer.append(Data(repeating: 0x00, count: 16))

        XCTAssertThrowsError(try SyncWireProtocol.decode(from: &buffer)) { error in
            guard case SyncWireProtocol.WireError.implausibleLength(let n) = error else {
                return XCTFail("expected implausibleLength, got \(error)")
            }
            XCTAssertGreaterThan(n, SyncWireProtocol.maxMessageBytes)
        }
    }
}
