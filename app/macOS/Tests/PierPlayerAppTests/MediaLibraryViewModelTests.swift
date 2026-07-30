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

    @Test func reloadPublishesFastSourceWhileSlowSourceIsRunning() async {
        let slowGate = SuspensionGate()
        let slow = MediaLibrarySource(id: UUID(), displayName: "Slow NAS") { path in
            #expect(path == "/")
            await slowGate.wait()
            return [videoItem(path: "/slow.mp4")]
        }
        let fast = source(named: "Fast NAS", videoPath: "/fast.mp4")
        let viewModel = MediaLibraryViewModel()

        let reload = Task {
            await viewModel.reload(sources: [slow, fast])
        }

        #expect(await eventually { await slowGate.hasWaiter })
        #expect(await eventually {
            viewModel.snapshot.items.map(\.media.path) == ["/fast.mp4"]
        })
        #expect(viewModel.isLoading)

        await slowGate.resume()
        await reload.value

        #expect(
            viewModel.snapshot.items.map(\.media.path).sorted()
                == ["/fast.mp4", "/slow.mp4"]
        )
        #expect(!viewModel.isLoading)
    }

    @Test func reloadScansAtMostTwoSourcesConcurrently() async {
        let gate = ConcurrencyGate()
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
        }

        #expect(await eventually { await gate.startedCount == 2 })
        #expect(await gate.maximumActiveCount == 2)
        let firstWave = await gate.startedIDs
        await gate.resume(id: firstWave[0])

        #expect(await eventually { await gate.startedCount == 3 })
        #expect(await gate.maximumActiveCount == 2)

        await gate.resumeAll()
        await reload.value

        #expect(viewModel.snapshot.items.count == 4)
        #expect(await gate.maximumActiveCount == 2)
        #expect(!viewModel.isLoading)
    }

    @Test func cancellingReloadStopsLoadingAndIgnoresLateResult() async {
        let probe = CancellationProbe()
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
        }

        #expect(await eventually { await probe.hasStarted })
        #expect(viewModel.snapshot == MediaLibrarySnapshot())
        #expect(viewModel.isLoading)

        reload.cancel()
        await reload.value

        #expect(await probe.didObserveCancellation)
        #expect(viewModel.snapshot == MediaLibrarySnapshot())
        #expect(!viewModel.isLoading)
    }

    @Test func newerReloadWinsOverOlderLateResult() async {
        let oldGate = SuspensionGate()
        let oldSource = MediaLibrarySource(id: UUID(), displayName: "Old NAS") { path in
            #expect(path == "/")
            await oldGate.wait()
            return [videoItem(path: "/old.mp4")]
        }
        let newSource = source(named: "New NAS", videoPath: "/new.mp4")
        let viewModel = MediaLibraryViewModel()

        let oldReload = Task {
            await viewModel.reload(sources: [oldSource])
        }
        #expect(await eventually { await oldGate.hasWaiter })

        await viewModel.reload(sources: [newSource])
        #expect(viewModel.snapshot.items.map(\.media.path) == ["/new.mp4"])
        #expect(!viewModel.isLoading)

        await oldGate.resume()
        await oldReload.value

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
    private(set) var hasWaiter = false

    func wait() async {
        hasWaiter = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
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
