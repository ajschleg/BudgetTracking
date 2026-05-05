import Foundation

// MARK: - Protocol Messages

/// Messages exchanged between peers over the LAN sync connection.
enum SyncMessage: Codable {
    case handshake(PeerInfo)
    case syncRequest(SyncRequest)
    case syncResponse(SyncResponse)
    case syncAck(SyncAck)
    /// Sent by an iOS peer that wants the Mac peer to run a Plaid sync
    /// and push the new transactions back via the existing record
    /// channel. iOS can never originate Plaid data on its own (the
    /// access_token only lives on the Mac's /server/), so this is the
    /// remote-control flavor of "Refresh from Plaid".
    case requestPlaidRefresh(RequestPlaidRefresh)

    enum CodingKeys: String, CodingKey {
        case type, payload
    }

    enum MessageType: String, Codable {
        case handshake, syncRequest, syncResponse, syncAck, requestPlaidRefresh
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .handshake(let info):
            try container.encode(MessageType.handshake, forKey: .type)
            try container.encode(info, forKey: .payload)
        case .syncRequest(let req):
            try container.encode(MessageType.syncRequest, forKey: .type)
            try container.encode(req, forKey: .payload)
        case .syncResponse(let resp):
            try container.encode(MessageType.syncResponse, forKey: .type)
            try container.encode(resp, forKey: .payload)
        case .syncAck(let ack):
            try container.encode(MessageType.syncAck, forKey: .type)
            try container.encode(ack, forKey: .payload)
        case .requestPlaidRefresh(let req):
            try container.encode(MessageType.requestPlaidRefresh, forKey: .type)
            try container.encode(req, forKey: .payload)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        switch type {
        case .handshake:
            self = .handshake(try container.decode(PeerInfo.self, forKey: .payload))
        case .syncRequest:
            self = .syncRequest(try container.decode(SyncRequest.self, forKey: .payload))
        case .syncResponse:
            self = .syncResponse(try container.decode(SyncResponse.self, forKey: .payload))
        case .syncAck:
            self = .syncAck(try container.decode(SyncAck.self, forKey: .payload))
        case .requestPlaidRefresh:
            self = .requestPlaidRefresh(try container.decode(RequestPlaidRefresh.self, forKey: .payload))
        }
    }
}

extension SyncMessage {
    /// Human-readable message type for logging.
    var typeDescription: String {
        switch self {
        case .handshake: return "handshake"
        case .syncRequest: return "syncRequest"
        case .syncResponse(let resp): return "syncResponse(\(resp.records.count) records)"
        case .syncAck(let ack): return "syncAck(\(ack.recordsApplied) applied)"
        case .requestPlaidRefresh: return "requestPlaidRefresh"
        }
    }
}

/// Payload for SyncMessage.requestPlaidRefresh. Currently empty - the
/// receiver runs a full Plaid sync of all linked items. A future
/// extension can add an optional `itemId` to scope the refresh to a
/// single bank.
struct RequestPlaidRefresh: Codable {
    /// Free-form note for the responder's logs (e.g., "manual refresh
    /// from iPhone Settings"). Optional.
    let initiatorNote: String?

    init(initiatorNote: String? = nil) {
        self.initiatorNote = initiatorNote
    }
}

// MARK: - Supporting Types

struct PeerInfo: Codable {
    let deviceId: String
    let deviceName: String
    let appVersion: String
}

struct SyncRequest: Codable {
    /// The requesting peer's last known sync timestamp for this peer.
    let sinceDate: Date?
}

struct SyncResponse: Codable {
    let records: [SyncRecord]
    let syncTimestamp: Date
}

struct SyncAck: Codable {
    let syncTimestamp: Date
    let recordsApplied: Int
}

/// A single record to sync, wrapping any model type.
struct SyncRecord: Codable {
    let tableName: String
    let recordId: String
    let isDeleted: Bool
    let lastModifiedAt: Date
    let jsonData: Data // The full model encoded as JSON

    static func from<T: Codable>(_ record: T, tableName: String, id: String, isDeleted: Bool, lastModifiedAt: Date) throws -> SyncRecord {
        // Previously this used `try?` and produced an empty Data on encoder
        // failure - which then arrived at the peer as a "valid" SyncRecord
        // with 0-byte jsonData and silently failed to decode there. Throw
        // instead so the caller can log the offending row id/tablename
        // and skip it deliberately.
        let data = try JSONEncoder().encode(record)
        return SyncRecord(
            tableName: tableName,
            recordId: id,
            isDeleted: isDeleted,
            lastModifiedAt: lastModifiedAt,
            jsonData: data
        )
    }
}

// MARK: - Wire Protocol (length-prefixed framing)

enum SyncWireProtocol {

    enum WireError: Error, CustomStringConvertible {
        /// The 4-byte length prefix decoded to an implausibly large value,
        /// signalling buffer corruption (interleaved streams from a stale
        /// connection, or the head bytes were lost mid-message). Recovered
        /// by clearing the buffer at the call site.
        case implausibleLength(UInt32)

        var description: String {
            switch self {
            case .implausibleLength(let n):
                return "implausible message length \(n) - likely buffer corruption"
            }
        }
    }

    /// A single sync message can be large (a full DB syncResponse), but
    /// not infinite. Cap individual messages at 100 MB so a corrupted
    /// length prefix from interleaved streams gets caught instead of
    /// blocking decode forever.
    static let maxMessageBytes: UInt32 = 100 * 1024 * 1024

    /// Encode a message to a length-prefixed data packet.
    static func encode(_ message: SyncMessage) throws -> Data {
        let jsonData = try JSONEncoder().encode(message)
        var length = UInt32(jsonData.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(jsonData)
        return packet
    }

    /// Extract a complete message from a buffer. Returns the message and remaining bytes,
    /// or nil if the buffer doesn't contain a complete message yet.
    static func decode(from buffer: inout Data) throws -> SyncMessage? {
        guard buffer.count >= 4 else { return nil }

        let lengthBytes = buffer.prefix(4)
        let length = lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        // Sanity check: reject obviously corrupt prefixes before they make
        // us wait for billions of bytes that will never arrive.
        guard length <= maxMessageBytes else {
            throw WireError.implausibleLength(length)
        }

        let totalNeeded = 4 + Int(length)
        guard buffer.count >= totalNeeded else { return nil }

        let jsonData = buffer[4..<totalNeeded]
        buffer = Data(buffer[totalNeeded...])

        return try JSONDecoder().decode(SyncMessage.self, from: jsonData)
    }
}
