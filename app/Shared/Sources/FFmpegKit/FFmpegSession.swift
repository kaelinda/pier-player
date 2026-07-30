import Foundation
import PierFFmpeg

public final class FFmpegSession: @unchecked Sendable {
    private let bridge: FFmpegIOBridge
    private let lock = NSLock()
    private var nativeSession: OpaquePointer?

    public convenience init(
        data: Data,
        limits: FFmpegProbeLimits = .default
    ) throws {
        try self.init(source: FFmpegIOBridge.dataSource(data), limits: limits)
    }

    public init(
        source: any FFmpegByteSource,
        limits: FFmpegProbeLimits = .default
    ) throws {
        guard limits.maximumBytes > 0,
              limits.maximumDuration.isFinite,
              limits.maximumDuration > 0 else {
            throw FFmpegError.invalidProbeLimits
        }

        let bridge = FFmpegIOBridge(source: source, limits: limits)
        var nativeError = PPFFError()
        let nativeLimits = PPFFProbeLimits(
            maximum_probe_bytes: limits.maximumBytes,
            maximum_analyze_duration_us: Int64(limits.maximumDuration * 1_000_000)
        )
        guard let session = ppff_session_open(
            bridge.callbacks,
            nativeLimits,
            &nativeError
        ) else {
            bridge.cancel()
            throw Self.error(from: &nativeError)
        }

        self.bridge = bridge
        self.nativeSession = session
    }

    deinit {
        close()
    }

    public func metadata() throws -> MediaMetadata {
        try lock.withLock {
            guard let nativeSession else { throw FFmpegError.sessionClosed }

            var nativeError = PPFFError()
            var mediaInfo = PPFFMediaInfo()
            let mediaResult = ppff_session_media_info(
                nativeSession,
                &mediaInfo,
                &nativeError
            )
            guard mediaResult >= 0 else {
                throw Self.error(from: &nativeError)
            }

            let streamCount = ppff_session_stream_count(nativeSession)
            var tracks: [MediaTrack] = []
            tracks.reserveCapacity(Int(streamCount))
            for index in 0..<streamCount {
                var streamInfo = PPFFStreamInfo()
                let streamResult = ppff_session_stream_info(
                    nativeSession,
                    index,
                    &streamInfo,
                    &nativeError
                )
                guard streamResult >= 0 else {
                    throw Self.error(from: &nativeError)
                }
                tracks.append(Self.track(from: &streamInfo))
            }

            return MediaMetadata(
                containerName: Self.string(from: &mediaInfo.container_name),
                duration: TimeInterval(mediaInfo.duration_us) / 1_000_000,
                isSeekable: mediaInfo.is_seekable != 0,
                tracks: tracks
            )
        }
    }

    public func close() {
        lock.withLock {
            guard nativeSession != nil else { return }
            bridge.cancel()
            ppff_session_close(&nativeSession)
        }
    }

    private static func track(from info: inout PPFFStreamInfo) -> MediaTrack {
        MediaTrack(
            index: Int(info.index),
            kind: kind(from: Int(info.kind.rawValue)),
            codecID: Int(info.codec_id),
            codecName: string(from: &info.codec_name),
            language: optionalString(from: &info.language),
            title: optionalString(from: &info.title),
            width: Int(info.width),
            height: Int(info.height),
            sampleRate: Int(info.sample_rate),
            channelCount: Int(info.channel_count),
            isDefault: info.is_default != 0
        )
    }

    private static func kind(from rawValue: Int) -> MediaTrackKind {
        switch rawValue {
        case 1: .video
        case 2: .audio
        case 3: .subtitle
        default: .unknown
        }
    }

    private static func error(from error: inout PPFFError) -> FFmpegError {
        FFmpegError.native(
            code: Int(error.code),
            message: string(from: &error.message)
        )
    }

    private static func optionalString<T>(from value: inout T) -> String? {
        let string = string(from: &value)
        return string.isEmpty ? nil : string
    }

    private static func string<T>(from value: inout T) -> String {
        withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: MemoryLayout<T>.size
            ) { characters in
                String(cString: characters)
            }
        }
    }
}
