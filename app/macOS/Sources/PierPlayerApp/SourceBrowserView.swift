import AVKit
import MediaSourceKit
import SMBSourceKit
import SwiftUI

/// Manages downloading a video from SMB and playing it locally.
@MainActor
final class VideoPlayerModel: ObservableObject {
    let item: MediaSourceItem
    let source: SMBMediaSource

    @Published var phase: Phase = .downloading(progress: 0)
    @Published var localURL: URL?
    @Published var error: String?

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

        do {
            let file = try await source.open(file: item.path)
            let fileSize = file.identity.size

            let tempDir = FileManager.default.temporaryDirectory
            let safeName = item.name
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            let tempURL = tempDir.appendingPathComponent("PierPlayer-\(UUID().uuidString.prefix(8))-\(safeName)")
            tempFileURL = tempURL

            // Write downloaded data to temp file
            var allData = Data()
            var downloaded: Int64 = 0
            let chunkSize = 1 * 1024 * 1024  // 1MB chunks

            while downloaded < fileSize {
                let remaining = fileSize - downloaded
                let readSize = min(Int64(chunkSize), remaining)
                let data = try await file.read(at: downloaded, length: Int(readSize))
                if data.isEmpty { break }
                allData.append(data)
                downloaded += Int64(data.count)
                let prog = fileSize > 0 ? Double(downloaded) / Double(fileSize) : 1.0
                phase = .downloading(progress: min(prog, 1.0))
            }

            try allData.write(to: tempURL)
            localURL = tempURL
            phase = .playing
        } catch {
            self.error = String(describing: error)
            phase = .failed(String(describing: error))
            if let url = tempFileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func cleanup() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - SourceBrowserView

/// Displays a single directory listing with navigation link support.
struct SourceBrowserView: View {
    @EnvironmentObject var model: AppModel
    let sourceID: UUID
    let path: String

    @State private var items: [MediaSourceItem] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedFile: MediaSourceItem?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = loadError {
                ContentUnavailableView {
                    Label("Cannot Load Folder", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(error)
                }
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("Empty Folder", systemImage: "folder")
                }
            } else {
                List(items, id: \.path) { item in
                    if item.kind == .directory {
                        NavigationLink(value: BrowserDestination(sourceID: sourceID, path: item.path, name: item.name)) {
                            Label(item.name, systemImage: "folder")
                        }
                    } else if item.isSupportedVideo {
                        Button {
                            selectedFile = nil  // reset first to avoid SwiftUI sheet bug
                            selectedFile = item
                        } label: {
                            Label(item.name, systemImage: "film")
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Label(item.name, systemImage: "doc")
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(path == "/" ? "Root" : URL(fileURLWithPath: path).lastPathComponent)
        .navigationDestination(for: BrowserDestination.self) { destination in
            BrowserDestinationView(destination: destination)
        }
        .task(id: path) {
            guard !Task.isCancelled else { return }
            await load()
        }
        .sheet(item: $selectedFile) { item in
            if let connected = model.source(id: sourceID) {
                VideoPlayerSheet(item: item, source: connected.source)
            }
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            let loadedItems = try await model.list(sourceID: sourceID, directory: path)
            // Filter out any items with empty paths as a safety measure
            items = loadedItems.filter { !$0.path.isEmpty }
        } catch {
            loadError = String(describing: error)
        }
        isLoading = false
    }
}

// MARK: - VideoPlayerSheet

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
            HStack {
                Text(item.name)
                    .font(.headline)
                Spacer()
                Button("Done") {
                    playerModel.cleanup()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            playerContent
        }
        .frame(width: 900, height: 600)
        .task {
            await playerModel.start()
        }
    }

    @ViewBuilder
    private var playerContent: some View {
        switch playerModel.phase {
        case .downloading(let progress):
            VStack(spacing: 16) {
                ProgressView(value: progress) {
                    Text("Downloading...")
                } currentValueLabel: {
                    Text("\(Int(progress * 100))%")
                }
                .progressViewStyle(.linear)
                .frame(width: 400)

                Text("Loading video from NAS...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .playing:
            if let url = playerModel.localURL {
                VideoPlayerView(url: url)
                    .frame(minWidth: 640, minHeight: 480)
            } else {
                ContentUnavailableView("Player Error", systemImage: "exclamationmark.triangle")
            }

        case .failed(let message):
            ContentUnavailableView {
                Label("Playback Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        }
    }
}

// MARK: - VideoPlayerView

/// AVPlayer wrapped in NSViewRepresentable for use in SwiftUI.
struct VideoPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

/// Navigation destination for browser entries.
struct BrowserDestination: Hashable, Identifiable {
    let sourceID: UUID
    let path: String
    let name: String

    var id: String { path }
}

/// Wrapper to safely handle navigation destination creation.
struct BrowserDestinationView: View {
    @EnvironmentObject var model: AppModel
    let destination: BrowserDestination

    var body: some View {
        SourceBrowserView(sourceID: destination.sourceID, path: destination.path)
    }
}
