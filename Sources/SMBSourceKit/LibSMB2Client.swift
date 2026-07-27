import Darwin
import Foundation
import SMB2

public actor LibSMB2Client: SMBClient {
    private let configuration: SMBConnectionConfiguration
    private let credential: SMBCredential
    private let nativeFactory: any SMBNativeConnectionFactory
    private var connection: (any SMBNativeConnection)?

    public init(
        configuration: SMBConnectionConfiguration,
        credential: SMBCredential
    ) {
        self.configuration = configuration
        self.credential = credential
        nativeFactory = SystemLibSMB2ConnectionFactory()
    }

    public init(
        sourceID: UUID = UUID(),
        displayName: String,
        host: String,
        share: String,
        domain: String? = nil,
        requiresEncryption: Bool = false,
        credential: SMBCredential
    ) throws {
        configuration = try SMBConnectionConfiguration(
            sourceID: sourceID,
            displayName: displayName,
            host: host,
            share: share,
            domain: domain,
            requiresEncryption: requiresEncryption
        )
        self.credential = credential
        nativeFactory = SystemLibSMB2ConnectionFactory()
    }

    init(
        configuration: SMBConnectionConfiguration,
        credential: SMBCredential,
        nativeFactory: any SMBNativeConnectionFactory
    ) {
        self.configuration = configuration
        self.credential = credential
        self.nativeFactory = nativeFactory
    }

    init(
        sourceID: UUID = UUID(),
        displayName: String,
        host: String,
        share: String,
        domain: String? = nil,
        requiresEncryption: Bool = false,
        credential: SMBCredential,
        nativeFactory: any SMBNativeConnectionFactory
    ) throws {
        configuration = try SMBConnectionConfiguration(
            sourceID: sourceID,
            displayName: displayName,
            host: host,
            share: share,
            domain: domain,
            requiresEncryption: requiresEncryption
        )
        self.credential = credential
        self.nativeFactory = nativeFactory
    }

    public func connect() async throws {
        guard connection == nil else { return }
        connection = try await nativeFactory.connect(
            configuration: configuration,
            credential: credential
        )
    }

    public func disconnect() async {
        guard let connection else { return }
        self.connection = nil
        await connection.disconnect()
    }

    public func list(directory path: SMBPath) async throws -> [SMBDirectoryEntry] {
        guard let connection else {
            throw SMBClientError.notConnected
        }
        return try await connection.list(directory: path)
    }

    public func open(file path: SMBPath) async throws -> SMBOpenedFile {
        guard connection != nil else {
            throw SMBClientError.notConnected
        }

        let fileConnection = try await nativeFactory.connect(
            configuration: configuration,
            credential: credential
        )
        do {
            let stat = try await fileConnection.stat(path: path)
            guard stat.kind == .file else {
                throw SMBClientError.unsupported
            }
            let handle = try await fileConnection.open(file: path)
            let file = LibSMB2File(
                size: stat.size,
                handle: handle,
                connection: fileConnection
            )
            return SMBOpenedFile(file: file, size: stat.size, modifiedAt: stat.modifiedAt)
        } catch {
            await fileConnection.disconnect()
            throw error
        }
    }
}

private struct SystemLibSMB2ConnectionFactory: SMBNativeConnectionFactory {
    func connect(
        configuration: SMBConnectionConfiguration,
        credential: SMBCredential
    ) async throws -> any SMBNativeConnection {
        try await SystemLibSMB2Connection.connect(
            configuration: configuration,
            credential: credential
        )
    }
}

final class SystemLibSMB2Connection: SMBNativeConnection, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.pier-player.libsmb2.context")
    private let queueKey = DispatchSpecificKey<Void>()
    private let state = State()

    private init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            state.destroyContext()
        } else {
            queue.sync { state.destroyContext() }
        }
    }

    static func connect(
        configuration: SMBConnectionConfiguration,
        credential: SMBCredential
    ) async throws -> SystemLibSMB2Connection {
        let connection = SystemLibSMB2Connection()
        try await connection.initialize(configuration: configuration, credential: credential)
        return connection
    }

    func list(directory path: SMBPath) async throws -> [SMBDirectoryEntry] {
        try await perform { context in
            guard let directory = smb2_opendir(context, Self.nativePath(path)) else {
                throw mapLibSMB2Status(-Self.lastErrorCode(context), operation: .list)
            }
            defer { smb2_closedir(context, directory) }

            var entries: [SMBDirectoryEntry] = []
            while let entry = smb2_readdir(context, directory)?.pointee {
                guard let name = entry.name else { continue }
                let stat = try Self.convertStat(entry.st)
                entries.append(SMBDirectoryEntry(
                    name: String(cString: name),
                    kind: stat.kind,
                    size: stat.kind == .file ? stat.size : nil,
                    modifiedAt: stat.modifiedAt
                ))
            }
            return entries
        }
    }

    func stat(path: SMBPath) async throws -> SMBNativeStat {
        try await perform { context in
            var value = smb2_stat_64()
            let status = smb2_stat(context, Self.nativePath(path), &value)
            guard status == 0 else {
                throw mapLibSMB2Status(status, operation: .stat)
            }
            return try Self.convertStat(value)
        }
    }

    func open(file path: SMBPath) async throws -> any SMBNativeFileHandle {
        try await perform { context in
            guard let handle = smb2_open(context, Self.nativePath(path), O_RDONLY) else {
                throw mapLibSMB2Status(-Self.lastErrorCode(context), operation: .open)
            }
            return SystemLibSMB2FileHandle(connection: self, handle: handle)
        }
    }

    func disconnect() async {
        try? await perform { context in
            _ = smb2_disconnect_share(context)
            self.state.destroyContext()
        }
    }

    func perform<T: Sendable>(
        _ operation: @escaping @Sendable (UnsafeMutablePointer<smb2_context>) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<T, any Error>) in
            queue.async {
                do {
                    guard let context = self.state.context else {
                        throw SMBClientError.notConnected
                    }
                    continuation.resume(returning: try operation(context))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func initialize(
        configuration: SMBConnectionConfiguration,
        credential: SMBCredential
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard let context = smb2_init_context() else {
                    continuation.resume(throwing: SMBClientError.unreachable)
                    return
                }
                self.state.context = context

                smb2_set_security_mode(context, UInt16(SMB2_NEGOTIATE_SIGNING_ENABLED))
                smb2_set_seal(context, configuration.requiresEncryption ? 1 : 0)
                smb2_set_authentication(context, Int32(SMB2_SEC_NTLMSSP.rawValue))
                smb2_set_user(context, credential.username)
                smb2_set_password(context, credential.password)
                smb2_set_domain(context, configuration.domain ?? "")

                let status = smb2_connect_share(
                    context,
                    configuration.host,
                    configuration.share,
                    credential.username
                )
                guard status == 0 else {
                    let error = mapLibSMB2Status(status, operation: .connect)
                    self.state.destroyContext()
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private static func nativePath(_ path: SMBPath) -> String {
        path.string == "/" ? "" : String(path.string.dropFirst())
    }

    private static func convertStat(_ value: smb2_stat_64) throws -> SMBNativeStat {
        guard value.smb2_size <= UInt64(Int64.max) else {
            throw SMBClientError.unsupported
        }
        let kind: SMBDirectoryEntry.Kind = value.smb2_type == SMB2_TYPE_DIRECTORY
            ? .directory
            : .file
        let modifiedAt = value.smb2_mtime == 0
            ? nil
            : Date(
                timeIntervalSince1970: TimeInterval(value.smb2_mtime)
                    + TimeInterval(value.smb2_mtime_nsec) / 1_000_000_000
            )
        return SMBNativeStat(
            size: Int64(value.smb2_size),
            modifiedAt: modifiedAt,
            kind: kind
        )
    }

    private static func lastErrorCode(
        _ context: UnsafeMutablePointer<smb2_context>
    ) -> Int32 {
        let ntStatus = UInt32(bitPattern: smb2_get_nterror(context))
        let mappedError = nterror_to_errno(ntStatus)
        if mappedError != 0 { return mappedError }
        return errno == 0 ? EIO : errno
    }

    private final class State: @unchecked Sendable {
        var context: UnsafeMutablePointer<smb2_context>?

        func destroyContext() {
            guard let context else { return }
            self.context = nil
            smb2_destroy_context(context)
        }
    }
}

enum LibSMB2Operation {
    case connect
    case list
    case stat
    case open
    case read
}

func mapLibSMB2Status(_ status: Int32, operation: LibSMB2Operation) -> SMBClientError {
    let code = status < 0 ? -status : status
    switch code {
    case EACCES, EPERM:
        return .authenticationFailed
    case ENOENT:
        return .notFound
    case ENOTCONN:
        return .notConnected
    case ECONNREFUSED, ECONNRESET, EHOSTUNREACH, ENETUNREACH, ETIMEDOUT:
        return .unreachable
    default:
        switch operation {
        case .connect, .list:
            return .unreachable
        case .stat, .open:
            return .notFound
        case .read:
            return .readFailed
        }
    }
}
