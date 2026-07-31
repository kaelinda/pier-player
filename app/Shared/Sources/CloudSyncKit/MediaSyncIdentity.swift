import CryptoKit
import Foundation
import MediaSourceKit

public enum MediaSyncIdentity {
    public static func make(from identity: MediaFileIdentity) -> String {
        var canonical = Data("pier-player-media-v1".utf8)
        canonical.appendLengthPrefixed(identity.sourceID.uuidString.lowercased())
        canonical.appendLengthPrefixed(normalize(identity.path))
        canonical.appendInteger(identity.size)
        if let modifiedAt = identity.modifiedAt {
            canonical.appendInteger(Int64(modifiedAt.timeIntervalSince1970 * 1_000))
        } else {
            canonical.appendInteger(Int64.min)
        }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalize(_ path: String) -> String {
        "/" + path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
    }
}

private extension Data {
    mutating func appendLengthPrefixed(_ value: String) {
        let bytes = Data(value.utf8)
        appendInteger(UInt64(bytes.count))
        append(bytes)
    }

    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
