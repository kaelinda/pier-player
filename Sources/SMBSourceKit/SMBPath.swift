import Foundation

public struct SMBPath: Hashable, Sendable, CustomStringConvertible {
    public let string: String

    public init(_ value: String) throws {
        guard !value.contains("\\"), !value.contains("\0") else {
            throw SMBConfigurationError.invalidPath
        }

        var components: [Substring] = []
        for component in value.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                throw SMBConfigurationError.invalidPath
            default:
                components.append(component)
            }
        }

        string = components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    public func appending(_ relativePath: String) throws -> SMBPath {
        guard !relativePath.hasPrefix("/") else {
            throw SMBConfigurationError.invalidPath
        }
        guard !relativePath.isEmpty else {
            return self
        }
        return try SMBPath(string + "/" + relativePath)
    }

    public var description: String { string }
}
