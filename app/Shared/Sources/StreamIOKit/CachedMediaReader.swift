import DiagnosticsKit
import Foundation
import MediaSourceKit

public actor CachedMediaReader {
    private struct InFlightPage {
        let id: UUID
        let task: Task<Data, Error>
    }

    public nonisolated let identity: MediaFileIdentity
    public private(set) var metrics = StreamMetrics()

    private let file: any MediaReadableFile
    private let cache: PageCache
    private let pageSize: Int
    private let diagnosticRecorder: any DiagnosticRecording
    private let diagnosticContext: DiagnosticContext
    private let diagnosticFileID: String?
    private var inFlightPages: [Int64: InFlightPage] = [:]
    private var readGeneration: UInt64 = 0

    public init(
        file: any MediaReadableFile,
        pageSize: Int,
        capacityBytes: Int,
        diagnosticRecorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        diagnosticContext: DiagnosticContext? = nil,
        identityProvider: (any DiagnosticIdentityProviding)? = nil
    ) throws {
        self.file = file
        self.identity = file.identity
        self.pageSize = pageSize
        self.cache = try PageCache(pageSize: pageSize, capacityBytes: capacityBytes)
        self.diagnosticRecorder = diagnosticRecorder
        self.diagnosticContext = diagnosticContext ?? makeStreamDiagnosticContext()
        self.diagnosticFileID = identityProvider?.fileIdentity(
            sourceID: file.identity.sourceID,
            normalizedPath: file.identity.path,
            size: file.identity.size,
            modifiedAt: file.identity.modifiedAt
        ).value
    }

    public func read(at offset: Int64, length: Int) async throws -> Data {
        let initialPayload = DiagnosticPayload(
            sourceID: identity.sourceID,
            fileID: diagnosticFileID,
            offset: offset,
            requestedLength: length
        )
        let request = DiagnosticOperation(
            recorder: diagnosticRecorder,
            parentContext: diagnosticContext,
            name: .resourceRequest,
            payload: initialPayload,
            persistence: .detailed
        )
        do {
            guard offset >= 0, length > 0 else {
                throw MediaSourceError.invalidRead(offset: offset, length: length)
            }
            guard offset < identity.size else {
                request.end(
                    outcome: .success,
                    payload: DiagnosticPayload(
                        sourceID: identity.sourceID,
                        fileID: diagnosticFileID,
                        offset: offset,
                        requestedLength: length,
                        actualLength: 0
                    )
                )
                recordCacheSnapshot()
                return Data()
            }

            let available = identity.size - offset
            let actualLength = Int(min(Int64(length), available))

            if let cached = try await cache.data(at: offset, length: actualLength) {
                metrics.cacheHits &+= 1
                request.end(
                    outcome: .success,
                    payload: DiagnosticPayload(
                        sourceID: identity.sourceID,
                        fileID: diagnosticFileID,
                        offset: offset,
                        requestedLength: length,
                        actualLength: cached.count
                    )
                )
                recordCacheSnapshot()
                return cached
            }
            metrics.cacheMisses &+= 1

            let pageSize64 = Int64(pageSize)
            var pageOffset = (offset / pageSize64) * pageSize64
            let endOffset = offset + Int64(actualLength)
            while pageOffset < endOffset {
                try await loadPage(at: pageOffset, parentContext: request.context)
                pageOffset += pageSize64
            }

            guard let assembled = try await cache.data(at: offset, length: actualLength) else {
                throw StreamIOError.cacheAssemblyFailed(offset: offset, length: actualLength)
            }
            request.end(
                outcome: .success,
                payload: DiagnosticPayload(
                    sourceID: identity.sourceID,
                    fileID: diagnosticFileID,
                    offset: offset,
                    requestedLength: length,
                    actualLength: assembled.count
                )
            )
            recordCacheSnapshot()
            return assembled
        } catch {
            if error is CancellationError {
                request.end(outcome: .cancelled, payload: initialPayload)
            } else {
                request.end(
                    outcome: .failure,
                    payload: initialPayload,
                    error: streamDiagnosticDescriptor(for: error)
                )
            }
            recordCacheSnapshot()
            throw error
        }
    }

    public func removeAllCachedData() async {
        await cache.removeAll()
    }

    public func interruptPendingReads() {
        readGeneration &+= 1
        for page in inFlightPages.values {
            page.task.cancel()
        }
        inFlightPages.removeAll()
    }

    public func close() async {
        readGeneration &+= 1
        for page in inFlightPages.values {
            page.task.cancel()
        }
        inFlightPages.removeAll()
        await cache.removeAll()
        await file.close()
    }

    private func loadPage(
        at pageOffset: Int64,
        parentContext: DiagnosticContext
    ) async throws {
        let generation = readGeneration
        let remaining = identity.size - pageOffset
        let expectedLength = Int(min(Int64(pageSize), remaining))
        guard expectedLength > 0 else { return }

        if try await cache.data(at: pageOffset, length: expectedLength) != nil {
            return
        }

        let page: InFlightPage
        let ownsTask: Bool
        if let existing = inFlightPages[pageOffset] {
            page = existing
            ownsTask = false
        } else {
            let upstream = file
            let recorder = diagnosticRecorder
            let sourceID = identity.sourceID
            let fileID = diagnosticFileID
            let payload = DiagnosticPayload(
                sourceID: sourceID,
                fileID: fileID,
                offset: pageOffset,
                requestedLength: expectedLength
            )
            let operation = DiagnosticOperation(
                recorder: recorder,
                parentContext: parentContext,
                name: .resourceRead,
                payload: payload,
                persistence: .detailed
            )
            page = InFlightPage(
                id: UUID(),
                task: Task {
                    do {
                        let data = try await upstream.read(
                            at: pageOffset,
                            length: expectedLength
                        )
                        guard data.count == expectedLength else {
                            throw StreamIOError.unexpectedShortRead(
                                offset: pageOffset,
                                expected: expectedLength,
                                actual: data.count
                            )
                        }
                        operation.end(
                            outcome: .success,
                            payload: DiagnosticPayload(
                                sourceID: sourceID,
                                fileID: fileID,
                                offset: pageOffset,
                                requestedLength: expectedLength,
                                actualLength: data.count
                            )
                        )
                        return data
                    } catch {
                        if error is CancellationError {
                            operation.end(outcome: .cancelled, payload: payload)
                        } else {
                            operation.end(
                                outcome: .failure,
                                payload: payload,
                                error: streamDiagnosticDescriptor(for: error)
                            )
                        }
                        throw error
                    }
                }
            )
            inFlightPages[pageOffset] = page
            metrics.upstreamReads &+= 1
            ownsTask = true
        }

        do {
            let data = try await page.task.value
            guard generation == readGeneration else { throw CancellationError() }
            guard data.count == expectedLength else {
                throw StreamIOError.unexpectedShortRead(
                    offset: pageOffset,
                    expected: expectedLength,
                    actual: data.count
                )
            }
            try await cache.insert(page: data, at: pageOffset)
            if ownsTask {
                metrics.upstreamBytes &+= UInt64(data.count)
                removeInFlightPage(at: pageOffset, id: page.id)
            }
        } catch {
            if ownsTask {
                removeInFlightPage(at: pageOffset, id: page.id)
            }
            throw error
        }
    }

    private func recordCacheSnapshot() {
        diagnosticRecorder.record(.instant(
            level: .debug,
            name: .cacheSnapshot,
            context: diagnosticContext.child(),
            payload: DiagnosticPayload(
                sourceID: identity.sourceID,
                fileID: diagnosticFileID,
                cacheHits: metrics.cacheHits,
                cacheMisses: metrics.cacheMisses,
                upstreamReads: metrics.upstreamReads,
                upstreamBytes: metrics.upstreamBytes
            ),
            persistence: .detailed
        ))
    }

    private func removeInFlightPage(at pageOffset: Int64, id: UUID) {
        guard inFlightPages[pageOffset]?.id == id else { return }
        inFlightPages[pageOffset] = nil
    }
}

private func makeStreamDiagnosticContext() -> DiagnosticContext {
    DiagnosticContext(appRunID: UUID(), activityID: UUID(), operationID: UUID())
}

private func streamDiagnosticDescriptor(for error: Error) -> DiagnosticErrorDescriptor {
    switch error {
    case StreamIOError.unexpectedShortRead:
        DiagnosticErrorDescriptor(code: .streamUnexpectedShortRead)
    case StreamIOError.cacheAssemblyFailed:
        DiagnosticErrorDescriptor(code: .streamCacheAssemblyFailed)
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
        DiagnosticErrorDescriptor(code: .sourceReadFailed, isRetryable: true)
    }
}
