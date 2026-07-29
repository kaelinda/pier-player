import AVKit
import MediaSourceKit
import SMBSourceKit
import SwiftUI

@MainActor
final class VideoPlayerModel: ObservableObject {
    let item: MediaSourceItem
    let source: SMBMediaSource

    @Published var phase: Phase = .downloading(progress: 0)
    @Published var localURL: URL?
    @Published var downloadedByteCount: Int64 = 0

    enum Phase: Equatable {
        case downloading(progress: Double)
        case playing
        case failed(String)
    }

    private var tempFileURL: URL?

    init(item: MediaSourceItem, source: SMBMediaSource) {
        self.item = item
        self.source = source
    }

    func start() async {
        phase = .downloading(progress: 0)
        downloadedByteCount = 0

        do {
            let file = try await source.open(file: item.path)
            let fileSize = file.identity.size
            let tempDirectory = FileManager.default.temporaryDirectory
            let safeName = item.name
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            let tempURL = tempDirectory.appendingPathComponent(
                "PierPlayer-\(UUID().uuidString.prefix(8))-\(safeName)"
            )
            tempFileURL = tempURL

            var allData = Data()
            var downloaded: Int64 = 0
            let chunkSize = 1 * 1024 * 1024

            while downloaded < fileSize {
                try Task.checkCancellation()
                let remaining = fileSize - downloaded
                let readSize = min(Int64(chunkSize), remaining)
                let data = try await file.read(at: downloaded, length: Int(readSize))
                if data.isEmpty { break }
                allData.append(data)
                downloaded += Int64(data.count)
                downloadedByteCount = downloaded
                let progress = fileSize > 0 ? Double(downloaded) / Double(fileSize) : 1
                phase = .downloading(progress: min(progress, 1))
            }

            try allData.write(to: tempURL)
            localURL = tempURL
            phase = .playing
        } catch is CancellationError {
            cleanup()
        } catch {
            phase = .failed(String(describing: error))
            cleanup()
        }
    }

    func cleanup() {
        if let tempFileURL {
            try? FileManager.default.removeItem(at: tempFileURL)
        }
        tempFileURL = nil
    }
}

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
                VideoPlayerSheet(item: item, source: connectedSource.source)
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

struct VideoPlayerSheet: View {
    let item: MediaSourceItem
    let source: SMBMediaSource

    @StateObject private var playerModel: VideoPlayerModel
    @Environment(\.dismiss) private var dismiss

    init(item: MediaSourceItem, source: SMBMediaSource) {
        self.item = item
        self.source = source
        _playerModel = StateObject(wrappedValue: VideoPlayerModel(item: item, source: source))
    }

    var body: some View {
        VStack(spacing: 0) {
            playerHeader
            Divider()
            playerContent
        }
        .frame(minWidth: 760, idealWidth: 960, minHeight: 520, idealHeight: 640)
        .background(Color.black)
        .task {
            await playerModel.start()
        }
        .onDisappear {
            playerModel.cleanup()
        }
    }

    private var playerHeader: some View {
        HStack(spacing: 11) {
            Image(systemName: "film.fill")
                .foregroundStyle(.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = item.size {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Close Player")
            .accessibilityLabel("Close Player")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(.bar)
    }

    @ViewBuilder
    private var playerContent: some View {
        switch playerModel.phase {
        case .downloading(let progress):
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                    Image(systemName: "externaldrive.fill.badge.timemachine")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.teal)
                }
                .frame(width: 64, height: 64)

                VStack(spacing: 6) {
                    Text("Preparing Video")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(downloadProgressLabel(progress))
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.62))
                        .monospacedDigit()
                }

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.teal)
                    .frame(width: 360)
                    .accessibilityLabel("Download Progress")
                    .accessibilityValue("\(Int(progress * 100)) percent")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .black))

        case .playing:
            if let localURL = playerModel.localURL {
                VideoPlayerView(url: localURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            } else {
                PlayerFailureView(message: "The local video could not be opened.")
            }

        case .failed(let message):
            PlayerFailureView(message: message)
        }
    }

    private func downloadProgressLabel(_ progress: Double) -> String {
        let downloaded = ByteCountFormatter.string(
            fromByteCount: playerModel.downloadedByteCount,
            countStyle: .file
        )
        guard let total = item.size else {
            return "\(downloaded) downloaded"
        }
        let totalLabel = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "\(downloaded) of \(totalLabel)  ·  \(Int(progress * 100))%"
    }
}

private struct PlayerFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Playback Failed")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

struct VideoPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
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
