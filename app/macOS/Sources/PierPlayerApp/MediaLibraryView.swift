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
                progressManager: diagnostics.progressManager,
                historyStore: diagnostics.historyStore,
                sourceDisplayName: selection.source.displayName,
                onStopped: model.publishContinuityRevision
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

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 30) {
                libraryStatus

                if !sortedFailures.isEmpty {
                    failureNotice
                }

                content
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

private struct MediaLibrarySection<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            content
        }
    }
}

private struct RecentMediaCard: View {
    let item: MediaLibraryItem
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                MediaArtwork(item: item)
                    .frame(width: 248, height: 140)
                    .shadow(
                        color: PierPlayerTheme.accent.opacity(isHovering ? 0.18 : 0),
                        radius: isHovering ? 10 : 4,
                        y: isHovering ? 5 : 2
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                borderColor,
                                lineWidth: isFocused ? 2 : 1
                            )
                    }
                    .overlay {
                        if isHovering {
                            playOverlay
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                    }

                mediaLabels
            }
            .frame(width: 248, alignment: .leading)
        }
        .buttonStyle(MediaCardButtonStyle())
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .offset(y: isHovering ? -2 : 0)
        .scaleEffect(isHovering ? 1.012 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the video player")
    }

    private var mediaLabels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(MediaLibraryPresentation.displayTitle(for: item))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(item.sourceName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var borderColor: Color {
        isFocused ? .accentColor : .white.opacity(isHovering ? 0.34 : 0.12)
    }

    private var playOverlay: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(.black.opacity(0.62), in: Circle())
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        "\(MediaLibraryPresentation.displayTitle(for: item)), \(item.sourceName)"
    }
}

private struct PosterMediaCard: View {
    let item: MediaLibraryItem
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                MediaArtwork(item: item)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .shadow(
                        color: PierPlayerTheme.accent.opacity(isHovering ? 0.18 : 0),
                        radius: isHovering ? 10 : 4,
                        y: isHovering ? 5 : 2
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                borderColor,
                                lineWidth: isFocused ? 2 : 1
                            )
                    }
                    .overlay {
                        if isHovering {
                            playOverlay
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(MediaLibraryPresentation.displayTitle(for: item))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.sourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MediaCardButtonStyle())
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .offset(y: isHovering ? -2 : 0)
        .scaleEffect(isHovering ? 1.012 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the video player")
    }

    private var borderColor: Color {
        isFocused ? .accentColor : .white.opacity(isHovering ? 0.34 : 0.12)
    }

    private var playOverlay: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(.black.opacity(0.62), in: Circle())
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        "\(MediaLibraryPresentation.displayTitle(for: item)), \(item.sourceName)"
    }
}

private struct MediaSourceCard: View {
    let source: MediaLibrarySourceSummary
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(PierPlayerTheme.accent.opacity(0.16))
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(PierPlayerTheme.accent)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(source.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("Browse Files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(width: 220, height: 78)
            .background(
                isHovering
                    ? Color.accentColor.opacity(0.08)
                    : Color(nsColor: .controlBackgroundColor)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        borderColor,
                        lineWidth: isFocused ? 2 : 1
                    )
            }
        }
        .buttonStyle(MediaCardButtonStyle())
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .offset(y: isHovering ? -1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source.displayName)
        .accessibilityHint("Opens the file browser")
    }

    private var borderColor: Color {
        isFocused ? .accentColor : .white.opacity(isHovering ? 0.28 : 0.1)
    }
}

private struct MediaCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.1),
                value: configuration.isPressed
            )
    }
}

private struct MediaArtwork: View {
    let item: MediaLibraryItem

    private let symbols = [
        "film.fill",
        "play.rectangle.fill",
        "video.fill",
        "movieclapper.fill",
        "rectangle.stack.fill",
        "tv.fill",
    ]

    private let palettes: [(base: Color, accent: Color)] = [
        (Color(red: 0.08, green: 0.25, blue: 0.29), Color(red: 0.18, green: 0.66, blue: 0.63)),
        (Color(red: 0.25, green: 0.15, blue: 0.27), Color(red: 0.85, green: 0.42, blue: 0.55)),
        (Color(red: 0.15, green: 0.21, blue: 0.29), Color(red: 0.90, green: 0.72, blue: 0.36)),
        (Color(red: 0.26, green: 0.20, blue: 0.16), Color(red: 0.83, green: 0.48, blue: 0.29)),
        (Color(red: 0.12, green: 0.25, blue: 0.22), Color(red: 0.47, green: 0.71, blue: 0.43)),
        (Color(red: 0.25, green: 0.18, blue: 0.21), Color(red: 0.79, green: 0.46, blue: 0.39)),
        (Color(red: 0.18, green: 0.19, blue: 0.28), Color(red: 0.50, green: 0.65, blue: 0.85)),
        (Color(red: 0.24, green: 0.23, blue: 0.14), Color(red: 0.76, green: 0.70, blue: 0.36)),
    ]

    var body: some View {
        GeometryReader { proxy in
            let style = MediaLibraryPresentation.posterStyle(for: item)
            let palette = palettes[style.paletteIndex % palettes.count]

            ZStack {
                palette.base

                Rectangle()
                    .fill(palette.accent.opacity(0.72))
                    .frame(width: proxy.size.width * 1.45, height: proxy.size.height * 0.42)
                    .rotationEffect(.degrees(-16))
                    .offset(y: proxy.size.height * 0.23)

                Image(systemName: symbols[style.symbolIndex % symbols.count])
                    .font(.system(size: min(proxy.size.width, proxy.size.height) * 0.25, weight: .medium))
                    .foregroundStyle(.white.opacity(0.94))
                    .shadow(color: palette.base.opacity(0.42), radius: 3, y: 1)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                extensionBadge
                    .padding(8)
            }
        }
        .accessibilityHidden(true)
    }

    private var extensionBadge: some View {
        Text(fileExtension)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(.black.opacity(0.58))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var fileExtension: String {
        let value = (item.media.name as NSString).pathExtension.uppercased()
        return value.isEmpty ? "VIDEO" : value
    }
}
