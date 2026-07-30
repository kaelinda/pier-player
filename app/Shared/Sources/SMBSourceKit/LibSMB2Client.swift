import Darwin
import DiagnosticsKit
import Foundation
import SMB2

public actor LibSMB2Client: SMBClient {
    private let configuration: SMBConnectionConfiguration
    private let credential: SMBCredential
    private let nativeFactory: any SMBNativeConnectionFactory
    private let diagnosticRecorder: any DiagnosticRecording
    private let diagnosticContext: DiagnosticContext
    private let identityProvider: (any DiagnosticIdentityProviding)?
    private var connection: (any SMBNativeConnection)?

    public init(
        configuration: SMBConnectionConfiguration,
        credential: SMBCredential,
        diagnosticRecorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        diagnosticContext: DiagnosticContext? = nil,
        identityProvider: (any DiagnosticIdentityProviding)? = nil
    ) {
        self.configuration = configuration
        self.credential = credential
        nativeFactory = SystemLibSMB2ConnectionFactory()
        self.diagnosticRecorder = diagnosticRecorder
        self.diagnosticContext = diagnosticContext ?? makeLibSMB2DiagnosticContext()
        self.identityProvider = identityProvider
    }

    public init(
        sourceID: UUID = UUID(),
        displayName: String,
        host: String,
        share: String,
        domain: String? = nil,
        requiresEncryption: Bool = false,
        credential: SMBCredential,
        diagnosticRecorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        diagnosticContext: DiagnosticContext? = nil,
        identityProvider: (any DiagnosticIdentityProviding)? = nil
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
        self.diagnosticRecorder = diagnosticRecorder
        self.diagnosticContext = diagnosticContext ?? makeLibSMB2DiagnosticContext()
        self.identityProvider = identityProvider
    }

    init(
        configuration: SMBConnectionConfiguration,
        credential: SMBCredential,
        nativeFactory: any SMBNativeConnectionFactory,
        diagnosticRecorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        diagnosticContext: DiagnosticContext? = nil,
        identityProvider: (any DiagnosticIdentityProviding)? = nil
    ) {
        self.configuration = configuration
        self.credential = credential
        self.nativeFactory = nativeFactory
        self.diagnosticRecorder = diagnosticRecorder
        self.diagnosticContext = diagnosticContext ?? makeLibSMB2DiagnosticContext()
        self.identityProvider = identityProvider
    }

    init(
        sourceID: UUID = UUID(),
        displayName: String,
        host: String,
        share: String,
        domain: String? = nil,
        requiresEncryption: Bool = false,
        credential: SMBCredential,
        nativeFactory: any SMBNativeConnectionFactory,
        diagnosticRecorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        diagnosticContext: DiagnosticContext? = nil,
        identityProvider: (any DiagnosticIdentityProviding)? = nil
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
        self.diagnosticRecorder = diagnosticRecorder
        self.diagnosticContext = diagnosticContext ?? makeLibSMB2DiagnosticContext()
        self.identityProvider = identityProvider
    }

    public func connect() async throws {
        guard connection == nil else { return }
        let operation = DiagnosticOperation(
            recorder: diagnosticRecorder,
            parentContext: diagnosticContext,
            name: .smbConnect,
            level: .info,
            payload: DiagnosticPayload(sourceID: configuration.sourceID),
            persistence: .essential
        )
        do {
            connection = try await nativeFactory.connect(
                configuration: configuration,
                credential: credential
            )
            operation.end(
                outcome: .success,
                payload: DiagnosticPayload(sourceID: configuration.sourceID)
            )
        } catch {
            recordLibSMB2Failure(
                error,
                operation: operation,
                sourceID: configuration.sourceID
            )
            throw error
        }
    }

    public func disconnect() async {
        guard let connection else { return }
        self.connection = nil
        await connection.disconnect()
    }

    public func list(directory path: SMBPath) async throws -> [SMBDirectoryEntry] {
        let operation = DiagnosticOperation(
            recorder: diagnosticRecorder,
            parentContext: diagnosticContext,
            name: .smbList,
            payload: DiagnosticPayload(sourceID: configuration.sourceID),
            persistence: .essential
        )
        guard let connection else {
            operation.end(
                outcome: .failure,
                payload: DiagnosticPayload(sourceID: configuration.sourceID),
                error: diagnosticDescriptor(for: SMBClientError.notConnected)
            )
            throw SMBClientError.notConnected
        }
        do {
            let entries = try await connection.list(directory: path)
            operation.end(
                outcome: .success,
                payload: DiagnosticPayload(sourceID: configuration.sourceID)
            )
            return entries
        } catch {
            recordLibSMB2Failure(
                error,
                operation: operation,
                sourceID: configuration.sourceID
            )
            throw error
        }
    }

    public func open(file path: SMBPath) async throws -> SMBOpenedFile {
        let container = DiagnosticContainerKind(fileName: path.string)
        let operation = DiagnosticOperation(
            recorder: diagnosticRecorder,
            parentContext: diagnosticContext,
            name: .smbOpen,
            level: .info,
            payload: DiagnosticPayload(
                sourceID: configuration.sourceID,
                container: container
            ),
            persistence: .essential
        )
        guard connection != nil else {
            operation.end(
                outcome: .failure,
                payload: DiagnosticPayload(
                    sourceID: configuration.sourceID,
                    container: container
                ),
                error: diagnosticDescriptor(for: SMBClientError.notConnected)
            )
            throw SMBClientError.notConnected
        }

        do {
            let fileConnection = try await nativeFactory.connect(
                configuration: configuration,
                credential: credential
            )
            do {
                let statOperation = DiagnosticOperation(
                    recorder: diagnosticRecorder,
                    parentContext: operation.context,
                    name: .smbStat,
                    payload: DiagnosticPayload(
                        sourceID: configuration.sourceID,
                        container: container
                    ),
                    persistence: .essential
                )
                let stat: SMBNativeStat
                do {
                    stat = try await fileConnection.stat(path: path)
                    statOperation.end(
                        outcome: .success,
                        payload: DiagnosticPayload(
                            sourceID: configuration.sourceID,
                            container: container,
                            fileSize: stat.size
                        )
                    )
                } catch {
                    recordLibSMB2Failure(
                        error,
                        operation: statOperation,
                        sourceID: configuration.sourceID,
                        container: container
                    )
                    throw error
                }
                guard stat.kind == .file else {
                    throw SMBClientError.unsupported
                }
                let handle = try await fileConnection.open(file: path)
                let fileID = identityProvider?.fileIdentity(
                    sourceID: configuration.sourceID,
                    normalizedPath: path.string,
                    size: stat.size,
                    modifiedAt: stat.modifiedAt
                ).value
                let file = LibSMB2File(
                    size: stat.size,
                    handle: handle,
                    connection: fileConnection,
                    diagnosticRecorder: diagnosticRecorder,
                    diagnosticContext: operation.context,
                    sourceID: configuration.sourceID,
                    fileID: fileID
                )
                operation.end(
                    outcome: .success,
                    payload: DiagnosticPayload(
                        sourceID: configuration.sourceID,
                        fileID: fileID,
                        container: container,
                        fileSize: stat.size
                    )
                )
                return SMBOpenedFile(file: file, size: stat.size, modifiedAt: stat.modifiedAt)
            } catch {
                await fileConnection.disconnect()
                throw error
            }
        } catch {
            recordLibSMB2Failure(
                error,
                operation: operation,
                sourceID: configuration.sourceID,
                container: container
            )
            throw error
        }
    }
}

private func makeLibSMB2DiagnosticContext() -> DiagnosticContext {
    DiagnosticContext(appRunID: UUID(), activityID: UUID(), operationID: UUID())
}

private func recordLibSMB2Failure(
    _ error: Error,
    operation: DiagnosticOperation,
    sourceID: UUID,
    container: DiagnosticContainerKind? = nil
) {
    if error is CancellationError {
        operation.end(
            outcome: .cancelled,
            payload: DiagnosticPayload(sourceID: sourceID, container: container)
        )
    } else {
        operation.end(
            outcome: .failure,
            payload: DiagnosticPayload(sourceID: sourceID, container: container),
            error: diagnosticDescriptor(for: error)
        )
    }
}

private func diagnosticDescriptor(for error: Error) -> DiagnosticErrorDescriptor {
    guard let error = error as? SMBClientError else {
        return DiagnosticErrorDescriptor(code: .sourceUnreachable, isRetryable: true)
    }
    return switch error {
    case .notConnected:
        DiagnosticErrorDescriptor(code: .sourceNotConnected, isRetryable: true)
    case .authenticationFailed:
        DiagnosticErrorDescriptor(code: .sourceAuthenticationFailed)
    case .unreachable:
        DiagnosticErrorDescriptor(code: .sourceUnreachable, isRetryable: true)
    case .notFound:
        DiagnosticErrorDescriptor(code: .sourceNotFound)
    case .invalidRead:
        DiagnosticErrorDescriptor(code: .sourceInvalidRead)
    case .readFailed:
        DiagnosticErrorDescriptor(code: .sourceReadFailed, isRetryable: true)
    case .remoteFileChanged:
        DiagnosticErrorDescriptor(code: .sourceRemoteFileChanged)
    case .unsupported:
        DiagnosticErrorDescriptor(code: .sourceUnsupported)
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
