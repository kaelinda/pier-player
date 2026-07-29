import AppKit
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
