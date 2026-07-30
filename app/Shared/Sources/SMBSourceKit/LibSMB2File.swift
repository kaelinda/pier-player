import DiagnosticsKit
import Foundation
import SMB2

public actor LibSMB2File: SMBClientFile {
    private let size: Int64
    private let handle: any SMBNativeFileHandle
    private let connection: any SMBNativeConnection
    private let diagnosticRecorder: any DiagnosticRecording
    private let diagnosticContext: DiagnosticContext
    private let sourceID: UUID?
    private let fileID: String?
    private var isClosed = false

    init(
        size: Int64,
        handle: any SMBNativeFileHandle,
        connection: any SMBNativeConnection,
        diagnosticRecorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        diagnosticContext: DiagnosticContext? = nil,
        sourceID: UUID? = nil,
        fileID: String? = nil
    ) {
        self.size = size
        self.handle = handle
        self.connection = connection
        self.diagnosticRecorder = diagnosticRecorder
        self.diagnosticContext = diagnosticContext ?? makeLibSMB2FileDiagnosticContext()
        self.sourceID = sourceID
        self.fileID = fileID
    }

    public func read(at offset: Int64, length: Int) async throws -> Data {
        let initialPayload = DiagnosticPayload(
            sourceID: sourceID,
            fileID: fileID,
            offset: offset,
            requestedLength: length
        )
        let operation = DiagnosticOperation(
            recorder: diagnosticRecorder,
            parentContext: diagnosticContext,
            name: .smbRead,
            payload: initialPayload,
            persistence: .detailed
        )
        guard offset >= 0, length > 0, UInt64(length) <= UInt64(UInt32.max) else {
            let error = SMBClientError.invalidRead(offset: offset, length: length)
            operation.end(
                outcome: .failure,
                payload: initialPayload,
                error: libSMB2FileDiagnosticDescriptor(for: error)
            )
            throw error
        }
        guard !isClosed else {
            operation.end(
                outcome: .failure,
                payload: initialPayload,
                error: libSMB2FileDiagnosticDescriptor(for: SMBClientError.notConnected)
            )
            throw SMBClientError.notConnected
        }
        guard offset < size else {
            operation.end(
                outcome: .success,
                payload: DiagnosticPayload(
                    sourceID: sourceID,
                    fileID: fileID,
                    offset: offset,
                    requestedLength: length,
                    actualLength: 0
                )
            )
            return Data()
        }

        let available = size - offset
        let readLength = min(length, Int(available))
        do {
            let data = try await handle.read(at: offset, length: readLength)
            operation.end(
                outcome: .success,
                payload: DiagnosticPayload(
                    sourceID: sourceID,
                    fileID: fileID,
                    offset: offset,
                    requestedLength: length,
                    actualLength: data.count
                )
            )
            return data
        } catch {
            if error is CancellationError {
                operation.end(outcome: .cancelled, payload: initialPayload)
            } else {
                operation.end(
                    outcome: .failure,
                    payload: initialPayload,
                    error: libSMB2FileDiagnosticDescriptor(for: error)
                )
            }
            throw error
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        let payload = DiagnosticPayload(
            sourceID: sourceID,
            fileID: fileID,
            fileSize: size
        )
        let operation = DiagnosticOperation(
            recorder: diagnosticRecorder,
            parentContext: diagnosticContext,
            name: .smbClose,
            level: .info,
            payload: payload,
            persistence: .essential
        )
        await handle.close()
        await connection.disconnect()
        operation.end(outcome: .success, payload: payload)
    }
}

private func makeLibSMB2FileDiagnosticContext() -> DiagnosticContext {
    DiagnosticContext(appRunID: UUID(), activityID: UUID(), operationID: UUID())
}

private func libSMB2FileDiagnosticDescriptor(for error: Error) -> DiagnosticErrorDescriptor {
    guard let error = error as? SMBClientError else {
        return DiagnosticErrorDescriptor(code: .sourceReadFailed, isRetryable: true)
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

final class SystemLibSMB2FileHandle: SMBNativeFileHandle, @unchecked Sendable {
    private let connection: SystemLibSMB2Connection
    private let state: State

    init(connection: SystemLibSMB2Connection, handle: OpaquePointer) {
        self.connection = connection
        state = State(handle: handle)
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        try await connection.perform { context in
            guard let handle = self.state.handle else {
                throw SMBClientError.notConnected
            }

            var data = Data(repeating: 0, count: length)
            let count = data.withUnsafeMutableBytes { buffer -> Int32 in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return smb2_pread(
                    context,
                    handle,
                    baseAddress.assumingMemoryBound(to: UInt8.self),
                    UInt32(length),
                    UInt64(offset)
                )
            }
            guard count >= 0 else {
                throw mapLibSMB2Status(count, operation: .read)
            }
            data.count = Int(count)
            return data
        }
    }

    func close() async {
        try? await connection.perform { context in
            guard let handle = self.state.takeHandle() else { return }
            _ = smb2_close(context, handle)
        }
    }

    private final class State: @unchecked Sendable {
        var handle: OpaquePointer?

        init(handle: OpaquePointer) {
            self.handle = handle
        }

        func takeHandle() -> OpaquePointer? {
            defer { handle = nil }
            return handle
        }
    }
}
