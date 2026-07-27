import Foundation

public enum SMBConfigurationError: Error, Equatable, Sendable {
    case emptyDisplayName
    case emptyHost
    case invalidHost
    case emptyShare
    case invalidShare
    case emptyUsername
    case invalidPath
}

public struct SMBConnectionConfiguration: Hashable, Sendable {
    public let sourceID: UUID
    public let displayName: String
    public let host: String
    public let share: String
    public let domain: String?
    public let requiresEncryption: Bool

    public init(
        sourceID: UUID = UUID(),
        displayName: String,
        host: String,
        share: String,
        domain: String? = nil,
        requiresEncryption: Bool = false
    ) throws {
        let displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            throw SMBConfigurationError.emptyDisplayName
        }

        let host = try Self.normalizeHost(host)
        let share = try Self.normalizeShare(share)
        let domain = domain?.trimmingCharacters(in: .whitespacesAndNewlines)

        self.sourceID = sourceID
        self.displayName = displayName
        self.host = host
        self.share = share
        self.domain = domain?.isEmpty == false ? domain : nil
        self.requiresEncryption = requiresEncryption
    }

    private static func normalizeHost(_ value: String) throws -> String {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw SMBConfigurationError.emptyHost
        }

        if host.lowercased().hasPrefix("smb://") {
            host.removeFirst("smb://".count)
        }

        guard !host.isEmpty else {
            throw SMBConfigurationError.emptyHost
        }

        let invalidCharacters = CharacterSet(charactersIn: "/\\:@?#")
            .union(.whitespacesAndNewlines)
        guard host.rangeOfCharacter(from: invalidCharacters) == nil else {
            throw SMBConfigurationError.invalidHost
        }
        return host
    }

    private static func normalizeShare(_ value: String) throws -> String {
        let share = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !share.isEmpty else {
            throw SMBConfigurationError.emptyShare
        }
        guard !share.contains("/"), !share.contains("\\") else {
            throw SMBConfigurationError.invalidShare
        }
        return share
    }
}
