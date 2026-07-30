import AppKit
import MediaSourceKit
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
