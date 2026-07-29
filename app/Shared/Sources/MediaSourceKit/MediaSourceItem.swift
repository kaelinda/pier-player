import Foundation

public struct MediaSourceItem: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case file
        case directory
    }

    public let name: String
    public let path: String
    public let kind: Kind
    public let size: Int64?
    public let modifiedAt: Date?

    public var id: String { path }

    public init(
        name: String,
        path: String,
        kind: Kind,
        size: Int64?,
        modifiedAt: Date?
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
    }

    public var isSupportedVideo: Bool {
        guard kind == .file else { return false }
        let fileExtension = (name as NSString).pathExtension.lowercased()
        return Self.supportedVideoExtensions.contains(fileExtension)
    }

    public static let supportedVideoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov",
    ]
}
