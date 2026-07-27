import Foundation

public struct SMBCredential: Sendable, CustomDebugStringConvertible {
    public let username: String
    public let password: String

    public init(username: String, password: String) throws {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            throw SMBConfigurationError.emptyUsername
        }

        self.username = username
        self.password = password
    }

    public var debugDescription: String {
        "SMBCredential(username: <redacted>, password: <redacted>)"
    }
}
