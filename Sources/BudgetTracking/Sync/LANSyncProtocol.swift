import Foundation

// MARK: - Protocol Messages

/// Messages exchanged between peers over the LAN sync connection.
enum SyncMessage: Codable {
    case handshake(PeerInfo)
    case syncRequest(SyncRequest)
    case syncResponse(SyncResponse)
    case syncAck(SyncAck)

    enum CodingKeys: String, CodingKey {
        case type, payload
    }

    enum MessageType: String, Codable {
        case handshake, syncRequest, syncResponse, syncAck
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
        }
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

    static func from<T: Codable>(_ record: T, tableName: String, id: String, isDeleted: Bool, lastModifiedAt: Date) -> SyncRecord {
        let data = (try? JSONEncoder().encode(record)) ?? Data()
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

        let totalNeeded = 4 + Int(length)
        guard buffer.count >= totalNeeded else { return nil }

        let jsonData = buffer[4..<totalNeeded]
        buffer = Data(buffer[totalNeeded...])

        return try JSONDecoder().decode(SyncMessage.self, from: jsonData)
    }
}
