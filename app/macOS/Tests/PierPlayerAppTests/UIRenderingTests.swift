import AppKit
import MediaSourceKit
import PlaybackCore
import RenderKit
import SwiftUI
import Testing
@testable import PierPlayerApp

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
