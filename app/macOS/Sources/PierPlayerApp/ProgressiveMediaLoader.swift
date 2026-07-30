import DiagnosticsKit
import Foundation
import MediaSourceKit

enum ProgressiveMediaLoaderError: Error, Equatable, Sendable {
    case invalidMaximumReadLength(Int)
    case invalidRange(offset: Int64, length: Int64?)
    case unexpectedEndOfFile(offset: Int64)
    case closed
}

actor ProgressiveMediaLoader {
    nonisolated let identity: MediaFileIdentity

    private let file: any MediaReadableFile
    private let maximumReadLength: Int
    private let diagnosticRecorder: any DiagnosticRecording
    private let diagnosticContext: DiagnosticContext
    private let diagnosticFileID: String?
    private let diagnosticContainer: DiagnosticContainerKind
    private var isClosed = false

    init(
        file: any MediaReadableFile,
        maximumReadLength: Int = 512 * 1024,
        diagnosticRecorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        diagnosticContext: DiagnosticContext? = nil,
        identityProvider: (any DiagnosticIdentityProviding)? = nil
    ) throws {
        guard maximumReadLength > 0 else {
            throw ProgressiveMediaLoaderError.invalidMaximumReadLength(maximumReadLength)
        }

        self.file = file
        self.identity = file.identity
        self.maximumReadLength = maximumReadLength
        self.diagnosticRecorder = diagnosticRecorder
        self.diagnosticContext = diagnosticContext ?? DiagnosticContext(
            appRunID: UUID(),
            activityID: UUID(),
            operationID: UUID()
        )
        self.diagnosticFileID = identityProvider?.fileIdentity(
            sourceID: file.identity.sourceID,
            normalizedPath: file.identity.path,
            size: file.identity.size,
            modifiedAt: file.identity.modifiedAt
        ).value
        self.diagnosticContainer = DiagnosticContainerKind(fileName: file.identity.path)
    }

    func load(
        offset: Int64,
        length: Int64?,
        consume: @Sendable (Data) async throws -> Void
    ) async throws {
        let initialPayload = diagnosticPayload(
            offset: offset,
            requestedLength: diagnosticLength(length),
            actualLength: nil
        )
        let request = DiagnosticOperation(
            recorder: diagnosticRecorder,
            parentContext: diagnosticContext,
            name: .resourceRequest,
            payload: initialPayload,
            persistence: .detailed
        )
        do {
            guard !isClosed else {
                throw ProgressiveMediaLoaderError.closed
            }
            guard offset >= 0 else {
                throw ProgressiveMediaLoaderError.invalidRange(offset: offset, length: length)
            }
            if let length, length <= 0 {
                throw ProgressiveMediaLoaderError.invalidRange(offset: offset, length: length)
            }

            let requestedEnd = try endOffset(start: offset, length: length)
            guard offset < identity.size else {
                request.end(
                    outcome: .success,
                    payload: diagnosticPayload(
                        offset: offset,
                        requestedLength: diagnosticLength(length),
                        actualLength: 0
                    )
                )
                return
            }

            let end = min(identity.size, requestedEnd)
            var cursor = offset
            var totalBytes = 0

            while cursor < end {
                try Task.checkCancellation()
                guard !isClosed else {
                    throw ProgressiveMediaLoaderError.closed
                }

                let readLength = Int(min(Int64(maximumReadLength), end - cursor))
                let readPayload = diagnosticPayload(
                    offset: cursor,
                    requestedLength: readLength,
                    actualLength: nil
                )
                let read = DiagnosticOperation(
                    recorder: diagnosticRecorder,
                    parentContext: request.context,
                    name: .resourceRead,
                    payload: readPayload,
                    persistence: .detailed
                )
                let acceptedData: Data
                do {
                    let data = try await file.read(at: cursor, length: readLength)

                    try Task.checkCancellation()
                    guard !isClosed else {
                        throw ProgressiveMediaLoaderError.closed
                    }
                    guard !data.isEmpty else {
                        throw ProgressiveMediaLoaderError.unexpectedEndOfFile(offset: cursor)
                    }

                    acceptedData = Data(data.prefix(readLength))
                    try await consume(acceptedData)
                    read.end(
                        outcome: .success,
                        payload: diagnosticPayload(
                            offset: cursor,
                            requestedLength: readLength,
                            actualLength: acceptedData.count
                        )
                    )
                } catch {
                    finishDiagnosticOperation(read, error: error, payload: readPayload)
                    throw error
                }
                cursor += Int64(acceptedData.count)
                totalBytes += acceptedData.count
            }
            request.end(
                outcome: .success,
                payload: diagnosticPayload(
                    offset: offset,
                    requestedLength: diagnosticLength(length),
                    actualLength: totalBytes
                )
            )
        } catch {
            finishDiagnosticOperation(request, error: error, payload: initialPayload)
            throw error
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        let payload = diagnosticPayload(offset: nil, requestedLength: nil, actualLength: nil)
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

    private func endOffset(start: Int64, length: Int64?) throws -> Int64 {
        guard let length else { return identity.size }
        let (end, overflowed) = start.addingReportingOverflow(length)
        guard !overflowed else {
            throw ProgressiveMediaLoaderError.invalidRange(offset: start, length: length)
        }
        return end
    }

    private func diagnosticPayload(
        offset: Int64?,
        requestedLength: Int?,
        actualLength: Int?
    ) -> DiagnosticPayload {
        DiagnosticPayload(
            sourceID: identity.sourceID,
            fileID: diagnosticFileID,
            container: diagnosticContainer,
            fileSize: identity.size,
            offset: offset,
            requestedLength: requestedLength,
            actualLength: actualLength
        )
    }

    private func diagnosticLength(_ length: Int64?) -> Int? {
        guard let length, length >= 0, length <= Int64(Int.max) else { return nil }
        return Int(length)
    }
}

private func finishDiagnosticOperation(
    _ operation: DiagnosticOperation,
    error: Error,
    payload: DiagnosticPayload
) {
    if error is CancellationError {
        operation.end(outcome: .cancelled, payload: payload)
    } else {
        operation.end(
            outcome: .failure,
            payload: payload,
            error: progressiveLoaderDiagnosticDescriptor(for: error)
        )
    }
}

private func progressiveLoaderDiagnosticDescriptor(for error: Error) -> DiagnosticErrorDescriptor {
    switch error {
    case ProgressiveMediaLoaderError.invalidMaximumReadLength,
         ProgressiveMediaLoaderError.invalidRange:
        DiagnosticErrorDescriptor(code: .playerInvalidLoadingRequest)
    case ProgressiveMediaLoaderError.unexpectedEndOfFile:
        DiagnosticErrorDescriptor(code: .streamUnexpectedShortRead)
    case ProgressiveMediaLoaderError.closed:
        DiagnosticErrorDescriptor(code: .playerResourceLoaderClosed)
    case MediaSourceError.notConnected:
        DiagnosticErrorDescriptor(code: .sourceNotConnected, isRetryable: true)
    case MediaSourceError.authenticationFailed:
        DiagnosticErrorDescriptor(code: .sourceAuthenticationFailed)
    case MediaSourceError.unreachable:
        DiagnosticErrorDescriptor(code: .sourceUnreachable, isRetryable: true)
    case MediaSourceError.notFound:
        DiagnosticErrorDescriptor(code: .sourceNotFound)
    case MediaSourceError.invalidRead:
        DiagnosticErrorDescriptor(code: .sourceInvalidRead)
    case MediaSourceError.readFailed:
        DiagnosticErrorDescriptor(code: .sourceReadFailed, isRetryable: true)
    case MediaSourceError.remoteFileChanged:
        DiagnosticErrorDescriptor(code: .sourceRemoteFileChanged)
    case MediaSourceError.unsupported:
        DiagnosticErrorDescriptor(code: .sourceUnsupported)
    default:
        DiagnosticErrorDescriptor(code: .playerFailed)
    }
}
