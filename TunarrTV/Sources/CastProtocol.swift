#if os(iOS)
import Foundation

/// Minimal, dependency-free CASTV2 wire format. Chromecast frames each
/// `CastMessage` protobuf with a 4-byte big-endian length prefix over a TLS
/// socket (port 8009). We only ever need to *write* a full message and to
/// *read* two of its fields (namespace + JSON payload), so the whole protobuf
/// is hand-encoded here rather than pulling in SwiftProtobuf — keeping the app
/// free of third-party code dependencies.
enum CastNS {
    static let connection = "urn:x-cast:com.google.cast.tp.connection"
    static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let receiver = "urn:x-cast:com.google.cast.receiver"
    static let media = "urn:x-cast:com.google.cast.media"
}

enum CastProto {
    /// The CastMessage schema (all fields required except payloads):
    ///   1 protocol_version (varint, 0 = CASTV2_1_0)
    ///   2 source_id (string)   3 destination_id (string)   4 namespace (string)
    ///   5 payload_type (varint, 0 = STRING)   6 payload_utf8 (string)
    static func frame(namespace: String, source: String, destination: String, payload: String) -> Data {
        var body = Data()
        appendVarint(1 << 3 | 0, to: &body); appendVarint(0, to: &body)      // field 1 = 0
        appendString(2, source, to: &body)
        appendString(3, destination, to: &body)
        appendString(4, namespace, to: &body)
        appendVarint(5 << 3 | 0, to: &body); appendVarint(0, to: &body)      // field 5 = 0 (STRING)
        appendString(6, payload, to: &body)

        var out = Data(capacity: body.count + 4)
        let len = UInt32(body.count)
        out.append(UInt8((len >> 24) & 0xFF))
        out.append(UInt8((len >> 16) & 0xFF))
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        out.append(body)
        return out
    }

    /// Pulls every complete length-prefixed message out of a running TCP
    /// buffer, leaving any partial trailing frame in place.
    static func extractFrames(from buffer: inout Data) -> [[UInt8]] {
        var messages: [[UInt8]] = []
        let bytes = [UInt8](buffer)
        var offset = 0
        while bytes.count - offset >= 4 {
            let len = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            let total = 4 + len
            guard bytes.count - offset >= total else { break }
            messages.append(Array(bytes[(offset + 4)..<(offset + total)]))
            offset += total
        }
        if offset > 0 { buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: offset)) }
        return messages
    }

    /// Extracts just namespace (field 4) and payload_utf8 (field 6) from a
    /// CastMessage body, skipping everything else on the wire.
    static func parse(_ bytes: [UInt8]) -> (namespace: String, payload: String)? {
        var i = 0
        var namespace = ""
        var payload = ""
        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < bytes.count {
                let b = bytes[i]; i += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < bytes.count {
            guard let tag = readVarint() else { break }
            let field = tag >> 3
            switch tag & 0x7 {
            case 0: if readVarint() == nil { return nil }              // varint
            case 2:                                                     // length-delimited
                guard let len = readVarint() else { return nil }
                let n = Int(len)
                guard i + n <= bytes.count else { return nil }
                let slice = bytes[i..<i + n]; i += n
                if field == 4 { namespace = String(decoding: slice, as: UTF8.self) }
                else if field == 6 { payload = String(decoding: slice, as: UTF8.self) }
            case 5: i += 4                                              // 32-bit
            case 1: i += 8                                              // 64-bit
            default: return nil
            }
        }
        return (namespace, payload)
    }

    // MARK: - protobuf primitives
    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var v = value
        while v >= 0x80 { data.append(UInt8((v & 0x7F) | 0x80)); v >>= 7 }
        data.append(UInt8(v))
    }

    private static func appendString(_ field: UInt64, _ string: String, to data: inout Data) {
        let utf8 = Array(string.utf8)
        appendVarint(field << 3 | 2, to: &data)
        appendVarint(UInt64(utf8.count), to: &data)
        data.append(contentsOf: utf8)
    }
}
#endif
