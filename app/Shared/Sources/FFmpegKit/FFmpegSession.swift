import Foundation
import PierFFmpeg

public final class FFmpegSession: @unchecked Sendable {
    private let bridge: FFmpegIOBridge
    private let lock = NSLock()
    private var nativeSession: OpaquePointer?
    private var decodersPrepared = false
    private var isCancelled = false
    private var generation: UInt64 = 0

    public var currentGeneration: UInt64 {
        lock.withLock { generation }
    }

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
        if bridge.interrupted() != 0 {
            var expiredSession: OpaquePointer? = session
            ppff_session_close(&expiredSession)
            bridge.cancel()
            throw FFmpegError.native(
                code: Int(PPFF_ERROR_IO),
                message: "probe time limit exceeded"
            )
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

    public func prepareForDecoding(
        configuration: FFmpegDecodeConfiguration = .default
    ) throws {
        try lock.withLock {
            guard let nativeSession else { throw FFmpegError.sessionClosed }
            guard !isCancelled else { throw FFmpegError.cancelled }

            var nativeError = PPFFError()
            let nativeConfiguration = PPFFDecodeConfiguration(
                prefer_hardware: configuration.preferHardware ? 1 : 0,
                force_hardware_open_failure: configuration.forceHardwareOpenFailure ? 1 : 0
            )
            let result = ppff_session_prepare_decoders(
                nativeSession,
                nativeConfiguration,
                &nativeError
            )
            guard result >= 0 else {
                throw Self.error(from: &nativeError)
            }
            decodersPrepared = true
        }
    }

    public func videoDecoderStatus() throws -> VideoDecoderStatus {
        try lock.withLock {
            guard let nativeSession else { throw FFmpegError.sessionClosed }
            guard decodersPrepared else { throw FFmpegError.decodersNotPrepared }

            var nativeError = PPFFError()
            var nativeStatus = PPFFDecoderStatus()
            let result = ppff_session_video_decoder_status(
                nativeSession,
                &nativeStatus,
                &nativeError
            )
            guard result >= 0 else {
                throw Self.error(from: &nativeError)
            }
            return VideoDecoderStatus(
                mode: Self.decoderMode(from: Int(nativeStatus.mode.rawValue)),
                hardwareAttempted: nativeStatus.hardware_attempted != 0,
                softwareFallbackCount: Int(nativeStatus.software_fallback_count)
            )
        }
    }

    public func readNextSample() throws -> DecodedSample? {
        try lock.withLock { () throws -> DecodedSample? in
            guard let nativeSession else { throw FFmpegError.sessionClosed }
            guard decodersPrepared else { throw FFmpegError.decodersNotPrepared }
            guard !isCancelled else { throw FFmpegError.cancelled }

            var nativeError = PPFFError()
            var nativeSample = PPFFSample()
            let result = ppff_session_read_next(
                nativeSession,
                &nativeSample,
                &nativeError
            )
            guard result >= 0 else {
                throw Self.error(from: &nativeError)
            }
            guard result > 0 else { return nil }
            defer { ppff_sample_release(&nativeSample) }

            let presentationTime = TimeInterval(nativeSample.presentation_time_us) / 1_000_000
            let duration = TimeInterval(nativeSample.duration_us) / 1_000_000
            switch Int(nativeSample.kind.rawValue) {
            case 1:
                guard let pixelBuffer = nativeSample.video_buffer else {
                    throw FFmpegError.native(code: -1, message: "missing decoded video buffer")
                }
                let retainedPixelBuffer = pixelBuffer
                    .retain()
                    .takeRetainedValue()
                return .video(
                    DecodedVideoSample(
                        pixelBuffer: retainedPixelBuffer,
                        presentationTime: presentationTime,
                        duration: duration,
                        streamIndex: Int(nativeSample.stream_index),
                        generation: generation
                    )
                )
            case 2:
                guard let audioData = nativeSample.audio_data,
                      nativeSample.audio_byte_count > 0 else {
                    throw FFmpegError.native(code: -1, message: "missing decoded audio data")
                }
                return .audio(
                    DecodedAudioSample(
                        data: Data(
                            bytes: audioData,
                            count: Int(nativeSample.audio_byte_count)
                        ),
                        presentationTime: presentationTime,
                        duration: duration,
                        sampleCount: Int(nativeSample.audio_sample_count),
                        sampleRate: Int(nativeSample.audio_sample_rate),
                        channelCount: Int(nativeSample.audio_channel_count),
                        streamIndex: Int(nativeSample.stream_index),
                        generation: generation
                    )
                )
            case 3:
                guard let subtitleText = nativeSample.subtitle_text,
                      nativeSample.subtitle_text_length > 0 else {
                    throw FFmpegError.native(code: -1, message: "missing decoded subtitle text")
                }
                let text = String(
                    decoding: UnsafeBufferPointer(
                        start: UnsafeRawPointer(subtitleText)
                            .assumingMemoryBound(to: UInt8.self),
                        count: Int(nativeSample.subtitle_text_length)
                    ),
                    as: UTF8.self
                )
                return .subtitle(
                    DecodedSubtitleSample(
                        text: Self.normalizedSubtitleText(text),
                        presentationTime: presentationTime,
                        duration: duration,
                        streamIndex: Int(nativeSample.stream_index),
                        generation: generation
                    )
                )
            default:
                throw FFmpegError.native(code: -1, message: "unknown decoded sample kind")
            }
        }
    }

    @discardableResult
    public func seek(to presentationTime: TimeInterval) throws -> UInt64 {
        try lock.withLock {
            guard let nativeSession else { throw FFmpegError.sessionClosed }
            guard decodersPrepared else { throw FFmpegError.decodersNotPrepared }
            guard !isCancelled else { throw FFmpegError.cancelled }
            guard presentationTime.isFinite, presentationTime >= 0,
                  presentationTime <= TimeInterval(Int64.max) / 1_000_000 else {
                throw FFmpegError.native(code: -22, message: "invalid seek time")
            }

            var nativeError = PPFFError()
            let result = ppff_session_seek(
                nativeSession,
                Int64(presentationTime * 1_000_000),
                &nativeError
            )
            guard result >= 0 else { throw Self.error(from: &nativeError) }
            generation &+= 1
            return generation
        }
    }

    @discardableResult
    public func selectAudioTrack(
        index: Int,
        at presentationTime: TimeInterval
    ) throws -> UInt64 {
        try lock.withLock {
            guard let nativeSession else { throw FFmpegError.sessionClosed }
            guard decodersPrepared else { throw FFmpegError.decodersNotPrepared }
            guard !isCancelled else { throw FFmpegError.cancelled }
            guard presentationTime.isFinite, presentationTime >= 0,
                  presentationTime <= TimeInterval(Int64.max) / 1_000_000,
                  index >= 0, index <= Int(Int32.max) else {
                throw FFmpegError.native(code: -22, message: "invalid audio selection")
            }

            var nativeError = PPFFError()
            let result = ppff_session_select_audio(
                nativeSession,
                Int32(index),
                Int64(presentationTime * 1_000_000),
                &nativeError
            )
            guard result >= 0 else { throw Self.error(from: &nativeError) }
            generation &+= 1
            return generation
        }
    }

    public func selectSubtitleTrack(index: Int?) throws {
        try lock.withLock {
            guard let nativeSession else { throw FFmpegError.sessionClosed }
            guard decodersPrepared else { throw FFmpegError.decodersNotPrepared }
            let rawIndex = index ?? -1
            guard rawIndex >= -1, rawIndex <= Int(Int32.max) else {
                throw FFmpegError.native(code: -22, message: "invalid subtitle selection")
            }
            var nativeError = PPFFError()
            let result = ppff_session_select_subtitle(
                nativeSession,
                Int32(rawIndex),
                &nativeError
            )
            guard result >= 0 else { throw Self.error(from: &nativeError) }
        }
    }

    public func cancel() {
        lock.withLock {
            guard nativeSession != nil else { return }
            isCancelled = true
            bridge.cancel()
        }
    }

    public func close() {
        lock.withLock {
            guard nativeSession != nil else { return }
            isCancelled = true
            bridge.cancel()
            ppff_session_close(&nativeSession)
            decodersPrepared = false
        }
    }

    private static func decoderMode(from rawValue: Int) -> VideoDecoderMode {
        switch rawValue {
        case 1: .videoToolbox
        case 2: .software
        default: .none
        }
    }

    private static func normalizedSubtitleText(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
        guard let expression = try? NSRegularExpression(
            pattern: "\\{[^}]*\\}|<[^>]+>"
        ) else {
            return normalized
        }
        return expression.stringByReplacingMatches(
            in: normalized,
            range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
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
