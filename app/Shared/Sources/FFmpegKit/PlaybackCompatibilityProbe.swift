import CoreVideo
import Foundation
import MediaSourceKit
import StreamIOKit

public struct PlaybackProbeOptions: Equatable, Sendable {
    public let seekTime: TimeInterval?
    public let videoFrameLimit: Int?

    public init(seekTime: TimeInterval? = nil, videoFrameLimit: Int? = nil) {
        self.seekTime = seekTime
        self.videoFrameLimit = videoFrameLimit
    }
}

public struct PlaybackProbeTrack: Codable, Equatable, Sendable {
    public let index: Int
    public let kind: MediaTrackKind
    public let codecName: String
    public let language: String?
    public let title: String?
    public let isDefault: Bool
}

public struct PlaybackProbeQueuePeaks: Codable, Equatable, Sendable {
    public let videoItems: Int
    public let videoBytes: Int
    public let videoDuration: TimeInterval
    public let audioItems: Int
    public let audioBytes: Int
    public let audioDuration: TimeInterval

    public static let empty = PlaybackProbeQueuePeaks(
        videoItems: 0,
        videoBytes: 0,
        videoDuration: 0,
        audioItems: 0,
        audioBytes: 0,
        audioDuration: 0
    )
}

public struct PlaybackProbeResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let inputID: String
    public let ffmpegVersion: String
    public let containerName: String
    public let duration: TimeInterval
    public let isSeekable: Bool
    public let tracks: [PlaybackProbeTrack]
    public let selectedVideoCodec: String?
    public let selectedAudioCodec: String?
    public let decoderMode: VideoDecoderMode
    public let hardwareAttempted: Bool
    public let softwareFallbackCount: Int
    public let firstVideoTime: TimeInterval?
    public let firstAudioTime: TimeInterval?
    public let videoSampleCount: Int
    public let audioSampleCount: Int
    public let videoTimestampsMonotonic: Bool
    public let audioTimestampsMonotonic: Bool
    public let seekRequestedTime: TimeInterval?
    public let seekCompleted: Bool
    public let seekLatencyMilliseconds: Double?
    public let reachedEOF: Bool
    public let queuePeaks: PlaybackProbeQueuePeaks
    public let errors: [String]
}

public enum PlaybackProbeError: Error, Equatable, Sendable {
    case invalidSeekTime
    case invalidFrameLimit
}

public enum PlaybackCompatibilityProbe {
    private static let pageSize = 256 * 1_024
    private static let cacheCapacityBytes = 32 * 1_024 * 1_024

    public static func run(
        file: any MediaReadableFile,
        inputID: String,
        options: PlaybackProbeOptions = PlaybackProbeOptions()
    ) async throws -> PlaybackProbeResult {
        if let seekTime = options.seekTime,
           !seekTime.isFinite || seekTime < 0 {
            await file.close()
            throw PlaybackProbeError.invalidSeekTime
        }
        if let videoFrameLimit = options.videoFrameLimit,
           videoFrameLimit <= 0 {
            await file.close()
            throw PlaybackProbeError.invalidFrameLimit
        }

        let reader: CachedMediaReader
        do {
            reader = try CachedMediaReader(
                file: file,
                pageSize: pageSize,
                capacityBytes: cacheCapacityBytes
            )
        } catch {
            await file.close()
            throw error
        }
        let blockingReader = BlockingMediaReader(reader: reader, timeout: 10)

        let executor: FFmpegSessionExecutor
        do {
            executor = try await FFmpegSessionExecutor.open(source: blockingReader)
        } catch {
            await blockingReader.closeAndWait()
            throw error
        }

        do {
            let result = try await decode(
                executor: executor,
                inputID: inputID,
                options: options
            )
            await executor.close()
            await blockingReader.closeAndWait()
            return result
        } catch {
            executor.cancel()
            await executor.close()
            await blockingReader.closeAndWait()
            throw error
        }
    }

    private static func decode(
        executor: FFmpegSessionExecutor,
        inputID: String,
        options: PlaybackProbeOptions
    ) async throws -> PlaybackProbeResult {
        let metadata = try await executor.metadata()
        try await executor.prepareForDecoding()
        let decoderStatus = try await executor.videoDecoderStatus()

        var seekCompleted = false
        var seekLatencyMilliseconds: Double?
        if let seekTime = options.seekTime {
            let start = ContinuousClock.now
            _ = try await executor.seek(to: seekTime)
            seekLatencyMilliseconds = durationMilliseconds(start.duration(to: .now))
            seekCompleted = true
        }

        var videoSampleCount = 0
        var audioSampleCount = 0
        var firstVideoTime: TimeInterval?
        var firstAudioTime: TimeInterval?
        var previousVideoTime: TimeInterval?
        var previousAudioTime: TimeInterval?
        var videoTimestampsMonotonic = true
        var audioTimestampsMonotonic = true
        var reachedEOF = false
        var videoPeakBytes = 0
        var videoPeakDuration: TimeInterval = 0
        var audioPeakBytes = 0
        var audioPeakDuration: TimeInterval = 0

        decodeLoop: while true {
            guard let sample = try await executor.readNextSample() else {
                reachedEOF = true
                break
            }
            switch sample {
            case let .video(video):
                videoSampleCount += 1
                firstVideoTime = firstVideoTime ?? video.presentationTime
                if let previousVideoTime,
                   video.presentationTime < previousVideoTime {
                    videoTimestampsMonotonic = false
                }
                previousVideoTime = video.presentationTime
                videoPeakBytes = max(videoPeakBytes, CVPixelBufferGetDataSize(video.pixelBuffer))
                videoPeakDuration = max(videoPeakDuration, video.duration)
                if let limit = options.videoFrameLimit,
                   videoSampleCount >= limit {
                    break decodeLoop
                }
            case let .audio(audio):
                audioSampleCount += 1
                firstAudioTime = firstAudioTime ?? audio.presentationTime
                if let previousAudioTime,
                   audio.presentationTime < previousAudioTime {
                    audioTimestampsMonotonic = false
                }
                previousAudioTime = audio.presentationTime
                audioPeakBytes = max(audioPeakBytes, audio.data.count)
                audioPeakDuration = max(audioPeakDuration, audio.duration)
            case .subtitle:
                break
            }
        }

        let videoTrack = selectedTrack(kind: .video, from: metadata.tracks)
        let audioTrack = selectedTrack(kind: .audio, from: metadata.tracks)
        return PlaybackProbeResult(
            schemaVersion: 1,
            inputID: inputID,
            ffmpegVersion: try FFmpegRuntime.version(),
            containerName: metadata.containerName,
            duration: metadata.duration,
            isSeekable: metadata.isSeekable,
            tracks: metadata.tracks.map {
                PlaybackProbeTrack(
                    index: $0.index,
                    kind: $0.kind,
                    codecName: $0.codecName,
                    language: $0.language,
                    title: $0.title,
                    isDefault: $0.isDefault
                )
            },
            selectedVideoCodec: videoTrack?.codecName,
            selectedAudioCodec: audioTrack?.codecName,
            decoderMode: decoderStatus.mode,
            hardwareAttempted: decoderStatus.hardwareAttempted,
            softwareFallbackCount: decoderStatus.softwareFallbackCount,
            firstVideoTime: firstVideoTime,
            firstAudioTime: firstAudioTime,
            videoSampleCount: videoSampleCount,
            audioSampleCount: audioSampleCount,
            videoTimestampsMonotonic: videoTimestampsMonotonic,
            audioTimestampsMonotonic: audioTimestampsMonotonic,
            seekRequestedTime: options.seekTime,
            seekCompleted: seekCompleted,
            seekLatencyMilliseconds: seekLatencyMilliseconds,
            reachedEOF: reachedEOF,
            queuePeaks: PlaybackProbeQueuePeaks(
                videoItems: videoSampleCount > 0 ? 1 : 0,
                videoBytes: videoPeakBytes,
                videoDuration: videoPeakDuration,
                audioItems: audioSampleCount > 0 ? 1 : 0,
                audioBytes: audioPeakBytes,
                audioDuration: audioPeakDuration
            ),
            errors: []
        )
    }

    private static func selectedTrack(
        kind: MediaTrackKind,
        from tracks: [MediaTrack]
    ) -> MediaTrack? {
        tracks.first { $0.kind == kind && $0.isDefault }
            ?? tracks.first { $0.kind == kind }
    }

    private static func durationMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        let seconds = Double(components.seconds)
        let fractional = Double(components.attoseconds) / 1_000_000_000_000_000_000
        return (seconds + fractional) * 1_000
    }
}
