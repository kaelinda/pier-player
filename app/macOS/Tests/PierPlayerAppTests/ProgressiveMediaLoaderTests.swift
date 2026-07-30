import DiagnosticsKit
import Foundation
import MediaSourceKit
import Testing
@testable import PierPlayerApp

@Suite struct ProgressiveMediaLoaderTests {
    @Test func largeRangeIsSplitIntoBoundedReads() async throws {
        let bytes = Data((0..<24).map(UInt8.init))
        let file = RecordingReadableFile(bytes: bytes)
        let loader = try ProgressiveMediaLoader(file: file, maximumReadLength: 4)
        let sink = DataSink()

        try await loader.load(offset: 3, length: 13) { chunk in
            await sink.append(chunk)
        }

        #expect(await sink.data == bytes.subdata(in: 3..<16))
        #expect(await file.readRequests == [
            ReadRequest(offset: 3, length: 4),
            ReadRequest(offset: 7, length: 4),
            ReadRequest(offset: 11, length: 4),
            ReadRequest(offset: 15, length: 1),
        ])
    }

    @Test func finiteRangeIsClampedAtEndOfFile() async throws {
        let bytes = Data((0..<10).map(UInt8.init))
        let file = RecordingReadableFile(bytes: bytes)
        let loader = try ProgressiveMediaLoader(file: file, maximumReadLength: 4)
        let sink = DataSink()

        try await loader.load(offset: 7, length: 20) { chunk in
            await sink.append(chunk)
        }

        #expect(await sink.data == bytes.subdata(in: 7..<10))
        #expect(await file.readRequests == [ReadRequest(offset: 7, length: 3)])
    }

    @Test func nilLengthReadsToKnownEndOfFile() async throws {
        let bytes = Data((0..<10).map(UInt8.init))
        let file = RecordingReadableFile(bytes: bytes)
        let loader = try ProgressiveMediaLoader(file: file, maximumReadLength: 4)
        let sink = DataSink()

        try await loader.load(offset: 2, length: nil) { chunk in
            await sink.append(chunk)
        }

        #expect(await sink.data == bytes.subdata(in: 2..<10))
        #expect(await file.readRequests == [
            ReadRequest(offset: 2, length: 4),
            ReadRequest(offset: 6, length: 4),
        ])
    }

    @Test(arguments: [
        InvalidRange(offset: -1, length: 1),
        InvalidRange(offset: 0, length: 0),
        InvalidRange(offset: 0, length: -1),
        InvalidRange(offset: Int64.max - 1, length: 4),
    ])
    func invalidRangeDoesNotReachUpstream(range: InvalidRange) async throws {
        let file = RecordingReadableFile(bytes: Data(repeating: 0, count: 8))
        let loader = try ProgressiveMediaLoader(file: file, maximumReadLength: 4)

        await #expect(throws: ProgressiveMediaLoaderError.self) {
            try await loader.load(offset: range.offset, length: range.length) { _ in }
        }
        #expect(await file.readRequests.isEmpty)
    }

    @Test func unexpectedEmptyReadFailsWithoutSpinning() async throws {
        let file = RecordingReadableFile(
            bytes: Data(repeating: 1, count: 12),
            emptyReadOffsets: [4]
        )
        let loader = try ProgressiveMediaLoader(file: file, maximumReadLength: 4)
        let sink = DataSink()

        await #expect(
            throws: ProgressiveMediaLoaderError.unexpectedEndOfFile(offset: 4)
        ) {
            try await loader.load(offset: 0, length: 12) { chunk in
                await sink.append(chunk)
            }
        }

        #expect(await sink.data == Data(repeating: 1, count: 4))
        #expect(await file.readRequests.count == 2)
    }

    @Test func cancellingSuspendedReadDoesNotEmitData() async throws {
        let file = SuspendedReadableFile(size: 16)
        let loader = try ProgressiveMediaLoader(file: file, maximumReadLength: 4)
        let sink = DataSink()
        let loadingTask = Task {
            try await loader.load(offset: 0, length: 16) { chunk in
                await sink.append(chunk)
            }
        }

        await file.waitUntilReadStarts()
        loadingTask.cancel()

        await #expect(throws: CancellationError.self) {
            try await loadingTask.value
        }
        #expect(await sink.data.isEmpty)
        #expect(await file.readCount == 1)
    }

    @Test func closeIsIdempotentAndRejectsNewLoads() async throws {
        let file = RecordingReadableFile(bytes: Data(repeating: 1, count: 8))
        let loader = try ProgressiveMediaLoader(file: file, maximumReadLength: 4)

        await loader.close()
        await loader.close()

        #expect(await file.closeCount == 1)
        await #expect(throws: ProgressiveMediaLoaderError.closed) {
            try await loader.load(offset: 0, length: 4) { _ in }
        }
        #expect(await file.readRequests.isEmpty)
    }

    @Test func diagnosticsCorrelateRequestChunksCancellationAndClose() async throws {
        let bytes = Data((0..<12).map(UInt8.init))
        let file = RecordingReadableFile(bytes: bytes)
        let recorder = AppRecordingDiagnosticRecorder()
        let identityProvider = HMACDiagnosticIdentityProvider(keyData: Data(repeating: 3, count: 32))
        let loader = try ProgressiveMediaLoader(
            file: file,
            maximumReadLength: 4,
            diagnosticRecorder: recorder,
            diagnosticContext: appDiagnosticContext,
            identityProvider: identityProvider
        )

        try await loader.load(offset: 0, length: 8) { _ in }
        await loader.close()
        await loader.close()

        let events = recorder.snapshot
        let request = try #require(events.first {
            $0.name == .resourceRequest && $0.phase == .begin
        })
        let reads = events.filter { $0.name == .resourceRead }
        #expect(reads.filter { $0.phase == .begin }.count == 2)
        #expect(reads.filter { $0.phase == .begin }.allSatisfy {
            $0.context.parentOperationID == request.context.operationID
        })
        #expect(reads.filter { $0.phase == .end }.map(\.payload.actualLength) == [4, 4])
        let closes = events.filter { $0.name == .fileClose }
        #expect(closes.map(\.phase) == [.begin, .end])

        let expectedFileID = identityProvider.fileIdentity(
            sourceID: file.identity.sourceID,
            normalizedPath: file.identity.path,
            size: file.identity.size,
            modifiedAt: file.identity.modifiedAt
        ).value
        #expect(events.allSatisfy { $0.context.activityID == appDiagnosticContext.activityID })
        #expect(events.contains { $0.payload.fileID == expectedFileID })
        let encoded = try events.map(DiagnosticEventEncoder.encode)
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
            .lowercased()
        #expect(!encoded.contains("fixture.mp4"))
    }

    @Test func diagnosticReadMapsUnexpectedEOFAndCancellation() async throws {
        let eofRecorder = AppRecordingDiagnosticRecorder()
        let eofLoader = try ProgressiveMediaLoader(
            file: RecordingReadableFile(
                bytes: Data(repeating: 1, count: 8),
                emptyReadOffsets: [0]
            ),
            maximumReadLength: 4,
            diagnosticRecorder: eofRecorder,
            diagnosticContext: appDiagnosticContext
        )
        await #expect(throws: ProgressiveMediaLoaderError.unexpectedEndOfFile(offset: 0)) {
            try await eofLoader.load(offset: 0, length: 4) { _ in }
        }
        let eofEnd = try #require(eofRecorder.snapshot.last { $0.name == .resourceRead })
        #expect(eofEnd.outcome == .failure)
        #expect(eofEnd.payload.error?.code == .streamUnexpectedShortRead)

        let cancellationRecorder = AppRecordingDiagnosticRecorder()
        let suspended = SuspendedReadableFile(size: 8)
        let cancellationLoader = try ProgressiveMediaLoader(
            file: suspended,
            maximumReadLength: 4,
            diagnosticRecorder: cancellationRecorder,
            diagnosticContext: appDiagnosticContext
        )
        let task = Task {
            try await cancellationLoader.load(offset: 0, length: 4) { _ in }
        }
        await suspended.waitUntilReadStarts()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let cancelled = try #require(
            cancellationRecorder.snapshot.last { $0.name == .resourceRead }
        )
        #expect(cancelled.outcome == .cancelled)
        #expect(cancelled.payload.error == nil)
    }
}

private struct ReadRequest: Equatable, Sendable {
    let offset: Int64
    let length: Int
}

struct InvalidRange: Sendable, CustomTestStringConvertible {
    let offset: Int64
    let length: Int64?

    var testDescription: String {
        "offset=\(offset), length=\(length.map(String.init) ?? "nil")"
    }
}

private actor DataSink {
    private(set) var data = Data()

    func append(_ chunk: Data) {
        data.append(chunk)
    }
}

private actor RecordingReadableFile: MediaReadableFile {
    nonisolated let identity: MediaFileIdentity

    private let bytes: Data
    private let emptyReadOffsets: Set<Int64>
    private(set) var readRequests: [ReadRequest] = []
    private(set) var closeCount = 0

    init(bytes: Data, emptyReadOffsets: Set<Int64> = []) {
        self.bytes = bytes
        self.emptyReadOffsets = emptyReadOffsets
        self.identity = MediaFileIdentity(
            sourceID: UUID(),
            path: "/fixture.mp4",
            size: Int64(bytes.count),
            modifiedAt: nil
        )
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        readRequests.append(ReadRequest(offset: offset, length: length))
        if emptyReadOffsets.contains(offset) {
            return Data()
        }
        guard offset < Int64(bytes.count) else { return Data() }
        let start = Int(offset)
        let end = min(start + length, bytes.count)
        return bytes.subdata(in: start..<end)
    }

    func close() async {
        closeCount += 1
    }
}

private actor SuspendedReadableFile: MediaReadableFile {
    nonisolated let identity: MediaFileIdentity

    private(set) var readCount = 0
    private var didStartRead = false
    private var readStartWaiters: [CheckedContinuation<Void, Never>] = []

    init(size: Int64) {
        self.identity = MediaFileIdentity(
            sourceID: UUID(),
            path: "/suspended.mp4",
            size: size,
            modifiedAt: nil
        )
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        readCount += 1
        didStartRead = true
        let waiters = readStartWaiters
        readStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        try await Task.sleep(for: .seconds(60))
        return Data(repeating: 1, count: length)
    }

    func close() async {}

    func waitUntilReadStarts() async {
        if didStartRead { return }
        await withCheckedContinuation { continuation in
            readStartWaiters.append(continuation)
        }
    }
}
