import Foundation

public enum DiagnosticPrivacyViolationCode: String, Codable, Equatable, Sendable {
    case invalidJSON = "invalid_json"
    case forbiddenKey = "forbidden_key"
    case smbURL = "smb_url"
    case absolutePath = "absolute_path"
    case credentialURL = "credential_url"
}

public struct DiagnosticPrivacyViolation: Error, Equatable, Sendable {
    public let code: DiagnosticPrivacyViolationCode

    public init(code: DiagnosticPrivacyViolationCode) {
        self.code = code
    }
}

public enum DiagnosticPrivacyAudit {
    private static let forbiddenKeys: Set<String> = [
        "credential",
        "credentials",
        "displayname",
        "domain",
        "filename",
        "filepath",
        "host",
        "hostname",
        "password",
        "path",
        "query",
        "share",
        "sharename",
        "sourcename",
        "url",
        "username",
    ]

    public static func validate(_ data: Data) throws {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            try validate(object)
            return
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw DiagnosticPrivacyViolation(code: .invalidJSON)
        }
        let lines = text.split(whereSeparator: \Character.isNewline)
        guard !lines.isEmpty else {
            throw DiagnosticPrivacyViolation(code: .invalidJSON)
        }
        for line in lines {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData)
            else {
                throw DiagnosticPrivacyViolation(code: .invalidJSON)
            }
            try validate(object)
        }
    }

    private static func validate(_ value: Any) throws {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                let normalizedKey = key.lowercased().filter(\.isLetter)
                if forbiddenKeys.contains(normalizedKey) {
                    throw DiagnosticPrivacyViolation(code: .forbiddenKey)
                }
                try validate(child)
            }
            return
        }
        if let array = value as? [Any] {
            for child in array {
                try validate(child)
            }
            return
        }
        if let string = value as? String {
            try validate(string)
        }
    }

    private static func validate(_ value: String) throws {
        let lowercased = value.lowercased()
        if lowercased.contains("smb://") {
            throw DiagnosticPrivacyViolation(code: .smbURL)
        }
        if value.hasPrefix("/") || value.hasPrefix("~/") || isWindowsPath(value) {
            throw DiagnosticPrivacyViolation(code: .absolutePath)
        }
        guard let components = URLComponents(string: value), components.scheme != nil else {
            return
        }
        if components.user != nil || components.password != nil {
            throw DiagnosticPrivacyViolation(code: .credentialURL)
        }
        let forbiddenQueryNames: Set<String> = ["password", "passwd", "token", "username", "user"]
        if components.queryItems?.contains(where: {
            forbiddenQueryNames.contains($0.name.lowercased())
        }) == true {
            throw DiagnosticPrivacyViolation(code: .credentialURL)
        }
    }

    private static func isWindowsPath(_ value: String) -> Bool {
        guard value.count >= 3 else { return false }
        let characters = Array(value)
        return characters[0].isLetter
            && characters[1] == ":"
            && (characters[2] == "\\" || characters[2] == "/")
    }
}
