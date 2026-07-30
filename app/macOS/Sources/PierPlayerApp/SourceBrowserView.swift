import MediaSourceKit
import SMBSourceKit
import SwiftUI

struct SourceBrowserView: View {
    @EnvironmentObject private var model: AppModel
    let sourceID: UUID
    let path: String

    @State private var items: [MediaSourceItem] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedFile: MediaSourceItem?
    @State private var refreshGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            browserHeader
            Divider()
            browserContent
        }
        .navigationTitle(folderName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    refreshGeneration &+= 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Folder")
                .accessibilityLabel("Refresh Folder")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(isLoading)
            }
        }
        .navigationDestination(for: BrowserDestination.self) { destination in
            SourceBrowserView(sourceID: destination.sourceID, path: destination.path)
        }
        .task(id: BrowserLoadRequest(path: path, generation: refreshGeneration)) {
            await load()
        }
        .sheet(item: $selectedFile) { item in
            if let connectedSource = model.source(id: sourceID) {
                let diagnostics = model.makePlaybackDiagnosticDependencies()
                VideoPlayerSheet(
                    item: item,
                    source: connectedSource.source,
                    diagnosticRecorder: diagnostics.recorder,
                    diagnosticContext: diagnostics.context,
                    identityProvider: diagnostics.identityProvider
                )
            }
        }
    }

    private var browserHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.teal.opacity(0.12))
                Image(systemName: path == "/" ? "externaldrive.fill" : "folder.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.teal)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.source(id: sourceID)?.displayName ?? "Network Source")
                    .font(.headline)
                    .lineLimit(1)
                Text(displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if !isLoading, loadError == nil {
                Label(itemCountLabel, systemImage: "square.stack.3d.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(.background)
    }

    @ViewBuilder
    private var browserContent: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text("Loading Folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            ContentUnavailableView {
                Label("Cannot Load Folder", systemImage: "folder.badge.questionmark")
            } description: {
                Text(loadError)
            } actions: {
                Button {
                    refreshGeneration &+= 1
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
            }
        } else if items.isEmpty {
            ContentUnavailableView {
                Label("Empty Folder", systemImage: "folder")
            } description: {
                Text("This folder contains no files.")
            }
        } else {
            List(items) { item in
                browserRow(for: item)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func browserRow(for item: MediaSourceItem) -> some View {
        if item.kind == .directory {
            NavigationLink(value: BrowserDestination(
                sourceID: sourceID,
                path: item.path,
                name: item.name
            )) {
                MediaItemRow(item: item)
            }
        } else if item.isSupportedVideo {
            Button {
                selectedFile = item
            } label: {
                MediaItemRow(item: item)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the video player")
        } else {
            MediaItemRow(item: item)
                .foregroundStyle(.secondary)
        }
    }

    private var folderName: String {
        path == "/" ? "Files" : URL(fileURLWithPath: path).lastPathComponent
    }

    private var displayPath: String {
        guard let source = model.source(id: sourceID) else { return path }
        let base = "smb://\(source.configuration.host)/\(source.configuration.share)"
        return path == "/" ? base : base + path
    }

    private var itemCountLabel: String {
        items.count == 1 ? "1 Item" : "\(items.count) Items"
    }

    private func load() async {
        isLoading = true
        loadError = nil

        do {
            let loadedItems = try await model.list(sourceID: sourceID, directory: path)
            try Task.checkCancellation()
            items = loadedItems.filter { !$0.path.isEmpty }
        } catch is CancellationError {
            return
        } catch {
            loadError = String(describing: error)
        }

        isLoading = false
    }
}

private struct MediaItemRow: View {
    let item: MediaSourceItem

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(iconColor.opacity(0.12))
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(kindLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            if let sizeLabel {
                Text(sizeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
            }

            if let modifiedAt = item.modifiedAt {
                Text(modifiedAt, format: .dateTime.year().month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .trailing)
            }
        }
        .frame(minHeight: 38)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var iconName: String {
        if item.kind == .directory { return "folder.fill" }
        if item.isSupportedVideo { return "film.fill" }
        return "doc.fill"
    }

    private var iconColor: Color {
        if item.kind == .directory { return .teal }
        if item.isSupportedVideo { return .orange }
        return .secondary
    }

    private var kindLabel: String {
        if item.kind == .directory { return "Folder" }
        let fileExtension = (item.name as NSString).pathExtension.uppercased()
        guard !fileExtension.isEmpty else { return "File" }
        return item.isSupportedVideo ? "\(fileExtension) Video" : "\(fileExtension) File"
    }

    private var sizeLabel: String? {
        guard item.kind == .file, let size = item.size else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct BrowserDestination: Hashable, Identifiable {
    let sourceID: UUID
    let path: String
    let name: String

    var id: String { path }
}

private struct BrowserLoadRequest: Equatable {
    let path: String
    let generation: Int
}
