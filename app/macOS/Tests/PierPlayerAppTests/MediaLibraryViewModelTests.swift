import Foundation
import MediaSourceKit
import Testing

@testable import PierPlayerApp

@MainActor
@Suite("MediaLibraryViewModelTests")
struct MediaLibraryViewModelTests {
    @Test func reloadCombinesSuccessfulSources() async {
        let first = source(named: "First NAS", videoPath: "/first.mp4")
        let second = source(named: "Second NAS", videoPath: "/second.mkv")
        let viewModel = MediaLibraryViewModel()

        await viewModel.reload(sources: [first, second])

        #expect(
            viewModel.snapshot.items.map(\.media.path).sorted()
                == ["/first.mp4", "/second.mkv"]
        )
        #expect(viewModel.snapshot.failures.isEmpty)
        #expect(!viewModel.isLoading)
    }

    @Test func reloadKeepsPartialItemsAndIsolatesSanitizedFailures() async throws {
        let failedSourceID = UUID()
        let partial = MediaLibrarySource(
            id: failedSourceID,
            displayName: "Private NAS"
        ) { path in
            if path == "/" {
                return [
                    videoItem(path: "/kept.mp4"),
                    directoryItem(path: "/restricted"),
                ]
            }
            throw SensitiveTestError(secret: "smb://user:password@private-host/share")
        }
        let successful = source(named: "Public NAS", videoPath: "/public.mov")
        let viewModel = MediaLibraryViewModel()

        await viewModel.reload(sources: [partial, successful])

        #expect(
            viewModel.snapshot.items.map(\.media.path).sorted()
                == ["/kept.mp4", "/public.mov"]
        )
        let failure = try #require(viewModel.snapshot.failures.first)
        #expect(viewModel.snapshot.failures.count == 1)
        #expect(failure.sourceID == failedSourceID)
        #expect(failure.sourceName == "Private NAS")
        #expect(!viewModel.isLoading)
    }

    @Test func reloadPublishesFastSourceWhileSlowSourceIsRunning() async throws {
        let slowGate = SuspensionGate()
        let completion = TaskCompletionProbe()
        let slow = MediaLibrarySource(id: UUID(), displayName: "Slow NAS") { path in
            #expect(path == "/")
            await slowGate.wait()
            return [videoItem(path: "/slow.mp4")]
        }
        let fast = source(named: "Fast NAS", videoPath: "/fast.mp4")
        let viewModel = MediaLibraryViewModel()

        let reload = Task {
            await viewModel.reload(sources: [slow, fast])
            await completion.markFinished()
        }

        let slowDidStart = await eventually { await slowGate.hasWaiter }
        if !slowDidStart {
            reload.cancel()
            await slowGate.resume()
            _ = await eventually { await completion.didFinish }
        }
        try #require(slowDidStart)

        let fastDidPublish = await eventually {
            viewModel.snapshot.items.map(\.media.path) == ["/fast.mp4"]
        }
        if !fastDidPublish {
            reload.cancel()
            await slowGate.resume()
            _ = await eventually { await completion.didFinish }
        }
        try #require(fastDidPublish)
        #expect(viewModel.isLoading)

        await slowGate.resume()
        let reloadDidFinish = await eventually { await completion.didFinish }
        if !reloadDidFinish {
            reload.cancel()
            await slowGate.resume()
        }
        try #require(reloadDidFinish)
        await reload.value

        #expect(
            viewModel.snapshot.items.map(\.media.path).sorted()
                == ["/fast.mp4", "/slow.mp4"]
        )
        #expect(!viewModel.isLoading)
    }

    @Test func reloadScansAtMostTwoSourcesConcurrently() async throws {
        let gate = ConcurrencyGate()
        let completion = TaskCompletionProbe()
        let sources = (0..<4).map { index in
            let id = UUID()
            return MediaLibrarySource(id: id, displayName: "NAS \(index)") { path in
                #expect(path == "/")
                await gate.enter(id: id)
                return [videoItem(path: "/video-\(index).mp4")]
            }
        }
        let viewModel = MediaLibraryViewModel()

        let reload = Task {
            await viewModel.reload(sources: sources)
            await completion.markFinished()
        }

        let firstWaveDidStart = await eventually { await gate.startedCount >= 2 }
        if !firstWaveDidStart {
            reload.cancel()
            await gate.resumeAll()
            _ = await eventually { await completion.didFinish }
        }
        try #require(firstWaveDidStart)

        #expect(await gate.maximumActiveCount == 2)
        let firstWave = await gate.startedIDs
        if firstWave.count != 2 {
            reload.cancel()
            await gate.resumeAll()
            _ = await eventually { await completion.didFinish }
        }
        try #require(firstWave.count == 2)
        let firstSourceID = try #require(firstWave.first)
        await gate.resume(id: firstSourceID)

        let thirdSourceDidStart = await eventually { await gate.startedCount >= 3 }
        if !thirdSourceDidStart {
            reload.cancel()
            await gate.resumeAll()
            _ = await eventually { await completion.didFinish }
        }
        try #require(thirdSourceDidStart)
        #expect(await gate.maximumActiveCount == 2)

        await gate.resumeAll()
        let reloadDidFinish = await eventually { await completion.didFinish }
        if !reloadDidFinish {
            reload.cancel()
            await gate.resumeAll()
        }
        try #require(reloadDidFinish)
        await reload.value

        #expect(viewModel.snapshot.items.count == 4)
        #expect(await gate.maximumActiveCount == 2)
        #expect(!viewModel.isLoading)
    }

    @Test func cancellingReloadStopsLoadingAndIgnoresLateResult() async throws {
        let probe = CancellationProbe()
        let completion = TaskCompletionProbe()
        let source = MediaLibrarySource(id: UUID(), displayName: "Slow NAS") { path in
            #expect(path == "/")
            return try await probe.list()
        }
        let initialItem = libraryItem(sourceName: "Preview", path: "/preview.mp4")
        let viewModel = MediaLibraryViewModel(
            initialSnapshot: MediaLibrarySnapshot(items: [initialItem])
        )

        let reload = Task {
            await viewModel.reload(sources: [source])
            await completion.markFinished()
        }

        let sourceDidStart = await eventually { await probe.hasStarted }
        if !sourceDidStart {
            reload.cancel()
            _ = await eventually { await completion.didFinish }
        }
        try #require(sourceDidStart)
        #expect(viewModel.snapshot == MediaLibrarySnapshot())
        #expect(viewModel.isLoading)

        reload.cancel()
        let reloadDidFinish = await eventually { await completion.didFinish }
        if !reloadDidFinish {
            reload.cancel()
        }
        try #require(reloadDidFinish)
        await reload.value

        #expect(await probe.didObserveCancellation)
        #expect(viewModel.snapshot == MediaLibrarySnapshot())
        #expect(!viewModel.isLoading)
    }

    @Test func newerReloadWinsOverOlderLateResult() async throws {
        let oldProbe = CancellationProbe()
        let oldCompletion = TaskCompletionProbe()
        let newCompletion = TaskCompletionProbe()
        let oldSource = MediaLibrarySource(id: UUID(), displayName: "Old NAS") { path in
            #expect(path == "/")
            return try await oldProbe.list()
        }
        let newGate = SuspensionGate()
        let newSource = MediaLibrarySource(id: UUID(), displayName: "New NAS") { path in
            #expect(path == "/")
            await newGate.wait()
            return [videoItem(path: "/new.mp4")]
        }
        let viewModel = MediaLibraryViewModel()

        let oldReload = Task {
            await viewModel.reload(sources: [oldSource])
            await oldCompletion.markFinished()
        }
        let oldDidStart = await eventually { await oldProbe.hasStarted }
        if !oldDidStart {
            oldReload.cancel()
            _ = await eventually { await oldCompletion.didFinish }
        }
        try #require(oldDidStart)

        let newReload = Task {
            await viewModel.reload(sources: [newSource])
            await newCompletion.markFinished()
        }
        let handoffDidStart = await eventually {
            let oldWasCancelled = await oldProbe.didObserveCancellation
            let newDidStart = await newGate.hasWaiter
            return oldWasCancelled && newDidStart
        }
        if !handoffDidStart {
            oldReload.cancel()
            newReload.cancel()
            await newGate.resume()
            _ = await eventually { await oldCompletion.didFinish }
            _ = await eventually { await newCompletion.didFinish }
        }
        try #require(handoffDidStart)

        let oldReloadDidFinish = await eventually { await oldCompletion.didFinish }
        if !oldReloadDidFinish {
            oldReload.cancel()
            newReload.cancel()
            await newGate.resume()
            _ = await eventually { await newCompletion.didFinish }
        }
        try #require(oldReloadDidFinish)
        await oldReload.value
        #expect(viewModel.snapshot == MediaLibrarySnapshot())
        #expect(viewModel.isLoading)

        await newGate.resume()
        let newReloadDidFinish = await eventually { await newCompletion.didFinish }
        if !newReloadDidFinish {
            newReload.cancel()
            await newGate.resume()
        }
        try #require(newReloadDidFinish)
        await newReload.value

        #expect(viewModel.snapshot.items.map(\.media.path) == ["/new.mp4"])
        #expect(!viewModel.isLoading)
    }

    @Test func newerReloadCancelsPriorScansBeforeStarting() async throws {
        let probe = ReloadReplacementProbe()
        let oldSources = (0..<2).map { index in
            let id = UUID()
            return MediaLibrarySource(id: id, displayName: "Old NAS \(index)") { path in
                #expect(path == "/")
                return try await probe.listOldSource(id: id)
            }
        }
        let newSource = MediaLibrarySource(id: UUID(), displayName: "New NAS") { path in
            #expect(path == "/")
            return await probe.listNewSource()
        }
        let viewModel = MediaLibraryViewModel()

        let oldReload = Task {
            await viewModel.reload(sources: oldSources)
            await probe.markOldReloadReturned()
        }
        let oldSourcesDidStart = await eventually {
            await probe.startedOldSourceCount == 2
        }
        if !oldSourcesDidStart {
            oldReload.cancel()
            _ = await eventually { await probe.didReturnOldReload }
        }
        try #require(oldSourcesDidStart)

        let newReload = Task {
            await viewModel.reload(sources: [newSource])
            await probe.markNewReloadReturned()
        }
        let replacementCompleted = await eventually {
            await probe.replacementCompleted
        }

        if !replacementCompleted {
            oldReload.cancel()
            newReload.cancel()
            _ = await eventually { await probe.didReturnOldReload }
            _ = await eventually { await probe.didReturnNewReload }
        }
        try #require(replacementCompleted)
        await oldReload.value
        await newReload.value

        #expect(await probe.cancelledOldSourceCount == 2)
        #expect(await probe.didStartNewSource)
        #expect(await probe.didReturnNewReload)
        #expect(await probe.maximumActiveCount <= 2)
        #expect(viewModel.snapshot.items.map(\.media.path) == ["/new.mp4"])
        #expect(!viewModel.isLoading)
    }

    @Test func replacementWaitsForNonCooperativePriorScans() async throws {
        let gate = NonCooperativeGate()
        let probe = NonCooperativeReplacementProbe()
        let oldCompletion = TaskCompletionProbe()
        let newCompletion = TaskCompletionProbe()
        let oldSources = (0..<2).map { index in
            let id = UUID()
            return MediaLibrarySource(id: id, displayName: "Old NAS \(index)") { path in
                #expect(path == "/")
                return await probe.listOldSource(id: id, gate: gate)
            }
        }
        let newSource = MediaLibrarySource(id: UUID(), displayName: "New NAS") { path in
            #expect(path == "/")
            return await probe.listNewSource()
        }
        let viewModel = MediaLibraryViewModel()

        let oldReload = Task {
            await viewModel.reload(sources: oldSources)
            await oldCompletion.markFinished()
        }
        let oldSourcesDidStart = await eventually {
            await probe.startedOldSourceCount == 2
        }
        if !oldSourcesDidStart {
            oldReload.cancel()
            await gate.resumeAll()
            _ = await eventually { await oldCompletion.didFinish }
        }
        try #require(oldSourcesDidStart)

        let newReload = Task {
            await viewModel.reload(sources: [newSource])
            await newCompletion.markFinished()
        }

        let newStartedBeforeRelease = await eventually(timeout: .milliseconds(100)) {
            await probe.didStartNewSource
        }
        #expect(!newStartedBeforeRelease)
        #expect(await probe.maximumActiveCount <= 2)

        await gate.resumeAll()
        let replacementDidFinish = await eventually {
            let oldDidFinish = await oldCompletion.didFinish
            let newDidFinish = await newCompletion.didFinish
            return oldDidFinish && newDidFinish
        }
        if !replacementDidFinish {
            oldReload.cancel()
            newReload.cancel()
            await gate.resumeAll()
            _ = await eventually { await oldCompletion.didFinish }
            _ = await eventually { await newCompletion.didFinish }
        }
        try #require(replacementDidFinish)
        await oldReload.value
        await newReload.value

        #expect(await probe.didStartNewSource)
        #expect(await probe.maximumActiveCount <= 2)
        #expect(viewModel.snapshot.items.map(\.media.path) == ["/new.mp4"])
        #expect(!viewModel.isLoading)
    }

    @Test func emptySourcesProduceEmptyNotLoadingSnapshot() async {
        let initialItem = libraryItem(sourceName: "Preview", path: "/preview.mp4")
        let initialFailure = MediaLibraryScanFailure(
            sourceID: initialItem.sourceID,
            sourceName: initialItem.sourceName
        )
        let viewModel = MediaLibraryViewModel(
            initialSnapshot: MediaLibrarySnapshot(
                items: [initialItem],
                failures: [initialFailure]
            )
        )

        await viewModel.reload(sources: [])

        #expect(viewModel.snapshot == MediaLibrarySnapshot())
        #expect(!viewModel.isLoading)
    }
}

private actor SuspensionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private(set) var hasWaiter = false

    func wait() async {
        hasWaiter = true
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ConcurrencyGate {
    private(set) var startedIDs: [UUID] = []
    private(set) var maximumActiveCount = 0
    private var activeCount = 0
    private var isOpen = false
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    var startedCount: Int {
        startedIDs.count
    }

    func enter(id: UUID) async {
        startedIDs.append(id)
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)

        if isOpen {
            activeCount -= 1
            return
        }

        await withCheckedContinuation { continuation in
            continuations[id] = continuation
        }

        activeCount -= 1
    }

    func resume(id: UUID) {
        continuations.removeValue(forKey: id)?.resume()
    }

    func resumeAll() {
        isOpen = true
        let waiting = continuations.values
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private actor CancellationProbe {
    private(set) var hasStarted = false
    private(set) var didObserveCancellation = false

    func list() async throws -> [MediaSourceItem] {
        hasStarted = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            didObserveCancellation = true
            return [videoItem(path: "/late.mp4")]
        }
        return []
    }
}

private actor ReloadReplacementProbe {
    private var activeCount = 0
    private var startedOldSourceIDs: Set<UUID> = []
    private var cancelledOldSourceIDs: Set<UUID> = []
    private(set) var maximumActiveCount = 0
    private(set) var didStartNewSource = false
    private(set) var didReturnOldReload = false
    private(set) var didReturnNewReload = false

    var startedOldSourceCount: Int {
        startedOldSourceIDs.count
    }

    var cancelledOldSourceCount: Int {
        cancelledOldSourceIDs.count
    }

    var replacementCompleted: Bool {
        cancelledOldSourceIDs.count == 2
            && didReturnOldReload
            && didReturnNewReload
    }

    func listOldSource(id: UUID) async throws -> [MediaSourceItem] {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        startedOldSourceIDs.insert(id)
        defer { activeCount -= 1 }

        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            cancelledOldSourceIDs.insert(id)
            throw CancellationError()
        }
        return []
    }

    func listNewSource() -> [MediaSourceItem] {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        didStartNewSource = true
        defer { activeCount -= 1 }
        return [videoItem(path: "/new.mp4")]
    }

    func markOldReloadReturned() {
        didReturnOldReload = true
    }

    func markNewReloadReturned() {
        didReturnNewReload = true
    }
}

private actor NonCooperativeGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeAll() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private actor NonCooperativeReplacementProbe {
    private var activeCount = 0
    private var startedOldSourceIDs: Set<UUID> = []
    private(set) var maximumActiveCount = 0
    private(set) var didStartNewSource = false

    var startedOldSourceCount: Int {
        startedOldSourceIDs.count
    }

    func listOldSource(
        id: UUID,
        gate: NonCooperativeGate
    ) async -> [MediaSourceItem] {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        startedOldSourceIDs.insert(id)
        defer { activeCount -= 1 }

        await gate.wait()
        return []
    }

    func listNewSource() -> [MediaSourceItem] {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        didStartNewSource = true
        defer { activeCount -= 1 }
        return [videoItem(path: "/new.mp4")]
    }
}

private actor TaskCompletionProbe {
    private(set) var didFinish = false

    func markFinished() {
        didFinish = true
    }
}

private struct SensitiveTestError: Error {
    let secret: String
}

@MainActor
private func eventually(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while !(await condition()), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }

    return await condition()
}

private func source(named name: String, videoPath: String) -> MediaLibrarySource {
    MediaLibrarySource(id: UUID(), displayName: name) { path in
        #expect(path == "/")
        return [videoItem(path: videoPath)]
    }
}

private func libraryItem(sourceName: String, path: String) -> MediaLibraryItem {
    MediaLibraryItem(
        sourceID: UUID(),
        sourceName: sourceName,
        media: videoItem(path: path)
    )
}

private func videoItem(path: String) -> MediaSourceItem {
    MediaSourceItem(
        name: (path as NSString).lastPathComponent,
        path: path,
        kind: .file,
        size: nil,
        modifiedAt: nil
    )
}

private func directoryItem(path: String) -> MediaSourceItem {
    MediaSourceItem(
        name: (path as NSString).lastPathComponent,
        path: path,
        kind: .directory,
        size: nil,
        modifiedAt: nil
    )
}
