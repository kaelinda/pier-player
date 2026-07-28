import Foundation

public struct MediaFileIdentity: Hashable, Codable, Sendable {
    public let sourceID: UUID
    public let path: String
    public let size: Int64
    public let modifiedAt: Date?

    public init(
        sourceID: UUID,
        path: String,
        size: Int64,
        modifiedAt: Date?
    ) {
        self.sourceID = sourceID
        self.path = path
        self.size = size
        self.modifiedAt = modifiedAt
    }
}
