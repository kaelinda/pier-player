import DiagnosticsKit
import Foundation
import MediaSourceKit

public actor SMBMediaSource: MediaSource {
    public nonisolated let id: UUID
    public nonisolated let displayName: String

    private let client: any SMBClient
    private let diagnosticRecorder: any DiagnosticRecording
    private let diagnosticContext: DiagnosticContext
    private let identityProvider: (any DiagnosticIdentityProviding)?
    private var isConnected = false

    public init(
        configuration: SMBConnectionConfiguration,
        client: any SMBClient,
        diagnosticRecorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        diagnosticContext: DiagnosticContext? = nil,
        identityProvider: (any DiagnosticIdentityProviding)? = nil
    ) {
        id = configuration.sourceID
        displayName = configuration.displayName
        self.client = client
        self.diagnosticRecorder = diagnosticRecorder
        self.diagnosticContext = diagnosticContext ?? makeDefaultDiagnosticContext()
        self.identityProvider = identityProvider
    }

    public func connect() async throws {
        let operation = DiagnosticOperation(
            recorder: diagnosticRecorder,
            parentContext: diagnosticContext,
            name: .sourceConnect,
            level: .info,
            payload: sourcePayload,
            persistence: .essential
        )
        do {
            try await client.connect()
            isConnected = true
            operation.end(outcome: .success, payload: sourcePayload)
        } catch {
            isConnected = false
            if error is CancellationError {
                operation.end(outcome: .cancelled, payload: sourcePayload)
                throw error
            }
            let mapped = mapSMBError(error)
            operation.end(
                outcome: .failure,
                payload: sourcePayload,
                error: diagnosticDescriptor(for: mapped)
            )
            throw mapped
        }
    }

    public func disconnect() async {
        let operation = DiagnosticOperation(
            recorder: diagnosticRecorder,
            parentContext: diagnosticContext,
            name: .sourceDisconnect,
            level: .info,
            payload: sourcePayload,
            persistence: .essential
        )
        isConnected = false
        await client.disconnect()
        operation.end(outcome: .success, payload: sourcePayload)
    }

    public func list(directory path: String) async throws -> [MediaSourceItem] {
        let operation = DiagnosticOperation(
            recorder: diagnosticRecorder,
            parentContext: diagnosticContext,
            name: .directoryList,
            payload: sourcePayload,
            persistence: .essential
        )
        guard isConnected else {
            operation.end(
                outcome: .failure,
                payload: sourcePayload,
                error: diagnosticDescriptor(for: MediaSourceError.notConnected)
            )
            throw MediaSourceError.notConnected
        }

        do {
            let directory = try SMBPath(path)
            let entries = try await client.list(directory: directory)
            let items = try entries
                .filter { !$0.name.hasPrefix(".") }
                .map { entry in
                    let childPath = try directory.appending(entry.name)
                    return MediaSourceItem(
                        name: entry.name,
                        path: childPath.string,
                        kind: entry.kind == .directory ? .directory : .file,
                        size: entry.size,
                        modifiedAt: entry.modifiedAt
                    )
                }
                .sorted(by: Self.sortItems)
            operation.end(outcome: .success, payload: sourcePayload)
            return items
        } catch {
            if error is CancellationError {
                operation.end(outcome: .cancelled, payload: sourcePayload)
                throw error
            }
            let mapped = mapSMBError(error, path: path)
            operation.end(
                outcome: .failure,
                payload: sourcePayload,
                error: diagnosticDescriptor(for: mapped)
            )
            throw mapped
        }
    }

    public func open(file path: String) async throws -> any MediaReadableFile {
        let container = DiagnosticContainerKind(fileName: path)
        let operation = DiagnosticOperation(
            recorder: diagnosticRecorder,
            parentContext: diagnosticContext,
            name: .fileOpen,
            level: .info,
            payload: DiagnosticPayload(sourceID: id, container: container),
            persistence: .essential
        )
        guard isConnected else {
            operation.end(
                outcome: .failure,
                payload: DiagnosticPayload(sourceID: id, container: container),
                error: diagnosticDescriptor(for: MediaSourceError.notConnected)
            )
            throw MediaSourceError.notConnected
        }

        do {
            let normalizedPath = try SMBPath(path)
            let opened = try await client.open(file: normalizedPath)
            let identity = MediaFileIdentity(
                sourceID: id,
                path: normalizedPath.string,
                size: opened.size,
                modifiedAt: opened.modifiedAt
            )
            let fileID = identityProvider?.fileIdentity(
                sourceID: id,
                normalizedPath: normalizedPath.string,
                size: opened.size,
                modifiedAt: opened.modifiedAt
            ).value
            let payload = DiagnosticPayload(
                sourceID: id,
                fileID: fileID,
                container: container,
                fileSize: opened.size
            )
            operation.end(outcome: .success, payload: payload)
            return SMBReadableFile(
                identity: identity,
                file: opened.file,
                diagnosticRecorder: diagnosticRecorder,
                diagnosticContext: operation.context,
                fileID: fileID,
                container: container
            )
        } catch {
            if error is CancellationError {
                operation.end(
                    outcome: .cancelled,
                    payload: DiagnosticPayload(sourceID: id, container: container)
                )
                throw error
            }
            let mapped = mapSMBError(error, path: path)
            operation.end(
                outcome: .failure,
                payload: DiagnosticPayload(sourceID: id, container: container),
                error: diagnosticDescriptor(for: mapped)
            )
            throw mapped
        }
    }

    private var sourcePayload: DiagnosticPayload {
        DiagnosticPayload(sourceID: id)
    }

    private static func sortItems(_ lhs: MediaSourceItem, _ rhs: MediaSourceItem) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind == .directory
        }
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if comparison == .orderedSame {
            return lhs.name < rhs.name
        }
        return comparison == .orderedAscending
    }
}

private actor SMBReadableFile: MediaReadableFile {
    nonisolated let identity: MediaFileIdentity
    private let file: any SMBClientFile
    private let diagnosticRecorder: any DiagnosticRecording
    private let diagnosticContext: DiagnosticContext
    private let fileID: String?
    private let container: DiagnosticContainerKind
    private var isClosed = false

    init(
        identity: MediaFileIdentity,
        file: any SMBClientFile,
        diagnosticRecorder: any DiagnosticRecording,
        diagnosticContext: DiagnosticContext,
        fileID: String?,
        container: DiagnosticContainerKind
    ) {
        self.identity = identity
        self.file = file
        self.diagnosticRecorder = diagnosticRecorder
        self.diagnosticContext = diagnosticContext
        self.fileID = fileID
        self.container = container
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        do {
            return try await file.read(at: offset, length: length)
        } catch {
            if error is CancellationError { throw error }
            throw mapSMBError(error, path: identity.path)
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        let payload = DiagnosticPayload(
            sourceID: identity.sourceID,
            fileID: fileID,
            container: container,
            fileSize: identity.size
        )
        let operation = DiagnosticOperation(
            recorder: diagnosticRecorder,
            parentContext: diagnosticContext,
            name: .fileClose,
            level: .info,
            payload: payload,
            persistence: .essential
        )
        await file.close()
        operation.end(outcome: .success, payload: payload)
    }
}

private func makeDefaultDiagnosticContext() -> DiagnosticContext {
    DiagnosticContext(appRunID: UUID(), activityID: UUID(), operationID: UUID())
}

private func diagnosticDescriptor(for error: MediaSourceError) -> DiagnosticErrorDescriptor {
    switch error {
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

private func mapSMBError(_ error: Error, path: String? = nil) -> MediaSourceError {
    guard let error = error as? SMBClientError else {
        if error is SMBConfigurationError {
            return .unsupported(reason: "Invalid SMB path")
        }
        return .unreachable(details: nil)
    }

    switch error {
    case .notConnected:
        return .notConnected
    case .authenticationFailed:
        return .authenticationFailed
    case .unreachable:
        return .unreachable(details: nil)
    case .notFound:
        return .notFound(path: path ?? "/")
    case let .invalidRead(offset, length):
        return .invalidRead(offset: offset, length: length)
    case .readFailed:
        return .readFailed(details: nil)
    case .remoteFileChanged:
        return .remoteFileChanged
    case .unsupported:
        return .unsupported(reason: "Unsupported SMB operation")
    }
}
