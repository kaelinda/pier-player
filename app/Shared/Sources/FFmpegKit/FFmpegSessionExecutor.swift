import Foundation

public final class FFmpegSessionExecutor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let session: FFmpegSession

    private init(queue: DispatchQueue, session: FFmpegSession) {
        self.queue = queue
        self.session = session
    }

    public static func open(
        source: any FFmpegByteSource,
        limits: FFmpegProbeLimits = .default
    ) async throws -> FFmpegSessionExecutor {
        let queue = DispatchQueue(
            label: "dev.pierplayer.ffmpeg.session.\(UUID().uuidString)",
            qos: .userInitiated
        )
        let session = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(
                        returning: try FFmpegSession(source: source, limits: limits)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return FFmpegSessionExecutor(queue: queue, session: session)
    }

    public func metadata() async throws -> MediaMetadata {
        try await perform { try $0.metadata() }
    }

    public func prepareForDecoding(
        configuration: FFmpegDecodeConfiguration = .default
    ) async throws {
        try await perform { try $0.prepareForDecoding(configuration: configuration) }
    }

    public func videoDecoderStatus() async throws -> VideoDecoderStatus {
        try await perform { try $0.videoDecoderStatus() }
    }

    public func readNextSample() async throws -> DecodedSample? {
        try await perform { try $0.readNextSample() }
    }

    @discardableResult
    public func seek(to presentationTime: TimeInterval) async throws -> UInt64 {
        try await perform { try $0.seek(to: presentationTime) }
    }

    @discardableResult
    public func selectAudioTrack(
        index: Int,
        at presentationTime: TimeInterval
    ) async throws -> UInt64 {
        try await perform {
            try $0.selectAudioTrack(index: index, at: presentationTime)
        }
    }

    public func selectSubtitleTrack(index: Int?) async throws {
        try await perform { try $0.selectSubtitleTrack(index: index) }
    }

    public func cancel() {
        session.cancel()
    }

    public func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [session] in
                session.close()
                continuation.resume()
            }
        }
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable (FFmpegSession) throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [session] in
                do {
                    continuation.resume(returning: try operation(session))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
