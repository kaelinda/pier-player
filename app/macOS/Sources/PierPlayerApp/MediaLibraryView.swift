import AppKit
import SwiftUI

enum MediaLibrarySectionKind: Hashable {
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
        isScanning: Bool
    ) -> MediaLibraryContentState {
        guard itemCount > 0 else {
            if isRestoring {
                return MediaLibraryContentState(mode: .restoring, compactActivity: nil)
            }
            if sourceCount == 0 {
                return MediaLibraryContentState(mode: .noSources, compactActivity: nil)
            }
            if isScanning {
                return MediaLibraryContentState(mode: .scanning, compactActivity: nil)
            }
            let sections: [MediaLibrarySectionKind] = hasQuery
                ? [.noSearchResults, .fileSources]
                : [.noVideos, .fileSources]
            return MediaLibraryContentState(mode: .content(sections), compactActivity: nil)
        }

        let sections: [MediaLibrarySectionKind]
        if hasQuery {
            sections = filteredItemCount > 0
                ? [.searchResults]
                : [.noSearchResults, .fileSources]
        } else {
            sections = [.recentlyAdded, .allVideos, .fileSources]
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

    var body: some View {
        MediaLibraryContentView(
            snapshot: viewModel.snapshot,
            sourceSummaries: model.mediaLibrarySourceSummaries,
            isRestoring: model.isRestoring,
            isScanning: viewModel.isLoading,
            query: query,
            play: selectForPlayback,
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
                    refreshGeneration &+= 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Library")
                .accessibilityLabel("Refresh Library")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewModel.isLoading)
            }
        }
        .task(id: reloadRequest) {
            await viewModel.reload(sources: model.mediaLibrarySources)
        }
        .onChange(of: model.sources.map(\.id)) { _, sourceIDs in
            if let playerSelection, !sourceIDs.contains(playerSelection.source.id) {
                self.playerSelection = nil
            }
        }
        .sheet(item: $playerSelection) { selection in
            let diagnostics = model.makePlaybackDiagnosticDependencies()
            VideoPlayerSheet(
                item: selection.item.media,
                source: selection.source.source,
                diagnosticRecorder: diagnostics.recorder,
                diagnosticContext: diagnostics.context,
                identityProvider: diagnostics.identityProvider,
                progressManager: diagnostics.progressManager
            )
        }
    }

    private var reloadRequest: MediaLibraryReloadRequest {
        MediaLibraryReloadRequest(
            sourceIDs: model.sources.map(\.id),
            sourceRevision: model.sourceRevision,
            generation: refreshGeneration
        )
    }

    private func selectForPlayback(_ item: MediaLibraryItem) {
        guard let source = model.source(id: item.sourceID) else {
            return
        }
        playerSelection = MediaLibraryPlayerSelection(item: item, source: source)
    }
}

private struct MediaLibraryPlayerSelection: Identifiable {
    let item: MediaLibraryItem
    let source: AppModel.ConnectedSource

    var id: String { item.id }
}

struct MediaLibraryContentView: View {
    let snapshot: MediaLibrarySnapshot
    let sourceSummaries: [MediaLibrarySourceSummary]
    let isRestoring: Bool
    let isScanning: Bool
    let query: String
    let scanLimits: MediaLibraryScanLimits = MediaLibraryScanLimits()
    let play: (MediaLibraryItem) -> Void
    let openSource: (UUID) -> Void
    let addSource: () -> Void

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
            isScanning: isScanning
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
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .background(.background)
    }

    private var libraryStatus: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.primaryText)
                    .font(.title2.weight(.semibold))
                Text(summary.secondaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let compactActivity = contentState.compactActivity {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(compactActivity.accessibilityLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(Color.yellow.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
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
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
