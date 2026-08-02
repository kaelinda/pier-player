import AppKit
import CloudSyncKit
import DiagnosticsKit
import MediaSourceKit
import PlaybackCore
import RenderKit
import SwiftUI
import Testing
@testable import PierPlayerApp

@Test func sidebarDestinationReconcilesRemovedSourcesToLibrary() {
    let existingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let missingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    #expect(SidebarDestination.source(missingID).reconciled(with: []) == .library)
    #expect(
        SidebarDestination.source(existingID).reconciled(with: [existingID])
            == .source(existingID)
    )
    #expect(SidebarDestination.library.reconciled(with: [existingID]) == .library)
}

@Test func sourceManagementPresentsCompleteActionsAndSafeEditDefaults() {
    #expect(SourceManagementAction.allCases.map(\.title) == [
        "Get Info",
        "Edit Source",
        "Remove Source",
    ])
    let removal = SourceRemovalRequest(
        id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        displayName: "Home NAS"
    )
    #expect(removal.title == "Remove \"Home NAS\"?")
    #expect(removal.message.contains("saved credentials"))
    #expect(removal.message.contains("will not be deleted"))

    let details = sourceManagementDetailsFixture()
    #expect(details.address == "smb://nas.local/Media")
    #expect(details.domainText == "WORKGROUP")
    #expect(details.encryptionText == "Required")

    var draft = SMBSourceFormDraft(details: details)
    #expect(draft.displayName == "Home NAS")
    #expect(draft.username == "viewer")
    #expect(draft.password.isEmpty)
    #expect(draft.replacementPassword == nil)
    #expect(draft.canSubmit)

    draft.password = "replacement"
    #expect(draft.replacementPassword == "replacement")

    let idleInteraction = SourceEditInteractionState(isSaving: false)
    #expect(idleInteraction.allowsDismissal)
    #expect(idleInteraction.allowsEditing)

    let savingInteraction = SourceEditInteractionState(isSaving: true)
    #expect(!savingInteraction.allowsDismissal)
    #expect(!savingInteraction.allowsEditing)
}

@Test func mediaLibraryStatePrioritizesRestorationAndPreservesExistingContent() {
    let restoringEmpty = MediaLibraryContentState.resolve(
        sourceCount: 1,
        itemCount: 0,
        filteredItemCount: 0,
        hasQuery: false,
        isRestoring: true,
        isScanning: true
    )
    #expect(restoringEmpty.mode == .restoring)
    #expect(restoringEmpty.compactActivity == nil)

    let restoringContent = MediaLibraryContentState.resolve(
        sourceCount: 2,
        itemCount: 8,
        filteredItemCount: 8,
        hasQuery: false,
        isRestoring: true,
        isScanning: true
    )
    #expect(
        restoringContent.mode == .content([
            .recentlyAdded,
            .allVideos,
            .fileSources,
        ])
    )
    #expect(restoringContent.compactActivity == .restoring)
    #expect(restoringContent.compactActivity?.accessibilityLabel == "Restoring Sources")

    let refreshingContent = MediaLibraryContentState.resolve(
        sourceCount: 2,
        itemCount: 8,
        filteredItemCount: 8,
        hasQuery: false,
        isRestoring: false,
        isScanning: true
    )
    #expect(refreshingContent.mode == restoringContent.mode)
    #expect(refreshingContent.compactActivity == .refreshing)
    #expect(refreshingContent.compactActivity?.accessibilityLabel == "Refreshing Library")

    let scanningEmpty = MediaLibraryContentState.resolve(
        sourceCount: 2,
        itemCount: 0,
        filteredItemCount: 0,
        hasQuery: false,
        isRestoring: false,
        isScanning: true
    )
    #expect(scanningEmpty.mode == .scanning)
}

@Test func mediaLibrarySearchCompositionUsesOnlyOneResultsShelf() {
    let matching = MediaLibraryContentState.resolve(
        sourceCount: 2,
        itemCount: 8,
        filteredItemCount: 3,
        hasQuery: true,
        isRestoring: false,
        isScanning: false
    )
    #expect(matching.mode == .content([.searchResults]))

    let empty = MediaLibraryContentState.resolve(
        sourceCount: 2,
        itemCount: 8,
        filteredItemCount: 0,
        hasQuery: true,
        isRestoring: false,
        isScanning: false
    )
    #expect(empty.mode == .content([.noSearchResults, .fileSources]))
}

@Test func noVideoStateAcknowledgesBoundedDiscovery() {
    #expect(
        MediaLibraryContentCopy.noVideosDescription
            == "No supported videos were found within the scanned folders."
    )
}

@Test func continuitySectionsPrecedeScannedSectionsWhenNotSearching() {
    let state = MediaLibraryContentState.resolve(
        sourceCount: 2,
        itemCount: 4,
        filteredItemCount: 4,
        continueWatchingCount: 1,
        recentlyPlayedCount: 1,
        hasQuery: false,
        isRestoring: false,
        isScanning: false
    )

    #expect(state.mode == .content([
        .continueWatching,
        .recentlyPlayed,
        .recentlyAdded,
        .allVideos,
        .fileSources,
    ]))
}

@Test func continuityRemainsVisibleWhenScanIsEmptyButSearchHidesIt() {
    let continuityOnly = MediaLibraryContentState.resolve(
        sourceCount: 1,
        itemCount: 0,
        filteredItemCount: 0,
        continueWatchingCount: 1,
        recentlyPlayedCount: 0,
        hasQuery: false,
        isRestoring: false,
        isScanning: false
    )
    #expect(continuityOnly.mode == .content([
        .continueWatching,
        .allVideos,
        .fileSources,
    ]))

    let searching = MediaLibraryContentState.resolve(
        sourceCount: 1,
        itemCount: 4,
        filteredItemCount: 1,
        continueWatchingCount: 1,
        recentlyPlayedCount: 1,
        hasQuery: true,
        isRestoring: false,
        isScanning: false
    )
    #expect(searching.mode == .content([.searchResults]))
}

@Test func continuityCardPresentationAndRoutingAreExplicit() throws {
    let sourceID = UUID()
    let item = MediaLibraryItem(
        sourceID: sourceID,
        sourceName: "Family NAS",
        media: MediaSourceItem(
            name: "Arrival.mkv",
            path: "/Movies/Arrival.mkv",
            kind: .file,
            size: 1_024,
            modifiedAt: nil
        )
    )
    let progress = try PlaybackProgress(
        mediaID: String(repeating: "a", count: 64),
        sourceID: sourceID,
        position: 42,
        duration: 100
    )
    let available = MediaLibraryProjectedItem(
        mediaID: progress.mediaID,
        item: item,
        lastPlayedAt: Date(),
        progress: progress,
        isAvailable: true
    )
    let watched = MediaLibraryProjectedItem(
        mediaID: progress.mediaID,
        item: item,
        lastPlayedAt: Date(),
        progress: try PlaybackProgress(
            mediaID: progress.mediaID,
            sourceID: sourceID,
            position: 96,
            duration: 100
        ),
        isAvailable: false
    )

    #expect(ContinuityCardPresentation(item: available).progressText == "42%")
    #expect(ContinuityCardPresentation(item: available).showsProgressBar)
    #expect(!ContinuityCardPresentation(item: available).showsStatusBackground)
    #expect(ContinuityCardPresentation(item: watched).badgeText == "Watched")
    #expect(ContinuityCardPresentation(item: watched).progressText == nil)
    #expect(!ContinuityCardPresentation(item: watched).showsProgressBar)
    #expect(ContinuityCardPresentation(item: watched).showsStatusBackground)
    #expect(ContinuityCardPresentation(item: watched).availabilityText == "Unavailable")
    #expect(MediaLibraryContinuityAction.route(for: available) == .play(item))
    #expect(MediaLibraryContinuityAction.route(for: watched) == .openSource(sourceID))
}

@Test func projectedItemIdentityUsesMediaIdentityForReplacements() {
    let sourceID = UUID()
    let item = MediaLibraryItem(
        sourceID: sourceID,
        sourceName: "Family NAS",
        media: MediaSourceItem(
            name: "Replacement.mkv",
            path: "/Movies/Replacement.mkv",
            kind: .file,
            size: 2_048,
            modifiedAt: nil
        )
    )
    let first = MediaLibraryProjectedItem(
        mediaID: String(repeating: "a", count: 64),
        item: item,
        lastPlayedAt: nil,
        progress: nil,
        isAvailable: true
    )
    let replacement = MediaLibraryProjectedItem(
        mediaID: String(repeating: "b", count: 64),
        item: item,
        lastPlayedAt: nil,
        progress: nil,
        isAvailable: true
    )
    let unidentified = MediaLibraryProjectedItem(
        mediaID: nil,
        item: item,
        lastPlayedAt: nil,
        progress: nil,
        isAvailable: true
    )

    #expect(first.id != replacement.id)
    #expect(unidentified.id == item.id)
}

@Test func continuityCardHoverRespectsReduceMotion() {
    #expect(ContinuityCardMotion.hoverOffset(isHovering: true, reduceMotion: false) == -2)
    #expect(ContinuityCardMotion.hoverOffset(isHovering: true, reduceMotion: true) == 0)
    #expect(ContinuityCardMotion.hoverOffset(isHovering: false, reduceMotion: false) == 0)
    #expect(ContinuityCardMotion.hoverScale(isHovering: true, reduceMotion: false) == 1.012)
    #expect(ContinuityCardMotion.hoverScale(isHovering: true, reduceMotion: true) == 1)
    #expect(ContinuityCardMotion.hoverScale(isHovering: false, reduceMotion: false) == 1)
}

@MainActor
@Test func cancelledContinuityLoadDoesNotPublishLateResult() async throws {
    let gate = ContinuityLoadGate()
    let model = MediaLibraryContinuityModel()
    let late = try continuityInput(marker: "a")

    let load = Task {
        await model.reload {
            await gate.wait(for: late)
        }
    }
    try #require(await eventuallyRendering { await gate.hasWaiter })

    load.cancel()
    await gate.resume()
    await load.value

    #expect(model.input == .empty)
}

@MainActor
@Test func newestContinuityLoadWinsWhenOlderLoadFinishesLast() async throws {
    let oldGate = ContinuityLoadGate()
    let newGate = ContinuityLoadGate()
    let model = MediaLibraryContinuityModel()
    let old = try continuityInput(marker: "a")
    let new = try continuityInput(marker: "b")

    let oldLoad = Task {
        await model.reload {
            await oldGate.wait(for: old)
        }
    }
    try #require(await eventuallyRendering { await oldGate.hasWaiter })

    let newLoad = Task {
        await model.reload {
            await newGate.wait(for: new)
        }
    }
    try #require(await eventuallyRendering { await newGate.hasWaiter })

    await newGate.resume()
    await newLoad.value
    #expect(model.input == new)

    await oldGate.resume()
    await oldLoad.value
    #expect(model.input == new)
}

@MainActor
@Test func continuityRefreshDoesNotListMediaDirectories() async throws {
    let listProbe = MediaLibraryListProbe()
    let source = MediaLibrarySource(id: UUID(), displayName: "NAS") { _ in
        await listProbe.list()
    }
    let scannerModel = MediaLibraryViewModel()
    let continuityModel = MediaLibraryContinuityModel()
    let input = try continuityInput(marker: "c")
    let scan = Task {
        await scannerModel.reload(sources: [source])
    }
    try #require(await eventuallyRendering { await listProbe.hasWaiter })

    await continuityModel.reload {
        input
    }

    #expect(continuityModel.input == input)
    #expect(await listProbe.count == 1)
    #expect(scannerModel.isLoading)

    await listProbe.resume()
    await scan.value
    #expect(await listProbe.count == 1)
}

@Test func mediaLibrarySummaryAdaptsToLibraryCounts() {
    let empty = MediaLibrarySummary(videoCount: 0, sourceCount: 0)
    #expect(empty.primaryText == "No videos")
    #expect(empty.secondaryText == "Connect a source to begin")

    let single = MediaLibrarySummary(videoCount: 1, sourceCount: 1)
    #expect(single.primaryText == "1 video")
    #expect(single.secondaryText == "From 1 source")

    let populated = MediaLibrarySummary(videoCount: 8, sourceCount: 2)
    #expect(populated.primaryText == "8 videos")
    #expect(populated.secondaryText == "Across 2 sources")

    let historyOnly = MediaLibrarySummary(videoCount: 2, sourceCount: 0)
    #expect(historyOnly.primaryText == "2 videos")
    #expect(historyOnly.secondaryText == "Saved playback history")
}

@Test func playbackTimeLabelsUseHoursOnlyWhenNeeded() {
    #expect(PlaybackControlCopy.timeLabel(.nan) == "0:00")
    #expect(PlaybackControlCopy.timeLabel(.greatestFiniteMagnitude) == "0:00")
    #expect(PlaybackControlCopy.timeLabel(-1) == "0:00")
    #expect(PlaybackControlCopy.timeLabel(65) == "1:05")
    #expect(PlaybackControlCopy.timeLabel(3_661) == "1:01:01")
}

@Test func subtitleAppearanceReadsValidSystemCaptionMetrics() {
    let appearance = SubtitleAppearance.system
    #expect(appearance.relativeCharacterSize >= 0.5)
    #expect(SubtitleAppearance.settingsChangedNotification.rawValue.isEmpty == false)
}

@MainActor
@Test func rootViewRendersAtMinimumWindowSize() throws {
    let size = CGSize(width: 820, height: 560)
    let image = try renderInWindow(
        RootView()
            .environmentObject(AppModel())
            .tint(.teal)
            .preferredColorScheme(.dark)
            .frame(width: size.width, height: size.height),
        at: size,
        appearance: NSAppearance(named: .darkAqua)
    )

    #expect(image.size == size)
    #expect(image.tiffRepresentation?.isEmpty == false)
    #expect(distinctSampledColorCount(in: image) > 8)
    #expect(darkPixelFraction(in: image) > 0.6)
    try writeSnapshotIfRequested(image, name: "root-view")
}

@MainActor
@Test func rootSidebarRendersSelectedLibraryAndSourceStatus() throws {
    let size = CGSize(width: 260, height: 560)
    let image = try renderInWindow(
        RootSidebarContent(
            sources: [],
            isRestoring: true,
            selection: .constant(.library),
            addSource: {},
            showSourceInformation: { _ in },
            editSource: { _ in },
            removeSource: { _ in }
        )
        .preferredColorScheme(.dark)
        .tint(.teal)
        .frame(width: size.width, height: size.height),
        at: size,
        appearance: NSAppearance(named: .darkAqua)
    )

    #expect(image.size == size)
    #expect(image.tiffRepresentation?.isEmpty == false)
    #expect(distinctSampledColorCount(in: image) > 8)
    #expect(darkPixelFraction(in: image) > 0.6)
    try writeSnapshotIfRequested(image, name: "root-sidebar")
}

@MainActor
@Test func sourceInformationSheetRendersAtDesignedSize() throws {
    let size = CGSize(width: 520, height: 430)
    let image = try render(
        SourceInformationView(details: sourceManagementDetailsFixture())
            .tint(.teal)
            .frame(width: size.width, height: size.height),
        at: size
    )

    #expect(image.size == size)
    #expect(image.tiffRepresentation?.isEmpty == false)
    try writeSnapshotIfRequested(image, name: "source-information-sheet")
}

@MainActor
@Test func editSourceSheetRendersAtDesignedSize() throws {
    let size = CGSize(width: 520, height: 590)
    let image = try render(
        EditSMBSourceView(
            model: AppModel(),
            details: sourceManagementDetailsFixture()
        )
        .tint(.teal)
        .frame(width: size.width, height: size.height),
        at: size
    )

    #expect(image.size == size)
    #expect(image.tiffRepresentation?.isEmpty == false)
    try writeSnapshotIfRequested(image, name: "edit-source-sheet")
}

@MainActor
@Test func addSourceSheetRendersAtDesignedSize() throws {
    let size = CGSize(width: 520, height: 560)
    let image = try render(
        AddSMBSourceView(model: AppModel())
            .tint(.teal)
            .frame(width: size.width, height: size.height),
        at: size
    )

    #expect(image.size == size)
    #expect(image.tiffRepresentation?.isEmpty == false)
    try writeSnapshotIfRequested(image, name: "add-source-sheet")
}

@MainActor
@Test(arguments: [
    (CGSize(width: 820, height: 560), "media-library-minimum"),
    (CGSize(width: 1120, height: 720), "media-library-default"),
])
func populatedMediaLibraryRenders(
    size: CGSize,
    snapshotName: String
) throws {
    let fixture = mediaLibraryFixture()
    let image = try renderInWindow(
        MediaLibraryContentView(
            snapshot: fixture.snapshot,
            continuity: .empty,
            sourceSummaries: fixture.sources,
            isRestoring: false,
            isScanning: true,
            query: "",
            play: { _ in },
            openSource: { _ in },
            addSource: {}
        )
        .preferredColorScheme(.dark)
        .tint(.teal)
        .frame(width: size.width, height: size.height),
        at: size,
        appearance: NSAppearance(named: .darkAqua)
    )

    #expect(image.size == size)
    #expect(image.tiffRepresentation?.isEmpty == false)
    try writeSnapshotIfRequested(image, name: snapshotName)
}

@MainActor
@Test(arguments: [
    (CGSize(width: 820, height: 560), "continuity-minimum-dark", true),
    (CGSize(width: 820, height: 560), "continuity-minimum-light", false),
    (CGSize(width: 1_120, height: 720), "continuity-default-dark", true),
    (CGSize(width: 1_120, height: 720), "continuity-default-light", false),
])
func continuityMediaLibraryRendersProgressWatchedUnavailableAndPartialFailure(
    size: CGSize,
    snapshotName: String,
    isDark: Bool
) throws {
    let fixture = try continuityMediaLibraryFixture()
    let image = try renderInWindow(
        MediaLibraryContentView(
            snapshot: fixture.snapshot,
            continuity: fixture.continuity,
            sourceSummaries: fixture.sources,
            isRestoring: false,
            isScanning: false,
            query: "",
            play: { _ in },
            openSource: { _ in },
            addSource: {}
        )
        .preferredColorScheme(isDark ? .dark : .light)
        .tint(.teal)
        .frame(width: size.width, height: size.height),
        at: size,
        appearance: NSAppearance(named: isDark ? .darkAqua : .aqua)
    )

    #expect(fixture.snapshot.failures.count == 1)
    #expect(image.size == size)
    #expect(image.tiffRepresentation?.isEmpty == false)
    #expect(distinctSampledColorCount(in: image) > 8)
    if isDark {
        #expect(darkPixelFraction(in: image) > 0.6)
    } else {
        #expect(darkPixelFraction(in: image) < 0.6)
    }
    try writeSnapshotIfRequested(image, name: snapshotName)
}

@MainActor
@Test func populatedMediaLibraryRendersInLightAppearance() throws {
    let size = CGSize(width: 1_120, height: 720)
    let fixture = mediaLibraryFixture()
    let image = try renderInWindow(
        MediaLibraryContentView(
            snapshot: fixture.snapshot,
            continuity: .empty,
            sourceSummaries: fixture.sources,
            isRestoring: false,
            isScanning: false,
            query: "",
            play: { _ in },
            openSource: { _ in },
            addSource: {}
        )
        .preferredColorScheme(.light)
        .tint(.teal)
        .frame(width: size.width, height: size.height),
        at: size,
        appearance: NSAppearance(named: .aqua)
    )

    #expect(image.size == size)
    #expect(image.tiffRepresentation?.isEmpty == false)
    #expect(darkPixelFraction(in: image) < 0.6)
    try writeSnapshotIfRequested(image, name: "media-library-light")
}

@MainActor
@Test(arguments: [
    CGSize(width: 760, height: 520),
    CGSize(width: 1_180, height: 760),
])
func playerRendersLongMetadataAtSupportedSizes(size: CGSize) async throws {
    let item = testVideoItem()
    let coordinator = ModelTestCoordinator()
    let model = VideoPlayerModel(
        item: item,
        source: ModelTestSource(file: ModelTestFile(size: 1_024)),
        renderer: SampleBufferRenderer(),
        coordinator: coordinator
    )
    await model.start()
    coordinator.send(snapshot(
        state: .buffering(.seek),
        tracks: [
            PlaybackTrack(index: 1, kind: .audio, codecName: "aac", language: "jpn", title: "Japanese lossless commentary track with a long title", isSelected: true),
            PlaybackTrack(index: 2, kind: .subtitle, codecName: "subrip", language: "eng", title: "English signs and dialogue with a long title", isSelected: true),
        ]
    ))
    try await waitForModel(model) { $0.state == .buffering(.seek) }
    let image = try render(
        VideoPlayerSheet(item: item, playerModel: model)
            .frame(width: size.width, height: size.height),
        at: size
    )

    #expect(image.size == size)
    #expect(image.tiffRepresentation?.isEmpty == false)
    try writeSnapshotIfRequested(image, name: "player-\(Int(size.width))")
}

@MainActor
@Test func videoPlayerSheetRendersPreparingState() throws {
    let size = CGSize(width: 960, height: 640)
    let item = MediaSourceItem(
        name: "Large Fixture.mp4",
        path: "/Movies/Large Fixture.mp4",
        kind: .file,
        size: 8 * 1024 * 1024 * 1024,
        modifiedAt: nil
    )
    let image = try render(
        VideoPlayerSheet(item: item, source: SuspendedRenderingMediaSource())
            .tint(.teal)
            .frame(width: size.width, height: size.height),
        at: size
    )

    #expect(image.size == size)
    #expect(image.tiffRepresentation?.isEmpty == false)
    try writeSnapshotIfRequested(image, name: "video-player-preparing")
}

@MainActor
@Test func subtitleOverlayRendersAtAccessibilityTextSize() throws {
    let size = CGSize(width: 760, height: 220)
    let image = try render(
        SubtitleOverlayView(
            text: "A long subtitle line remains readable when accessibility text sizing is enabled."
        )
        .dynamicTypeSize(.accessibility3)
        .padding(24)
        .frame(width: size.width, height: size.height, alignment: .bottom),
        at: size
    )

    #expect(image.size == size)
    #expect(image.tiffRepresentation?.isEmpty == false)
    #expect(distinctSampledColorCount(in: image) > 2)
    try writeSnapshotIfRequested(image, name: "subtitle-accessibility-size")
}

@MainActor
@Test func videoPlayerSheetRendersFriendlyCorruptMediaFailure() async throws {
    let size = CGSize(width: 760, height: 520)
    let item = testVideoItem()
    let coordinator = ModelTestCoordinator()
    let model = VideoPlayerModel(
        item: item,
        source: ModelTestSource(file: ModelTestFile(size: 1_024)),
        renderer: SampleBufferRenderer(),
        coordinator: coordinator
    )
    await model.start()
    coordinator.send(snapshot(
        state: .failed("submit media packet: Invalid NAL unit size"),
        failure: PlaybackFailure(
            boundary: .videoDecode,
            reason: .corruptMedia,
            message: "submit media packet: Invalid NAL unit size",
            diagnosticCode: -1_094_995_529
        )
    ))
    try await waitForModel(model) { $0.failure?.reason == .corruptMedia }

    let image = try render(
        VideoPlayerSheet(item: item, playerModel: model)
            .frame(width: size.width, height: size.height),
        at: size
    )

    #expect(image.size == size)
    #expect(image.tiffRepresentation?.isEmpty == false)
    #expect(distinctSampledColorCount(in: image) > 8)
    try writeSnapshotIfRequested(image, name: "video-player-corrupt-media")
}

@MainActor
@Test(arguments: DiagnosticSettingsRenderingFixture.all)
private func diagnosticsSettingsRendersAllOperationalStates(
    fixture: DiagnosticSettingsRenderingFixture
) throws {
    let size = CGSize(width: 520, height: 560)
    let image = try renderInWindow(
        DiagnosticsSettingsContentView(
            snapshot: fixture.snapshot,
            now: fixture.now,
            selectedRunIDs: .constant(Set(fixture.snapshot.recentRuns.map(\.runID))),
            isExporting: false,
            setDetailedEnabled: { _ in },
            export: {},
            reveal: {},
            clear: {}
        )
        .preferredColorScheme(.dark)
        .tint(.teal)
        .frame(width: size.width, height: size.height),
        at: size
    )

    #expect(image.size == size)
    #expect(image.tiffRepresentation?.isEmpty == false)
    #expect(distinctSampledColorCount(in: image) > 8)
    #expect(darkPixelFraction(in: image) > 0.55)
    #expect(DiagnosticsSettingsCopy.detailedDiagnostics == "Detailed Diagnostics")
    #expect(DiagnosticsSettingsCopy.storageUsage == "Storage Usage")
    #expect(DiagnosticsSettingsCopy.recentSessions == "Recent Sessions")
    #expect(DiagnosticsSettingsCopy.export == "Export")
    #expect(DiagnosticsSettingsCopy.reveal == "Reveal in Finder")
    #expect(DiagnosticsSettingsCopy.clear == "Clear History")
    try writeSnapshotIfRequested(image, name: "diagnostics-settings-\(fixture.name)")
}

@MainActor
@Test func diagnosticsSettingsRendersInLightAppearance() throws {
    let size = CGSize(width: 520, height: 560)
    let fixture = DiagnosticSettingsRenderingFixture.all[0]
    let image = try renderInWindow(
        DiagnosticsSettingsContentView(
            snapshot: fixture.snapshot,
            now: fixture.now,
            selectedRunIDs: .constant([]),
            isExporting: false,
            setDetailedEnabled: { _ in },
            export: {},
            reveal: {},
            clear: {}
        )
        .preferredColorScheme(.light)
        .tint(.teal)
        .frame(width: size.width, height: size.height),
        at: size,
        appearance: NSAppearance(named: .aqua)
    )

    #expect(image.size == size)
    #expect(image.tiffRepresentation?.isEmpty == false)
    #expect(distinctSampledColorCount(in: image) > 8)
    #expect(darkPixelFraction(in: image) < 0.45)
    try writeSnapshotIfRequested(image, name: "diagnostics-settings-light")
}

@MainActor
private func render<Content: View>(_ content: Content, at size: CGSize) throws -> NSImage {
    let hostingView = NSHostingView(rootView: content)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()

    let representation = try #require(
        hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
    )
    hostingView.cacheDisplay(in: hostingView.bounds, to: representation)

    let image = NSImage(size: size)
    image.addRepresentation(representation)
    return image
}

@MainActor
private func renderInWindow<Content: View>(
    _ content: Content,
    at size: CGSize,
    appearance: NSAppearance? = nil
) throws -> NSImage {
    let hostingView = NSHostingView(rootView: content)
    hostingView.appearance = appearance
    hostingView.frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.contentView = hostingView
    window.orderFrontRegardless()
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }

    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    hostingView.layoutSubtreeIfNeeded()

    let representation = try #require(
        hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
    )
    hostingView.cacheDisplay(in: hostingView.bounds, to: representation)

    let image = NSImage(size: size)
    image.addRepresentation(representation)
    return image
}

private func distinctSampledColorCount(in image: NSImage) -> Int {
    guard let data = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: data) else {
        return 0
    }

    var colors: Set<UInt32> = []
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                continue
            }
            let red = UInt32((color.redComponent * 15).rounded())
            let green = UInt32((color.greenComponent * 15).rounded())
            let blue = UInt32((color.blueComponent * 15).rounded())
            colors.insert((red << 8) | (green << 4) | blue)
        }
    }
    return colors.count
}

private func darkPixelFraction(in image: NSImage) -> Double {
    guard let data = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: data) else {
        return 0
    }

    var darkPixels = 0
    var sampledPixels = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                continue
            }
            let luminance = 0.2126 * color.redComponent
                + 0.7152 * color.greenComponent
                + 0.0722 * color.blueComponent
            darkPixels += luminance < 0.5 ? 1 : 0
            sampledPixels += 1
        }
    }
    return sampledPixels == 0 ? 0 : Double(darkPixels) / Double(sampledPixels)
}

private func writeSnapshotIfRequested(_ image: NSImage, name: String) throws {
    guard let outputPath = ProcessInfo.processInfo.environment["PIER_UI_SNAPSHOT_DIR"] else {
        return
    }
    let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let tiffData = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiffData))
    let pngData = try #require(bitmap.representation(using: .png, properties: [:]))
    try pngData.write(to: outputDirectory.appendingPathComponent("\(name).png"))
}

private func mediaLibraryFixture() -> (
    snapshot: MediaLibrarySnapshot,
    sources: [MediaLibrarySourceSummary]
) {
    let studioID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let archiveID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    let sources = [
        MediaLibrarySourceSummary(id: studioID, displayName: "Studio NAS"),
        MediaLibrarySourceSummary(id: archiveID, displayName: "Family Archive"),
    ]
    let videos: [(UUID, String, String, String, TimeInterval)] = [
        (studioID, "Studio NAS", "Arrival Cut.mkv", "/Films/Arrival Cut.mkv", 1_785_480_000),
        (archiveID, "Family Archive", "Coastal Morning.mp4", "/Trips/Coastal Morning.mp4", 1_785_393_600),
        (studioID, "Studio NAS", "Night Train.mov", "/Films/Night Train.mov", 1_785_307_200),
        (archiveID, "Family Archive", "Summer Reel.m4v", "/Trips/Summer Reel.m4v", 1_785_220_800),
        (studioID, "Studio NAS", "Workshop Session.mp4", "/Projects/Workshop Session.mp4", 1_785_134_400),
        (archiveID, "Family Archive", "Winter Lights.mkv", "/Family/Winter Lights.mkv", 1_785_048_000),
        (studioID, "Studio NAS", "Blue Hour.mov", "/Films/Blue Hour.mov", 1_784_961_600),
        (archiveID, "Family Archive", "First Steps.mp4", "/Family/First Steps.mp4", 1_784_875_200),
    ]
    let items = videos.enumerated().map { index, video in
        MediaLibraryItem(
            sourceID: video.0,
            sourceName: video.1,
            media: MediaSourceItem(
                name: video.2,
                path: video.3,
                kind: .file,
                size: Int64(750_000_000 + index * 125_000_000),
                modifiedAt: Date(timeIntervalSince1970: video.4)
            )
        )
    }

    return (
        MediaLibrarySnapshot(
            items: items,
            failures: [
                MediaLibraryScanFailure(
                    sourceID: archiveID,
                    sourceName: "Family Archive"
                ),
            ]
        ),
        sources
    )
}

private func continuityMediaLibraryFixture() throws -> (
    snapshot: MediaLibrarySnapshot,
    continuity: MediaLibraryContinuityInput,
    sources: [MediaLibrarySourceSummary]
) {
    let fixture = mediaLibraryFixture()
    let continuingItem = fixture.snapshot.items[0]
    let watchedItem = fixture.snapshot.items[1]
    let offlineSourceID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    let continuingMediaID = mediaIDForFixture(continuingItem)
    let watchedMediaID = mediaIDForFixture(watchedItem)
    let unavailableMediaID = String(repeating: "c", count: 64)
    let history = [
        try PlaybackHistoryEntry(
            mediaID: continuingMediaID,
            sourceID: continuingItem.sourceID,
            sourceDisplayName: continuingItem.sourceName,
            fileName: continuingItem.media.name,
            path: continuingItem.media.path,
            size: continuingItem.media.size ?? 0,
            modifiedAt: continuingItem.media.modifiedAt,
            lastPlayedAt: Date(timeIntervalSince1970: 1_800_000_300)
        ),
        try PlaybackHistoryEntry(
            mediaID: watchedMediaID,
            sourceID: watchedItem.sourceID,
            sourceDisplayName: watchedItem.sourceName,
            fileName: watchedItem.media.name,
            path: watchedItem.media.path,
            size: watchedItem.media.size ?? 0,
            modifiedAt: watchedItem.media.modifiedAt,
            lastPlayedAt: Date(timeIntervalSince1970: 1_800_000_200)
        ),
        try PlaybackHistoryEntry(
            mediaID: unavailableMediaID,
            sourceID: offlineSourceID,
            sourceDisplayName: "Offline Archive",
            fileName: "Unavailable Cut.mkv",
            path: "/Archive/Unavailable Cut.mkv",
            size: 3_000_000_000,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastPlayedAt: Date(timeIntervalSince1970: 1_800_000_100)
        ),
    ]
    let progress = [
        try PlaybackProgress(
            mediaID: continuingMediaID,
            sourceID: continuingItem.sourceID,
            position: 42,
            duration: 100
        ),
        try PlaybackProgress(
            mediaID: watchedMediaID,
            sourceID: watchedItem.sourceID,
            position: 96,
            duration: 100
        ),
    ]
    let connectedSourceIDs = Set(fixture.sources.map(\.id))

    return (
        fixture.snapshot,
        MediaLibraryContinuityInput(
            history: history,
            progress: progress,
            configuredSourceIDs: connectedSourceIDs.union([offlineSourceID]),
            connectedSourceIDs: connectedSourceIDs
        ),
        fixture.sources + [
            MediaLibrarySourceSummary(id: offlineSourceID, displayName: "Offline Archive"),
        ]
    )
}

private func mediaIDForFixture(_ item: MediaLibraryItem) -> String {
    MediaSyncIdentity.make(from: MediaFileIdentity(
        sourceID: item.sourceID,
        path: item.media.path,
        size: item.media.size ?? 0,
        modifiedAt: item.media.modifiedAt
    ))
}

private func continuityInput(marker: Character) throws -> MediaLibraryContinuityInput {
    let sourceID = UUID()
    return MediaLibraryContinuityInput(
        history: [],
        progress: [
            try PlaybackProgress(
                mediaID: String(repeating: marker, count: 64),
                sourceID: sourceID,
                position: 42,
                duration: 100
            ),
        ],
        configuredSourceIDs: [sourceID],
        connectedSourceIDs: [sourceID]
    )
}

private actor ContinuityLoadGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var hasWaiter: Bool { continuation != nil }

    func wait(for input: MediaLibraryContinuityInput) async -> MediaLibraryContinuityInput {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return input
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor MediaLibraryListProbe {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var count = 0

    var hasWaiter: Bool { continuation != nil }

    func list() async -> [MediaSourceItem] {
        count += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return []
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func eventuallyRendering(
    attempts: Int = 200,
    condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

private func sourceManagementDetailsFixture() -> SMBSourceDetails {
    SMBSourceDetails(
        id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
        displayName: "Home NAS",
        host: "nas.local",
        share: "Media",
        username: "viewer",
        domain: "WORKGROUP",
        requiresEncryption: true
    )
}

private struct DiagnosticSettingsRenderingFixture: Sendable, CustomTestStringConvertible {
    let name: String
    let now: Date
    let snapshot: DiagnosticStatusSnapshot

    var testDescription: String { name }

    static let all: [DiagnosticSettingsRenderingFixture] = {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let run = DiagnosticRunSummary(
            runID: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            startedAt: now.addingTimeInterval(-600),
            endedAt: now.addingTimeInterval(-300),
            policy: .standard,
            byteCount: 512 * 1_024
        )
        return [
            DiagnosticSettingsRenderingFixture(
                name: "standard-empty",
                now: now,
                snapshot: DiagnosticStatusSnapshot(
                    policy: .standard,
                    detailedUntil: nil,
                    isCapturingIncident: false,
                    storageBytes: 0,
                    recentRuns: [],
                    warning: nil
                )
            ),
            DiagnosticSettingsRenderingFixture(
                name: "detailed",
                now: now,
                snapshot: DiagnosticStatusSnapshot(
                    policy: .detailed,
                    detailedUntil: now.addingTimeInterval(24 * 60),
                    isCapturingIncident: false,
                    storageBytes: 18 * 1_024 * 1_024,
                    recentRuns: [run],
                    warning: nil
                )
            ),
            DiagnosticSettingsRenderingFixture(
                name: "incident",
                now: now,
                snapshot: DiagnosticStatusSnapshot(
                    policy: .incident,
                    detailedUntil: nil,
                    isCapturingIncident: true,
                    storageBytes: 32 * 1_024 * 1_024,
                    recentRuns: [run],
                    warning: nil
                )
            ),
            DiagnosticSettingsRenderingFixture(
                name: "storage-warning",
                now: now,
                snapshot: DiagnosticStatusSnapshot(
                    policy: .standard,
                    detailedUntil: nil,
                    isCapturingIncident: false,
                    storageBytes: 100 * 1_024 * 1_024,
                    recentRuns: [run],
                    warning: .storageLimitReached
                )
            ),
        ]
    }()
}

private actor SuspendedRenderingMediaSource: MediaSource {
    nonisolated let id = UUID()
    nonisolated let displayName = "Rendering Source"

    func connect() async throws {}
    func disconnect() async {}

    func list(directory path: String) async throws -> [MediaSourceItem] {
        []
    }

    func open(file path: String) async throws -> any MediaReadableFile {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}
