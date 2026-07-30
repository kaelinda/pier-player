import AVFoundation
import DiagnosticsKit
import Foundation
import MediaSourceKit

@MainActor
protocol VideoPlaybackSession: AnyObject {
    var player: AVPlayer { get }

    func play()
    func stop() async
}

typealias VideoPlaybackSessionFactory = @MainActor (
    any MediaReadableFile,
    String
) throws -> any VideoPlaybackSession

enum ProgressivePlaybackError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedContainer(String)
    case invalidLoadingRequest
    case resourceLoaderClosed

    var errorDescription: String? {
        switch self {
        case .unsupportedContainer:
            "This video container is not supported by the current playback engine."
        case .invalidLoadingRequest:
            "The player requested an invalid media range."
        case .resourceLoaderClosed:
            "The media resource is no longer available."
        }
    }
}

enum DiagnosticPlayerObservation: Sendable {
    case ready
    case playing
    case paused
    case waiting
    case ended
    case failed
}

@MainActor
final class PlaybackStateDiagnosticAdapter {
    private let diagnosticRecorder: any DiagnosticRecording
    private let diagnosticContext: DiagnosticContext
    private let monotonicNow: @Sendable () -> TimeInterval
    private var state: DiagnosticPlaybackState = .preparing
    private var waitingSince: TimeInterval?
    private var didRecordLongWait = false
    private var recentShortStalls: [TimeInterval] = []

    init(
        diagnosticRecorder: any DiagnosticRecording,
        diagnosticContext: DiagnosticContext,
        monotonicNow: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.diagnosticRecorder = diagnosticRecorder
        self.diagnosticContext = diagnosticContext
        self.monotonicNow = monotonicNow
    }

    func observe(_ observation: DiagnosticPlayerObservation) {
        switch observation {
        case .ready:
            record(name: .playbackReady, newState: .ready, outcome: .success)
        case .playing:
            recoverIfWaiting(at: monotonicNow())
            state = .playing
        case .paused:
            record(name: .playbackPause, newState: .paused, outcome: .success)
        case .waiting:
            if waitingSince == nil {
                waitingSince = monotonicNow()
                didRecordLongWait = false
                state = .waiting
            }
        case .ended:
            record(name: .playbackEnded, newState: .ended, outcome: .success)
        case .failed:
            record(
                name: .playbackFailed,
                newState: .failed,
                outcome: .failure,
                error: DiagnosticErrorDescriptor(code: .playerFailed)
            )
        }
    }

    func poll() {
        guard let waitingSince, !didRecordLongWait else { return }
        guard monotonicNow() - waitingSince >= 3 else { return }
        didRecordLongWait = true
        record(name: .playbackStall, newState: .waiting, outcome: .failure)
    }

    private func recoverIfWaiting(at timestamp: TimeInterval) {
        guard waitingSince != nil else { return }
        if !didRecordLongWait {
            recentShortStalls = recentShortStalls.filter { timestamp - $0 <= 60 }
            recentShortStalls.append(timestamp)
            if recentShortStalls.count >= 3 {
                record(name: .playbackStall, newState: .waiting, outcome: .failure)
                recentShortStalls.removeAll(keepingCapacity: true)
            }
        }
        record(name: .playbackRecover, newState: .playing, outcome: .success)
        waitingSince = nil
        didRecordLongWait = false
    }

    private func record(
        name: DiagnosticEventName,
        newState: DiagnosticPlaybackState,
        outcome: DiagnosticOutcome,
        error: DiagnosticErrorDescriptor? = nil
    ) {
        let oldState = state
        state = newState
        diagnosticRecorder.record(.instant(
            level: outcome == .failure ? .error : .info,
            name: name,
            context: diagnosticContext.child(),
            outcome: outcome,
            payload: DiagnosticPayload(
                oldPlaybackState: oldState,
                newPlaybackState: newState,
                error: error
            ),
            persistence: .essential
        ))
    }
}

enum AVFoundationMediaType: String, CaseIterable, Sendable {
    case mp4
    case m4v
    case mov

    init?(fileName: String) {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        self.init(rawValue: fileExtension)
    }

    var fileExtension: String { rawValue }

    var contentType: String {
        switch self {
        case .mp4:
            AVFileType.mp4.rawValue
        case .m4v:
            AVFileType.m4v.rawValue
        case .mov:
            AVFileType.mov.rawValue
        }
    }

    func makeAssetURL(identifier: UUID = UUID()) -> URL {
        let value = "pier-player-media://asset/\(identifier.uuidString).\(fileExtension)"
        guard let url = URL(string: value) else {
            preconditionFailure("Failed to create the private playback asset URL")
        }
        return url
    }
}

struct AVFoundationLoadingRange: Equatable, Sendable {
    let offset: Int64
    let length: Int64?

    init(offset: Int64, length: Int64?) {
        self.offset = offset
        self.length = length
    }

    init?(
        requestedOffset: Int64,
        currentOffset: Int64,
        requestedLength: Int,
        requestsAllDataToEndOfResource: Bool
    ) {
        guard requestedOffset >= 0, currentOffset >= 0 else { return nil }
        let offset = max(requestedOffset, currentOffset)

        if requestsAllDataToEndOfResource {
            self.init(offset: offset, length: nil)
            return
        }

        guard requestedLength > 0 else { return nil }
        let (requestedEnd, overflowed) = requestedOffset.addingReportingOverflow(
            Int64(requestedLength)
        )
        guard !overflowed, offset < requestedEnd else { return nil }
        self.init(offset: offset, length: requestedEnd - offset)
    }
}

final class ProgressiveMediaResourceLoader: NSObject,
    AVAssetResourceLoaderDelegate,
    @unchecked Sendable
{
    let delegateQueue = DispatchQueue(label: "app.pier-player.avfoundation-resource-loader")

    private let mediaLoader: ProgressiveMediaLoader
    private let contentType: String
    private var operations: [ObjectIdentifier: LoadingOperation] = [:]
    private var isClosed = false

    init(mediaLoader: ProgressiveMediaLoader, contentType: String) {
        self.mediaLoader = mediaLoader
        self.contentType = contentType
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !isClosed else {
            loadingRequest.finishLoading(with: ProgressivePlaybackError.resourceLoaderClosed)
            return true
        }

        populateContentInformation(for: loadingRequest)

        guard let dataRequest = loadingRequest.dataRequest else {
            guard loadingRequest.contentInformationRequest != nil else { return false }
            loadingRequest.finishLoading()
            return true
        }
        guard let range = AVFoundationLoadingRange(
            requestedOffset: dataRequest.requestedOffset,
            currentOffset: dataRequest.currentOffset,
            requestedLength: dataRequest.requestedLength,
            requestsAllDataToEndOfResource: dataRequest.requestsAllDataToEndOfResource
        ) else {
            loadingRequest.finishLoading(with: ProgressivePlaybackError.invalidLoadingRequest)
            return true
        }

        let identifier = ObjectIdentifier(loadingRequest)
        operations.removeValue(forKey: identifier)?.cancel()

        let request = LoadingRequest(loadingRequest)
        let operation = LoadingOperation(request: request)
        operations[identifier] = operation
        operation.start { [weak self, weak operation] in
            guard let self, let operation else { return }

            do {
                try await self.mediaLoader.load(
                    offset: range.offset,
                    length: range.length
                ) { data in
                    try Task.checkCancellation()
                    operation.respond(with: data)
                }
                operation.finish()
            } catch is CancellationError {
                operation.cancel()
            } catch {
                operation.finish(with: error)
            }

            self.scheduleRemoval(of: operation, identifier: identifier)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let identifier = ObjectIdentifier(loadingRequest)
        operations.removeValue(forKey: identifier)?.cancel()
    }

    func close() async {
        await withCheckedContinuation { continuation in
            delegateQueue.async { [self] in
                if !isClosed {
                    isClosed = true
                    let activeOperations = Array(operations.values)
                    operations.removeAll()
                    for operation in activeOperations {
                        operation.cancel()
                    }
                }
                continuation.resume()
            }
        }
        await mediaLoader.close()
    }

    private func populateContentInformation(for loadingRequest: AVAssetResourceLoadingRequest) {
        guard let information = loadingRequest.contentInformationRequest else { return }
        information.contentType = contentType
        information.contentLength = mediaLoader.identity.size
        information.isByteRangeAccessSupported = true
    }

    private func scheduleRemoval(
        of operation: LoadingOperation,
        identifier: ObjectIdentifier
    ) {
        delegateQueue.async { [weak self, weak operation] in
            guard let self, let operation else { return }
            guard self.operations[identifier] === operation else { return }
            self.operations.removeValue(forKey: identifier)
        }
    }
}

@MainActor
final class ProgressivePlaybackSession: VideoPlaybackSession {
    let player: AVPlayer
    let asset: AVURLAsset

    private let resourceLoader: ProgressiveMediaResourceLoader
    private let stateAdapter: PlaybackStateDiagnosticAdapter
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var stallMonitorTask: Task<Void, Never>?
    private var isStopped = false

    init(
        file: any MediaReadableFile,
        fileName: String,
        diagnosticRecorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        diagnosticContext: DiagnosticContext? = nil,
        identityProvider: (any DiagnosticIdentityProviding)? = nil
    ) throws {
        guard let mediaType = AVFoundationMediaType(fileName: fileName) else {
            throw ProgressivePlaybackError.unsupportedContainer(
                (fileName as NSString).pathExtension.lowercased()
            )
        }

        let context = diagnosticContext ?? DiagnosticContext(
            appRunID: UUID(),
            activityID: UUID(),
            operationID: UUID()
        )
        let mediaLoader = try ProgressiveMediaLoader(
            file: file,
            diagnosticRecorder: diagnosticRecorder,
            diagnosticContext: context,
            identityProvider: identityProvider
        )
        let resourceLoader = ProgressiveMediaResourceLoader(
            mediaLoader: mediaLoader,
            contentType: mediaType.contentType
        )
        let asset = AVURLAsset(url: mediaType.makeAssetURL())
        asset.resourceLoader.setDelegate(resourceLoader, queue: resourceLoader.delegateQueue)

        self.resourceLoader = resourceLoader
        self.asset = asset
        self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        self.stateAdapter = PlaybackStateDiagnosticAdapter(
            diagnosticRecorder: diagnosticRecorder,
            diagnosticContext: context
        )
        installObservers()
    }

    func play() {
        player.play()
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        stallMonitorTask?.cancel()
        stallMonitorTask = nil
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
        player.pause()
        asset.cancelLoading()
        await resourceLoader.close()
    }

    private func installObservers() {
        guard let item = player.currentItem else { return }
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) {
            [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .unknown:
                    break
                case .readyToPlay:
                    stateAdapter.observe(.ready)
                case .failed:
                    stateAdapter.observe(.failed)
                @unknown default:
                    stateAdapter.observe(.failed)
                }
            }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) {
            [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch player.timeControlStatus {
                case .paused:
                    stateAdapter.observe(.paused)
                case .waitingToPlayAtSpecifiedRate:
                    stateAdapter.observe(.waiting)
                case .playing:
                    stateAdapter.observe(.playing)
                @unknown default:
                    break
                }
            }
        }
        notificationTokens = [
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stateAdapter.observe(.ended)
                }
            },
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stateAdapter.observe(.failed)
                }
            },
        ]
        stallMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
                self?.stateAdapter.poll()
            }
        }
    }
}

enum LoadingRequestCompletion: Sendable {
    case finished
    case failed
    case cancelled
}

final class LoadingRequestCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: LoadingRequestCompletion?

    func claim(_ completion: LoadingRequestCompletion) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.completion == nil else { return false }
        self.completion = completion
        return true
    }

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completion != nil
    }
}

private final class LoadingOperation: @unchecked Sendable {
    private let request: LoadingRequest
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isCancelled = false

    init(request: LoadingRequest) {
        self.request = request
    }

    func start(_ body: @escaping @Sendable () async -> Void) {
        let task = Task {
            await body()
        }

        lock.lock()
        self.task = task
        let shouldCancel = isCancelled
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func respond(with data: Data) {
        request.respond(with: data)
    }

    func finish() {
        request.finish()
    }

    func finish(with error: Error) {
        request.finish(with: error)
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()

        request.cancel()
        task?.cancel()
    }
}

private final class LoadingRequest: @unchecked Sendable {
    private let request: AVAssetResourceLoadingRequest
    private let completionGate = LoadingRequestCompletionGate()

    init(_ request: AVAssetResourceLoadingRequest) {
        self.request = request
    }

    func respond(with data: Data) {
        guard !completionGate.isCompleted else { return }
        request.dataRequest?.respond(with: data)
    }

    func finish() {
        guard completionGate.claim(.finished) else { return }
        request.finishLoading()
    }

    func finish(with error: Error) {
        guard completionGate.claim(.failed) else { return }
        request.finishLoading(with: error)
    }

    func cancel() {
        _ = completionGate.claim(.cancelled)
    }
}
