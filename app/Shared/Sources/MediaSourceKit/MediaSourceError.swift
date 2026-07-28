import Foundation

public enum MediaSourceError: Error, Equatable, Sendable {
    case notConnected
    case authenticationFailed
    case unreachable(details: String?)
    case notFound(path: String)
    case invalidRead(offset: Int64, length: Int)
    case readFailed(details: String?)
    case remoteFileChanged
    case unsupported(reason: String)
}
