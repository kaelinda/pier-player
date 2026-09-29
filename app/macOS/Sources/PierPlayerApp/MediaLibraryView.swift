import AppKit
import CloudSyncKit
import SwiftUI

enum MediaLibrarySectionKind: Hashable {
    case continueWatching
    case recentlyPlayed
    case recentlyAdded
    case allVideos
    case fileSources
    case searchResults
    case noSearchResults
    case noVideos
}

enum MediaLibraryContentCopy {
    static let noVideosDescription =
        "No supported videos were found within the scanned folders."
}

struct MediaLibraryLimitNoticeCopy: Equatable {
    let title: String
    let message: String

    static func make(
        didReachMaximumVideoCount: Bool,
        query: String,
        limits: MediaLibraryScanLimits = MediaLibraryScanLimits()
    ) -> MediaLibraryLimitNoticeCopy? {
        guard didReachMaximumVideoCount,
              query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        return MediaLibraryLimitNoticeCopy(
            title: "Library Scan Limit Reached",
            message:
                "Showing up to \(limits.maximumVideoCount) videos within "
                + "\(limits.maximumDepth) folder levels. Browse a source to find more."
        )
    }
}

struct MediaLibrarySummary: Equatable {
    let primaryText: String
    let secondaryText: String

    init(videoCount: Int, sourceCount: Int) {
        switch videoCount {
        case 0:
            primaryText = "No videos"
        case 1:
            primaryText = "1 video"
        default:
            primaryText = "\(videoCount) videos"
        }

        switch (videoCount, sourceCount) {
        case (0, 0):
            secondaryText = "Connect a source to begin"
        case (_, 1):
            secondaryText = "From 1 source"
        default:
            secondaryText = "Across \(sourceCount) sources"
        }
    }
}

enum MediaLibraryContentMode: Equatable {
    case restoring
    case scanning
    case noSources
    case content([MediaLibrarySectionKind])
}

enum MediaLibraryCompactActivity: Equatable {
    case restoring
    case refreshing

    var accessibilityLabel: String {
        switch self {
        case .restoring:
            return "Restoring Sources"
        case .refreshing:
            return "Refreshing Library"
        }
    }
}

struct MediaLibraryContentState: Equatable {
    let mode: MediaLibraryContentMode
    let compactActivity: MediaLibraryCompactActivity?

    static func resolve(
        sourceCount: Int,
        itemCount: Int,
        filteredItemCount: Int,
        hasQuery: Bool,
        isRestoring: Bool,
        isScanning: Bool,
        hasContinueWatching: Bool = false,
        hasRecentlyPlayed: Bool = false
    ) -> MediaLibraryContentState {
        let historySections: [MediaLibrarySectionKind] =
            (hasContinueWatching ? [.continueWatching] : [])
            + (hasRecentlyPlayed ? [.recentlyPlayed] : [])

        guard itemCount > 0 else {
            if isRestoring {
                return MediaLibraryContentState(mode: .restoring, compactActivity: nil)
            }
            if sourceCount == 0, historySections.isEmpty {
                return MediaLibraryContentState(mode: .noSources, compactActivity: nil)
            }
            if isScanning {
                return MediaLibraryContentState(mode: .scanning, compactActivity: nil)
            }
            let sections: [MediaLibrarySectionKind] = hasQuery
                ? [.noSearchResults, .fileSources]
                : historySections + [.noVideos, .fileSources]
            return MediaLibraryContentState(mode: .content(sections), compactActivity: nil)
        }

        let sections: [MediaLibrarySectionKind]
        if hasQuery {
            sections = filteredItemCount > 0
                ? [.searchResults]
                : [.noSearchResults, .fileSources]
        } else {
            sections = historySections + [.recentlyAdded, .allVideos, .fileSources]
        }

        let compactActivity: MediaLibraryCompactActivity?
        if isRestoring {
            compactActivity = .restoring
        } else if isScanning {
            compactActivity = .refreshing
        } else {
            compactActivity = nil
        }

        return MediaLibraryContentState(
            mode: .content(sections),
            compactActivity: compactActivity
        )
    }
}

struct MediaLibraryView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var destination: SidebarDestination
    let addSource: () -> Void

    @StateObject private var viewModel = MediaLibraryViewModel()
    @State private var query = ""
    @State private var refreshGeneration = 0
    @State private var playerSelection: MediaLibraryPlayerSelection?
    @State private var isConfirmingClearPlaybackHistory = false

    var body: some View {
        MediaLibraryContentView(
            snapshot: viewModel.snapshot,
            sourceSummaries: model.mediaLibrarySourceSummaries,
            playbackProgress: model.playbackProgress,
            sourceNames: model.mediaLibrarySourceNames,
            isRestoring: model.isRestoring,
            isScanning: viewModel.isLoading,
            query: query,
            play: { item in
                selectForPlayback(item)
            },
            playFromBeginning: { item in
                selectForPlayback(item, startMode: .fromBeginning)
            },
            removePlaybackHistory: { mediaID in
                Task { await model.removePlaybackHistory(mediaID: mediaID) }
            },
            openSource: { destination = .source($0) },
            addSource: addSource
        )
        .navigationTitle("Media Library")
        .searchable(
            text: $query,
            placement: .toolbar,
            prompt: "Search Library"
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    refreshLibrary()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Library")
                .accessibilityLabel("Refresh Library")
                .disabled(viewModel.isLoading)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    isConfirmingClearPlaybackHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("Clear Playback History")
                .accessibilityLabel("Clear Playback History")
                .disabled(
                    model.isLoadingPlaybackHistory
                        || !model.playbackProgress.contains { !$0.isDeleted }
                )
            }
        }
        .confirmationDialog(
            "Clear Playback History?",
            isPresented: $isConfirmingClearPlaybackHistory,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                Task { await model.clearPlaybackHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes saved resume positions from all devices after synchronization.")
        }
        .focusedValue(
            \.refreshMediaLibraryAction,
            refreshLibrary
        )
        .focusedValue(
            \.clearPlaybackHistoryAction,
            requestClearPlaybackHistory
        )
        .task(id: reloadRequest) {
            await viewModel.reload(sources: model.mediaLibrarySources)
            await model.refreshPlaybackProgress()
        }
        .onChange(of: model.sources.map(\.id)) { _, sourceIDs in
            if let playerSelection,
               playerSelection.entries.contains(where: {
                   !sourceIDs.contains($0.sourceID)
               }) {
                self.playerSelection = nil
            }
        }
        .sheet(item: $playerSelection) { selection in
            PlaybackQueuePlayerView(
                entries: selection.entries,
                startIndex: selection.startIndex,
                startMode: selection.startMode
            )
            .onDisappear {
                Task { await model.refreshPlaybackProgress() }
            }
        }
    }

    private func refreshLibrary() {
        guard !viewModel.isLoading else { return }
        refreshGeneration &+= 1
    }

    private func requestClearPlaybackHistory() {
        guard !model.isLoadingPlaybackHistory,
              model.playbackProgress.contains(where: { !$0.isDeleted }) else {
            return
        }
        isConfirmingClearPlaybackHistory = true
    }

    private var reloadRequest: MediaLibraryReloadRequest {
        MediaLibraryReloadRequest(
            sourceIDs: model.sources.map(\.id),
            sourceRevision: model.sourceRevision,
            generation: refreshGeneration
        )
    }

    private func selectForPlayback(
        _ item: MediaLibraryItem,
        startMode: PlaybackStartMode = .automatic
    ) {
        guard model.source(id: item.sourceID) != nil else { return }
        let entries = MediaLibraryPresentation
            .allVideos(viewModel.snapshot.items)
            .map { media in
                PlaybackQueueEntry(
                    sourceID: media.sourceID,
                    sourceName: media.sourceName,
                    media: media.media
                )
            }
        guard let startIndex = entries.firstIndex(where: { $0.id == item.id }) else {
            return
        }
        playerSelection = MediaLibraryPlayerSelection(
            entries: entries,
            startIndex: startIndex,
            startMode: startMode
        )
    }
}

private struct MediaLibraryPlayerSelection: Identifiable {
    let entries: [PlaybackQueueEntry]
    let startIndex: Int
    let startMode: PlaybackStartMode

    var id: String {
        guard entries.indices.contains(startIndex) else {
            return "empty-playback-queue"
        }
        return entries[startIndex].id
    }
}

struct MediaLibraryContentView: View {
    let snapshot: MediaLibrarySnapshot
    let sourceSummaries: [MediaLibrarySourceSummary]
    let playbackProgress: [PlaybackProgress]
    let sourceNames: [UUID: String]
    let isRestoring: Bool
    let isScanning: Bool
    let query: String
    let scanLimits: MediaLibraryScanLimits
    let play: (MediaLibraryItem) -> Void
    let playFromBeginning: (MediaLibraryItem) -> Void
    let removePlaybackHistory: (String) -> Void
    let openSource: (UUID) -> Void
    let addSource: () -> Void

    init(
        snapshot: MediaLibrarySnapshot,
        sourceSummaries: [MediaLibrarySourceSummary],
        playbackProgress: [PlaybackProgress] = [],
        sourceNames: [UUID: String] = [:],
        isRestoring: Bool,
        isScanning: Bool,
        query: String,
        scanLimits: MediaLibraryScanLimits = MediaLibraryScanLimits(),
        play: @escaping (MediaLibraryItem) -> Void,
        playFromBeginning: @escaping (MediaLibraryItem) -> Void = { _ in },
        removePlaybackHistory: @escaping (String) -> Void = { _ in },
        openSource: @escaping (UUID) -> Void,
        addSource: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.sourceSummaries = sourceSummaries
        self.playbackProgress = playbackProgress
        self.sourceNames = sourceNames
        self.isRestoring = isRestoring
        self.isScanning = isScanning
        self.query = query
        self.scanLimits = scanLimits
        self.play = play
        self.playFromBeginning = playFromBeginning
        self.removePlaybackHistory = removePlaybackHistory
        self.openSource = openSource
        self.addSource = addSource
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredItems: [MediaLibraryItem] {
        MediaLibraryPresentation.filtered(snapshot.items, query: query)
    }

    private var recentItems: [MediaLibraryItem] {
        MediaLibraryPresentation.recentlyAdded(snapshot.items)
    }

    private var allItems: [MediaLibraryItem] {
        MediaLibraryPresentation.allVideos(snapshot.items)
    }

    private var playbackHistory: PlaybackHistorySnapshot {
        PlaybackHistoryPresentation.make(
            progress: playbackProgress,
            items: snapshot.items,
            sourceNames: sourceNames
        )
    }

    private var sortedFailures: [MediaLibraryScanFailure] {
        snapshot.failures.sorted {
            let comparison = $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return $0.sourceID.uuidString < $1.sourceID.uuidString
        }
    }

    private var contentState: MediaLibraryContentState {
        MediaLibraryContentState.resolve(
            sourceCount: sourceSummaries.count,
            itemCount: snapshot.items.count,
            filteredItemCount: filteredItems.count,
            hasQuery: !trimmedQuery.isEmpty,
            isRestoring: isRestoring,
            isScanning: isScanning,
            hasContinueWatching: !playbackHistory.continueWatching.isEmpty,
            hasRecentlyPlayed: !playbackHistory.recentlyPlayed.isEmpty
        )
    }

    private var summary: MediaLibrarySummary {
        MediaLibrarySummary(
            videoCount: snapshot.items.count,
            sourceCount: sourceSummaries.count
        )
    }

    private var limitNoticeCopy: MediaLibraryLimitNoticeCopy? {
        MediaLibraryLimitNoticeCopy.make(
            didReachMaximumVideoCount: snapshot.didReachMaximumVideoCount,
            query: query,
            limits: scanLimits
        )
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 30) {
                libraryStatus

                if !sortedFailures.isEmpty {
                    failureNotice
                }

                if let limitNoticeCopy {
                    limitNotice(copy: limitNoticeCopy)
                }

                content
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .background(.background)
    }

    private var libraryStatus: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.primaryText)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                Text(summary.secondaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let compactActivity = contentState.compactActivity {
                Label {
                    Text(compactActivity.accessibilityLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.08))
                }
                .accessibilityElement(children: .combine)
                    .accessibilityLabel(compactActivity.accessibilityLabel)
            }
        }
        .frame(minHeight: 44)
    }

    private var failureNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(failureLabel)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.yellow.opacity(0.18))
        }
        .accessibilityElement(children: .combine)
    }

    private func limitNotice(copy: MediaLibraryLimitNoticeCopy) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.title)
                    .font(.callout.weight(.medium))
                Text(copy.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        switch contentState.mode {
        case .restoring:
            progressState(title: "Restoring Sources")
        case .scanning:
            progressState(title: "Scanning Library")
        case .noSources:
            noSourcesState
        case let .content(sections):
            ForEach(sections, id: \.self) { section in
                contentSection(section)
            }
        }
    }

    @ViewBuilder
    private func contentSection(_ section: MediaLibrarySectionKind) -> some View {
        switch section {
        case .continueWatching:
            continueWatchingSection
        case .recentlyPlayed:
            recentlyPlayedSection
        case .recentlyAdded:
            recentSection
        case .allVideos:
            allVideosSection(items: allItems, title: "All Videos")
        case .fileSources:
            sourcesSection
        case .searchResults:
            allVideosSection(items: filteredItems, title: "Search Results")
        case .noSearchResults:
            noResultsState
        case .noVideos:
            noVideosState
        }
    }

    private var continueWatchingSection: some View {
        PlaybackHistorySection(
            title: "Continue Watching",
            items: playbackHistory.continueWatching,
            play: play,
            playFromBeginning: playFromBeginning,
            remove: removePlaybackHistory
        )
    }

    private var recentlyPlayedSection: some View {
        PlaybackHistorySection(
            title: "Recently Played",
            items: playbackHistory.recentlyPlayed,
            play: play,
            playFromBeginning: playFromBeginning,
            remove: removePlaybackHistory
        )
    }

    private var recentSection: some View {
        MediaLibrarySection(title: "Recently Added", count: recentItems.count) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(recentItems) { item in
                        RecentMediaCard(item: item) {
                            play(item)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func allVideosSection(
        items: [MediaLibraryItem],
        title: String
    ) -> some View {
        MediaLibrarySection(title: title, count: items.count) {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 132, maximum: 164),
                        spacing: 16,
                        alignment: .top
                    ),
                ],
                alignment: .leading,
                spacing: 18
            ) {
                ForEach(items) { item in
                    PosterMediaCard(item: item) {
                        play(item)
                    }
                }
            }
        }
    }

    private var sourcesSection: some View {
        MediaLibrarySection(title: "File Sources", count: sourceSummaries.count) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(sourceSummaries) { source in
                        MediaSourceCard(source: source) {
                            openSource(source.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func progressState(title: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        }
        .accessibilityElement(children: .combine)
    }

    private var noSourcesState: some View {
        ContentUnavailableView {
            Label("No File Sources", systemImage: "externaldrive.badge.plus")
        } description: {
            Text("Connect an SMB source to build your media library.")
        } actions: {
            Button(action: addSource) {
                Label("Add Source", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var noVideosState: some View {
        ContentUnavailableView {
            Label("No Supported Videos", systemImage: "film")
        } description: {
            Text(MediaLibraryContentCopy.noVideosDescription)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var noResultsState: some View {
        ContentUnavailableView.search(text: trimmedQuery)
            .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var failureLabel: String {
        let names = sortedFailures.map(\.sourceName).joined(separator: ", ")
        return "Could not scan \(names)"
    }
}

private struct MediaLibraryReloadRequest: Hashable {
    let sourceIDs: [UUID]
    let sourceRevision: Int
    let generation: Int
}
