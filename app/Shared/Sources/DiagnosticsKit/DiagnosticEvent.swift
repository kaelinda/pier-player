import Foundation

public enum DiagnosticLevel: String, Codable, Equatable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
    case critical
}

public enum DiagnosticCategory: String, Codable, Equatable, Sendable {
    case app
    case resource
    case stream
    case playback
    case system
    case diagnostics
    case telemetry
}

public enum DiagnosticEventName: String, Codable, Equatable, Sendable {
    case appLaunch = "app.launch"
    case appTermination = "app.termination"
    case appSleep = "app.sleep"
    case appWake = "app.wake"
    case sourceRestore = "source.restore"
    case sourceAdd = "source.add"
    case sourceRemove = "source.remove"
    case sourceConnect = "source.connect"
    case sourceDisconnect = "source.disconnect"
    case directoryList = "directory.list"
    case fileOpen = "file.open"
    case fileClose = "file.close"
    case smbConnect = "smb.connect"
    case smbList = "smb.list"
    case smbStat = "smb.stat"
    case smbOpen = "smb.open"
    case smbRead = "smb.read"
    case smbClose = "smb.close"
    case resourceRead = "stream.resource_read"
    case resourceRequest = "stream.resource_request"
    case cacheSnapshot = "stream.cache_snapshot"
    case playbackPrepare = "playback.prepare"
    case playbackReady = "playback.ready"
    case playbackPlay = "playback.play"
    case playbackPause = "playback.pause"
    case playbackSeek = "playback.seek"
    case playbackStall = "playback.stall"
    case playbackRecover = "playback.recover"
    case playbackEnded = "playback.ended"
    case playbackFailed = "playback.failed"
    case playbackStop = "playback.stop"
    case networkChanged = "system.network_changed"
    case environmentSnapshot = "system.environment_snapshot"
    case diagnosticModeChanged = "diagnostics.mode_changed"
    case eventsDropped = "diagnostics.events_dropped"
    case storageLimitReached = "diagnostics.storage_limit_reached"
    case historyCleared = "diagnostics.history_cleared"
    case metricSnapshot = "telemetry.metric_snapshot"

    public var category: DiagnosticCategory {
        switch self {
        case .appLaunch, .appTermination, .appSleep, .appWake:
            .app
        case .sourceRestore, .sourceAdd, .sourceRemove, .sourceConnect,
             .sourceDisconnect, .directoryList, .fileOpen, .fileClose,
             .smbConnect, .smbList, .smbStat, .smbOpen, .smbRead, .smbClose:
            .resource
        case .resourceRead, .resourceRequest, .cacheSnapshot:
            .stream
        case .playbackPrepare, .playbackReady, .playbackPlay, .playbackPause,
             .playbackSeek, .playbackStall, .playbackRecover, .playbackEnded,
             .playbackFailed, .playbackStop:
            .playback
        case .networkChanged, .environmentSnapshot:
            .system
        case .diagnosticModeChanged, .eventsDropped, .storageLimitReached,
             .historyCleared:
            .diagnostics
        case .metricSnapshot:
            .telemetry
        }
    }
}

public enum DiagnosticPhase: String, Codable, Equatable, Sendable {
    case begin
    case end
    case instant
}

public enum DiagnosticOutcome: String, Codable, Equatable, Sendable {
    case success
    case failure
    case cancelled
    case discarded
}

public enum DiagnosticPersistence: String, Codable, Equatable, Sendable {
    case essential
    case detailed
}

public enum DiagnosticContainerKind: String, Codable, Equatable, Sendable {
    case mp4
    case m4v
    case mov
    case mkv
    case other

    public init(fileName: String) {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        self = DiagnosticContainerKind(rawValue: fileExtension) ?? .other
    }
}

public enum DiagnosticPlaybackState: String, Codable, Equatable, Sendable {
    case idle
    case connecting
    case opening
    case bufferingInitial = "buffering_initial"
    case bufferingSeek = "buffering_seek"
    case bufferingRecovery = "buffering_recovery"
    case preparing
    case ready
    case playing
    case paused
    case waiting
    case reconnecting
    case ended
    case failed
}

public enum DiagnosticErrorCode: String, Codable, Equatable, Sendable {
    case sourceNotConnected = "source_not_connected"
    case sourceAuthenticationFailed = "source_authentication_failed"
    case sourceUnreachable = "source_unreachable"
    case sourceNotFound = "source_not_found"
    case sourceInvalidRead = "source_invalid_read"
    case sourceReadFailed = "source_read_failed"
    case sourceRemoteFileChanged = "source_remote_file_changed"
    case sourceUnsupported = "source_unsupported"
    case streamUnexpectedShortRead = "stream_unexpected_short_read"
    case streamCacheAssemblyFailed = "stream_cache_assembly_failed"
    case playerUnsupportedContainer = "player_unsupported_container"
    case playerInvalidLoadingRequest = "player_invalid_loading_request"
    case playerResourceLoaderClosed = "player_resource_loader_closed"
    case playerFailed = "player_failed"
    case diagnosticsStorageFailed = "diagnostics_storage_failed"
    case diagnosticsPrivacyRejected = "diagnostics_privacy_rejected"
    case diagnosticsIntegrityFailed = "diagnostics_integrity_failed"
}

public enum DiagnosticIncidentKind: String, Codable, Equatable, Hashable, Sendable {
    case playbackFailure = "playback_failure"
    case sourceFailure = "source_failure"
    case unexpectedEndOfFile = "unexpected_end_of_file"
    case stall
    case eventLoss = "event_loss"
    case unclosedResource = "unclosed_resource"
}

public struct DiagnosticErrorDescriptor: Codable, Equatable, Sendable {
    public let code: DiagnosticErrorCode
    public let isRetryable: Bool
    public let isCancellation: Bool
    public let nativeCode: Int64?

    public init(
        code: DiagnosticErrorCode,
        isRetryable: Bool = false,
        isCancellation: Bool = false,
        nativeCode: Int64? = nil
    ) {
        self.code = code
        self.isRetryable = isRetryable
        self.isCancellation = isCancellation
        self.nativeCode = nativeCode
    }
}

public struct DiagnosticPayload: Codable, Equatable, Sendable {
    public let sourceID: UUID?
    public let fileID: String?
    public let container: DiagnosticContainerKind?
    public let fileSize: Int64?
    public let offset: Int64?
    public let requestedLength: Int?
    public let actualLength: Int?
    public let droppedEssentialEvents: UInt64?
    public let droppedDetailedEvents: UInt64?
    public let cacheHits: UInt64?
    public let cacheMisses: UInt64?
    public let upstreamReads: UInt64?
    public let upstreamBytes: UInt64?
    public let playbackSessionID: UUID?
    public let playbackGeneration: UInt64?
    public let oldPlaybackState: DiagnosticPlaybackState?
    public let newPlaybackState: DiagnosticPlaybackState?
    public let playbackPositionSeconds: Double?
    public let memoryPressure: DiagnosticMemoryPressure?
    public let thermalState: DiagnosticThermalState?
    public let powerState: DiagnosticPowerState?
    public let networkAvailability: DiagnosticNetworkAvailability?
    public let networkInterface: DiagnosticNetworkInterface?
    public let incidentKind: DiagnosticIncidentKind?
    public let error: DiagnosticErrorDescriptor?

    public init(
        sourceID: UUID? = nil,
        fileID: String? = nil,
        container: DiagnosticContainerKind? = nil,
        fileSize: Int64? = nil,
        offset: Int64? = nil,
        requestedLength: Int? = nil,
        actualLength: Int? = nil,
        droppedEssentialEvents: UInt64? = nil,
        droppedDetailedEvents: UInt64? = nil,
        cacheHits: UInt64? = nil,
        cacheMisses: UInt64? = nil,
        upstreamReads: UInt64? = nil,
        upstreamBytes: UInt64? = nil,
        playbackSessionID: UUID? = nil,
        playbackGeneration: UInt64? = nil,
        oldPlaybackState: DiagnosticPlaybackState? = nil,
        newPlaybackState: DiagnosticPlaybackState? = nil,
        playbackPositionSeconds: Double? = nil,
        memoryPressure: DiagnosticMemoryPressure? = nil,
        thermalState: DiagnosticThermalState? = nil,
        powerState: DiagnosticPowerState? = nil,
        networkAvailability: DiagnosticNetworkAvailability? = nil,
        networkInterface: DiagnosticNetworkInterface? = nil,
        incidentKind: DiagnosticIncidentKind? = nil,
        error: DiagnosticErrorDescriptor? = nil
    ) {
        self.sourceID = sourceID
        self.fileID = fileID
        self.container = container
        self.fileSize = fileSize
        self.offset = offset
        self.requestedLength = requestedLength
        self.actualLength = actualLength
        self.droppedEssentialEvents = droppedEssentialEvents
        self.droppedDetailedEvents = droppedDetailedEvents
        self.cacheHits = cacheHits
        self.cacheMisses = cacheMisses
        self.upstreamReads = upstreamReads
        self.upstreamBytes = upstreamBytes
        self.playbackSessionID = playbackSessionID
        self.playbackGeneration = playbackGeneration
        self.oldPlaybackState = oldPlaybackState
        self.newPlaybackState = newPlaybackState
        self.playbackPositionSeconds = playbackPositionSeconds
        self.memoryPressure = memoryPressure
        self.thermalState = thermalState
        self.powerState = powerState
        self.networkAvailability = networkAvailability
        self.networkInterface = networkInterface
        self.incidentKind = incidentKind
        self.error = error
    }
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sequence: UInt64
    public let wallTime: Date
    public let monotonicNanoseconds: UInt64
    public let level: DiagnosticLevel
    public let category: DiagnosticCategory
    public let name: DiagnosticEventName
    public let context: DiagnosticContext
    public let phase: DiagnosticPhase
    public let outcome: DiagnosticOutcome?
    public let durationMilliseconds: Double?
    public let payload: DiagnosticPayload
    public let persistence: DiagnosticPersistence

    public init(
        sequence: UInt64,
        wallTime: Date,
        monotonicNanoseconds: UInt64,
        level: DiagnosticLevel,
        name: DiagnosticEventName,
        context: DiagnosticContext,
        phase: DiagnosticPhase,
        outcome: DiagnosticOutcome? = nil,
        durationMilliseconds: Double? = nil,
        payload: DiagnosticPayload = DiagnosticPayload(),
        persistence: DiagnosticPersistence
    ) {
        self.schemaVersion = 1
        self.sequence = sequence
        self.wallTime = wallTime
        self.monotonicNanoseconds = monotonicNanoseconds
        self.level = level
        self.category = name.category
        self.name = name
        self.context = context
        self.phase = phase
        self.outcome = outcome
        self.durationMilliseconds = durationMilliseconds
        self.payload = payload
        self.persistence = persistence
    }

    func withSequence(_ sequence: UInt64) -> DiagnosticEvent {
        DiagnosticEvent(
            sequence: sequence,
            wallTime: wallTime,
            monotonicNanoseconds: monotonicNanoseconds,
            level: level,
            name: name,
            context: context,
            phase: phase,
            outcome: outcome,
            durationMilliseconds: durationMilliseconds,
            payload: payload,
            persistence: persistence
        )
    }

    public var incidentKind: DiagnosticIncidentKind? {
        switch name {
        case .playbackFailed:
            .playbackFailure
        case .playbackStall:
            .stall
        case .eventsDropped:
            .eventLoss
        case .fileClose where outcome == .failure:
            .unclosedResource
        case .smbConnect, .smbRead:
            switch payload.error?.code {
            case .sourceUnreachable, .sourceReadFailed:
                .sourceFailure
            case .streamUnexpectedShortRead:
                .unexpectedEndOfFile
            default:
                nil
            }
        case .resourceRead where payload.error?.code == .streamUnexpectedShortRead:
            .unexpectedEndOfFile
        default:
            nil
        }
    }
}

public enum DiagnosticEventEncoder {
    public static func encode(_ event: DiagnosticEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(event)
    }
}

public struct DiagnosticMetricRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let timestamp: Date
    public let context: DiagnosticContext
    public let networkBytesPerSecond: Double
    public let readLatencyMilliseconds: Double
    public let cacheHitRatio: Double
    public let bufferedDurationSeconds: Double
    public let compressedQueueDepth: Int
    public let videoQueueDepth: Int
    public let decodeLatencyMilliseconds: Double
    public let presentedFrames: UInt64
    public let droppedFrames: UInt64
    public let stallCount: UInt64
    public let residentBytes: UInt64

    public init(
        timestamp: Date,
        context: DiagnosticContext,
        networkBytesPerSecond: Double,
        readLatencyMilliseconds: Double,
        cacheHitRatio: Double,
        bufferedDurationSeconds: Double,
        compressedQueueDepth: Int,
        videoQueueDepth: Int,
        decodeLatencyMilliseconds: Double,
        presentedFrames: UInt64,
        droppedFrames: UInt64,
        stallCount: UInt64,
        residentBytes: UInt64
    ) {
        self.schemaVersion = 1
        self.timestamp = timestamp
        self.context = context
        self.networkBytesPerSecond = networkBytesPerSecond
        self.readLatencyMilliseconds = readLatencyMilliseconds
        self.cacheHitRatio = cacheHitRatio
        self.bufferedDurationSeconds = bufferedDurationSeconds
        self.compressedQueueDepth = compressedQueueDepth
        self.videoQueueDepth = videoQueueDepth
        self.decodeLatencyMilliseconds = decodeLatencyMilliseconds
        self.presentedFrames = presentedFrames
        self.droppedFrames = droppedFrames
        self.stallCount = stallCount
        self.residentBytes = residentBytes
    }
}

public enum DiagnosticMetricRecordEncoder {
    public static func encode(_ record: DiagnosticMetricRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(record)
    }
}
