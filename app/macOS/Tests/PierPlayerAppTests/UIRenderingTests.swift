import AppKit
import MediaSourceKit
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

@MainActor
@Test func rootViewRendersAtMinimumWindowSize() throws {
    let size = CGSize(width: 820, height: 560)
    let image = try render(
        RootView()
            .environmentObject(AppModel())
            .tint(.teal)
            .frame(width: size.width, height: size.height),
        at: size
    )

    #expect(image.size == size)
    #expect(image.tiffRepresentation?.isEmpty == false)
    try writeSnapshotIfRequested(image, name: "root-view")
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
    let image = try render(
        MediaLibraryContentView(
            snapshot: fixture.snapshot,
            sourceSummaries: fixture.sources,
            isLoading: false,
            query: "",
            play: { _ in },
            openSource: { _ in },
            addSource: {}
        )
        .preferredColorScheme(.dark)
        .tint(.teal)
        .frame(width: size.width, height: size.height),
        at: size
    )

    #expect(image.size == size)
    #expect(image.tiffRepresentation?.isEmpty == false)
    try writeSnapshotIfRequested(image, name: snapshotName)
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
