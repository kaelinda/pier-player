import Combine
import Foundation
import MediaSourceKit

struct MediaLibrarySource: Sendable {
    let id: UUID
    let displayName: String
    let listDirectory: @Sendable (String) async throws -> [MediaSourceItem]
}

struct MediaLibrarySourceSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
}

struct MediaLibraryItem: Identifiable, Hashable, Sendable {
    let sourceID: UUID
    let sourceName: String
    let media: MediaSourceItem

    var id: String {
        "\(sourceID.uuidString):\(media.path)"
    }
}

struct MediaLibraryScanLimits: Equatable, Sendable {
    let maximumDepth: Int
    let maximumVideoCount: Int

    init(maximumDepth: Int = 3, maximumVideoCount: Int = 200) {
        self.maximumDepth = maximumDepth
        self.maximumVideoCount = maximumVideoCount
    }
}

struct MediaLibraryScanFailure: Identifiable, Equatable, Sendable {
    let sourceID: UUID
    let sourceName: String

    var id: UUID { sourceID }
}

struct MediaLibraryScanResult: Equatable, Sendable {
    let items: [MediaLibraryItem]
    let failure: MediaLibraryScanFailure?
}

struct MediaLibrarySnapshot: Equatable, Sendable {
    var items: [MediaLibraryItem]
    var failures: [MediaLibraryScanFailure]

    init(
        items: [MediaLibraryItem] = [],
        failures: [MediaLibraryScanFailure] = []
    ) {
        self.items = items
        self.failures = failures
    }
}

struct MediaLibraryScanner: Sendable {
    let limits: MediaLibraryScanLimits

    init(limits: MediaLibraryScanLimits = MediaLibraryScanLimits()) {
        self.limits = limits
    }

    func scan(source: MediaLibrarySource) async throws -> MediaLibraryScanResult {
        guard limits.maximumDepth >= 0, limits.maximumVideoCount > 0 else {
            return MediaLibraryScanResult(items: [], failure: nil)
        }

        struct PendingDirectory {
            let path: String
            let depth: Int
        }

        var pendingDirectories = [PendingDirectory(path: "/", depth: 0)]
        var nextDirectoryIndex = 0
        var items: [MediaLibraryItem] = []

        while nextDirectoryIndex < pendingDirectories.count {
            try Task.checkCancellation()
            let directory = pendingDirectories[nextDirectoryIndex]
            nextDirectoryIndex += 1

            let entries: [MediaSourceItem]
            do {
                entries = try await source.listDirectory(directory.path)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                return MediaLibraryScanResult(
                    items: items,
                    failure: MediaLibraryScanFailure(
                        sourceID: source.id,
                        sourceName: source.displayName
                    )
                )
            }

            for entry in entries {
                try Task.checkCancellation()

                if entry.kind == .directory {
                    if directory.depth < limits.maximumDepth {
                        pendingDirectories.append(
                            PendingDirectory(
                                path: entry.path,
                                depth: directory.depth + 1
                            ))
                    }
                } else if entry.isSupportedVideo {
                    items.append(
                        MediaLibraryItem(
                            sourceID: source.id,
                            sourceName: source.displayName,
                            media: entry
                        ))
                    if items.count == limits.maximumVideoCount {
                        return MediaLibraryScanResult(items: items, failure: nil)
                    }
                }
            }
        }

        return MediaLibraryScanResult(items: items, failure: nil)
    }
}

@MainActor
final class MediaLibraryViewModel: ObservableObject {
    @Published private(set) var snapshot: MediaLibrarySnapshot
    @Published private(set) var isLoading = false

    private let scanner: MediaLibraryScanner
    private var reloadGeneration = 0

    init(
        scanner: MediaLibraryScanner = MediaLibraryScanner(),
        initialSnapshot: MediaLibrarySnapshot = MediaLibrarySnapshot()
    ) {
        self.scanner = scanner
        snapshot = initialSnapshot
    }

    func reload(sources: [MediaLibrarySource]) async {
        reloadGeneration += 1
        let generation = reloadGeneration
        snapshot = MediaLibrarySnapshot()
        isLoading = true

        defer {
            if reloadGeneration == generation {
                isLoading = false
            }
        }

        guard !sources.isEmpty, !Task.isCancelled else {
            return
        }

        let scanner = scanner
        await withTaskGroup(of: MediaLibraryScanResult?.self) { group in
            var nextSourceIndex = 0

            while nextSourceIndex < min(2, sources.count) {
                let source = sources[nextSourceIndex]
                nextSourceIndex += 1
                group.addTask {
                    try? await scanner.scan(source: source)
                }
            }

            while let result = await group.next() {
                guard !Task.isCancelled, reloadGeneration == generation else {
                    group.cancelAll()
                    return
                }

                if let result {
                    snapshot.items.append(contentsOf: result.items)
                    if let failure = result.failure {
                        snapshot.failures.append(failure)
                    }
                }

                if nextSourceIndex < sources.count {
                    let source = sources[nextSourceIndex]
                    nextSourceIndex += 1
                    group.addTask {
                        try? await scanner.scan(source: source)
                    }
                }
            }
        }
    }
}
