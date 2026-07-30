import AVFoundation
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
    private var isStopped = false

    init(file: any MediaReadableFile, fileName: String) throws {
        guard let mediaType = AVFoundationMediaType(fileName: fileName) else {
            throw ProgressivePlaybackError.unsupportedContainer(
                (fileName as NSString).pathExtension.lowercased()
            )
        }

        let mediaLoader = try ProgressiveMediaLoader(file: file)
        let resourceLoader = ProgressiveMediaResourceLoader(
            mediaLoader: mediaLoader,
            contentType: mediaType.contentType
        )
        let asset = AVURLAsset(url: mediaType.makeAssetURL())
        asset.resourceLoader.setDelegate(resourceLoader, queue: resourceLoader.delegateQueue)

        self.resourceLoader = resourceLoader
        self.asset = asset
        self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }

    func play() {
        player.play()
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        player.pause()
        asset.cancelLoading()
        await resourceLoader.close()
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
    private enum State {
        case active
        case cancelled
        case finished
    }

    private let request: AVAssetResourceLoadingRequest
    private let lock = NSLock()
    private var state = State.active

    init(_ request: AVAssetResourceLoadingRequest) {
        self.request = request
    }

    func respond(with data: Data) {
        lock.lock()
        let shouldRespond = state == .active
        lock.unlock()
        guard shouldRespond else { return }
        request.dataRequest?.respond(with: data)
    }

    func finish() {
        lock.lock()
        guard state == .active else {
            lock.unlock()
            return
        }
        state = .finished
        lock.unlock()
        request.finishLoading()
    }

    func finish(with error: Error) {
        lock.lock()
        guard state == .active else {
            lock.unlock()
            return
        }
        state = .finished
        lock.unlock()
        request.finishLoading(with: error)
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active else { return }
        state = .cancelled
    }
}
