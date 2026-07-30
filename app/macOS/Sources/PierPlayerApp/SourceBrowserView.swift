import AVKit
import DiagnosticsKit
import MediaSourceKit
import SMBSourceKit
import SwiftUI

@MainActor
final class VideoPlayerModel: ObservableObject {
    let item: MediaSourceItem
    let source: any MediaSource

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var player: AVPlayer?

    enum Phase: Equatable {
        case preparing
        case playing
        case failed(String)
    }

    private let sessionFactory: VideoPlaybackSessionFactory
    private let diagnosticRecorder: any DiagnosticRecording
    private let diagnosticContext: DiagnosticContext
    private let identityProvider: (any DiagnosticIdentityProviding)?
    private var activeDiagnosticPayload: DiagnosticPayload?
    private var playbackSession: (any VideoPlaybackSession)?

    init(
        item: MediaSourceItem,
        source: any MediaSource,
        diagnosticRecorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        diagnosticContext: DiagnosticContext? = nil,
        identityProvider: (any DiagnosticIdentityProviding)? = nil,
        sessionFactory: VideoPlaybackSessionFactory? = nil
    ) {
        let context = diagnosticContext ?? DiagnosticContext(
            appRunID: UUID(),
            activityID: UUID(),
            operationID: UUID()
        )
        self.item = item
        self.source = source
        self.diagnosticRecorder = diagnosticRecorder
        self.diagnosticContext = context
        self.identityProvider = identityProvider
        self.sessionFactory = sessionFactory ?? { file, fileName in
            try ProgressivePlaybackSession(
                file: file,
                fileName: fileName,
                diagnosticRecorder: diagnosticRecorder,
                diagnosticContext: context,
                identityProvider: identityProvider
            )
        }
    }

    func start() async {
        await stop()
        phase = .preparing
        let prepare = DiagnosticOperation(
            recorder: diagnosticRecorder,
            parentContext: diagnosticContext,
            name: .playbackPrepare,
            level: .info,
            payload: DiagnosticPayload(
                sourceID: source.id,
                container: DiagnosticContainerKind(fileName: item.name),
                fileSize: item.size
            ),
            persistence: .essential
        )

        do {
            let open = DiagnosticOperation(
                recorder: diagnosticRecorder,
                parentContext: diagnosticContext,
                name: .fileOpen,
                level: .info,
                payload: DiagnosticPayload(
                    sourceID: source.id,
                    container: DiagnosticContainerKind(fileName: item.name),
                    fileSize: item.size
                ),
                persistence: .essential
            )
            let file: any MediaReadableFile
            do {
                file = try await source.open(file: item.path)
            } catch {
                finishPlaybackOperation(open, error: error, payload: DiagnosticPayload(
                    sourceID: source.id,
                    container: DiagnosticContainerKind(fileName: item.name),
                    fileSize: item.size
                ))
                finishPlaybackOperation(prepare, error: error)
                throw error
            }
            let fileID = identityProvider?.fileIdentity(
                sourceID: file.identity.sourceID,
                normalizedPath: file.identity.path,
                size: file.identity.size,
                modifiedAt: file.identity.modifiedAt
            ).value
            let payload = DiagnosticPayload(
                sourceID: file.identity.sourceID,
                fileID: fileID,
                container: DiagnosticContainerKind(fileName: item.name),
                fileSize: file.identity.size
            )
            open.end(outcome: .success, payload: payload)

            let session: any VideoPlaybackSession
            do {
                try Task.checkCancellation()
                session = try sessionFactory(file, item.name)
            } catch {
                await file.close()
                recordPlaybackFileClose(payload: payload)
                finishPlaybackOperation(prepare, error: error, payload: payload)
                throw error
            }

            do {
                try Task.checkCancellation()
            } catch {
                await session.stop()
                finishPlaybackOperation(prepare, error: error, payload: payload)
                throw error
            }

            playbackSession = session
            activeDiagnosticPayload = payload
            player = session.player
            phase = .playing
            prepare.end(outcome: .success, payload: payload)
            diagnosticRecorder.record(.instant(
                level: .info,
                name: .playbackPlay,
                context: diagnosticContext.child(),
                outcome: .success,
                payload: payload,
                persistence: .essential
            ))
            session.play()
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    func stop() async {
        let session = playbackSession
        playbackSession = nil
        player = nil
        guard let session else { return }
        let payload = activeDiagnosticPayload ?? DiagnosticPayload(sourceID: source.id)
        activeDiagnosticPayload = nil
        let operation = DiagnosticOperation(
            recorder: diagnosticRecorder,
            parentContext: diagnosticContext,
            name: .playbackStop,
            level: .info,
            payload: payload,
            persistence: .essential
        )
        await session.stop()
        operation.end(outcome: .success, payload: payload)
    }

    private func recordPlaybackFileClose(payload: DiagnosticPayload) {
        let operation = DiagnosticOperation(
            recorder: diagnosticRecorder,
            parentContext: diagnosticContext,
            name: .fileClose,
            level: .info,
            payload: payload,
            persistence: .essential
        )
        operation.end(outcome: .success, payload: payload)
    }
}

private func finishPlaybackOperation(
    _ operation: DiagnosticOperation,
    error: Error,
    payload: DiagnosticPayload = DiagnosticPayload()
) {
    if error is CancellationError {
        operation.end(outcome: .cancelled, payload: payload)
    } else {
        operation.end(
            outcome: .failure,
            payload: payload,
            error: playbackDiagnosticDescriptor(for: error)
        )
    }
}

private func playbackDiagnosticDescriptor(for error: Error) -> DiagnosticErrorDescriptor {
    switch error {
    case ProgressivePlaybackError.unsupportedContainer:
        DiagnosticErrorDescriptor(code: .playerUnsupportedContainer)
    case ProgressivePlaybackError.invalidLoadingRequest:
        DiagnosticErrorDescriptor(code: .playerInvalidLoadingRequest)
    case ProgressivePlaybackError.resourceLoaderClosed:
        DiagnosticErrorDescriptor(code: .playerResourceLoaderClosed)
    case MediaSourceError.notConnected:
        DiagnosticErrorDescriptor(code: .sourceNotConnected, isRetryable: true)
    case MediaSourceError.authenticationFailed:
        DiagnosticErrorDescriptor(code: .sourceAuthenticationFailed)
    case MediaSourceError.unreachable:
        DiagnosticErrorDescriptor(code: .sourceUnreachable, isRetryable: true)
    case MediaSourceError.notFound:
        DiagnosticErrorDescriptor(code: .sourceNotFound)
    case MediaSourceError.invalidRead:
        DiagnosticErrorDescriptor(code: .sourceInvalidRead)
    case MediaSourceError.readFailed:
        DiagnosticErrorDescriptor(code: .sourceReadFailed, isRetryable: true)
    case MediaSourceError.remoteFileChanged:
        DiagnosticErrorDescriptor(code: .sourceRemoteFileChanged)
    case MediaSourceError.unsupported:
        DiagnosticErrorDescriptor(code: .sourceUnsupported)
    default:
        DiagnosticErrorDescriptor(code: .playerFailed)
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
        } else if isPlayableVideo(item) {
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

    private func isPlayableVideo(_ item: MediaSourceItem) -> Bool {
        item.kind == .file && AVFoundationMediaType(fileName: item.name) != nil
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
        if isPlayableVideo { return "film.fill" }
        return "doc.fill"
    }

    private var iconColor: Color {
        if item.kind == .directory { return .teal }
        if isPlayableVideo { return .orange }
        return .secondary
    }

    private var kindLabel: String {
        if item.kind == .directory { return "Folder" }
        let fileExtension = (item.name as NSString).pathExtension.uppercased()
        guard !fileExtension.isEmpty else { return "File" }
        return isPlayableVideo ? "\(fileExtension) Video" : "\(fileExtension) File"
    }

    private var isPlayableVideo: Bool {
        item.kind == .file && AVFoundationMediaType(fileName: item.name) != nil
    }

    private var sizeLabel: String? {
        guard item.kind == .file, let size = item.size else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct VideoPlayerSheet: View {
    let item: MediaSourceItem
    let source: any MediaSource

    @StateObject private var playerModel: VideoPlayerModel
    @Environment(\.dismiss) private var dismiss

    init(
        item: MediaSourceItem,
        source: any MediaSource,
        diagnosticRecorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        diagnosticContext: DiagnosticContext? = nil,
        identityProvider: (any DiagnosticIdentityProviding)? = nil
    ) {
        self.item = item
        self.source = source
        _playerModel = StateObject(wrappedValue: VideoPlayerModel(
            item: item,
            source: source,
            diagnosticRecorder: diagnosticRecorder,
            diagnosticContext: diagnosticContext,
            identityProvider: identityProvider
        ))
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
            Task {
                await playerModel.stop()
            }
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
        case .preparing:
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
                    Text("Opening the remote media stream")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.62))
                }

                ProgressView()
                    .controlSize(.regular)
                    .tint(.teal)
                    .accessibilityLabel("Opening Video")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .black))

        case .playing:
            if let player = playerModel.player {
                VideoPlayerView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            } else {
                PlayerFailureView(message: "The local video could not be opened.")
            }

        case .failed(let message):
            PlayerFailureView(message: message)
        }
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
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player = nil
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
