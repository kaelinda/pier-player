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

struct MediaLibraryScanFailure: Equatable, Sendable {
    let sourceID: UUID
    let sourceName: String
}

struct MediaLibraryScanResult: Equatable, Sendable {
    let items: [MediaLibraryItem]
    let failure: MediaLibraryScanFailure?
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
