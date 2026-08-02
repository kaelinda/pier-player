import CloudSyncKit
import DiagnosticsKit
import MediaSourceKit
import PlaybackCore
import SwiftUI

struct VideoPlayerSheet: View {
    let item: MediaSourceItem
    @StateObject private var playerModel: VideoPlayerModel
    @Environment(\.dismiss) private var dismiss
    private let onStopped: @MainActor @Sendable () -> Void
    private let activePlayback: ActivePlaybackLifecycle?
    private let sourceID: UUID?
    @State private var activePlaybackToken: UUID?

    @MainActor
    init(
        item: MediaSourceItem,
        source: any MediaSource,
        diagnosticRecorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        diagnosticContext: DiagnosticContext? = nil,
        identityProvider: (any DiagnosticIdentityProviding)? = nil,
        progressManager: (any PlaybackProgressManaging)? = nil,
        historyStore: (any PlaybackHistoryStoring)? = nil,
        sourceDisplayName: String? = nil,
        activePlayback: ActivePlaybackLifecycle? = nil,
        onStopped: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.item = item
        self.onStopped = onStopped
        self.activePlayback = activePlayback
        self.sourceID = source.id
        _playerModel = StateObject(
            wrappedValue: VideoPlayerModel(
                item: item,
                source: source,
                diagnosticRecorder: diagnosticRecorder,
                diagnosticContext: diagnosticContext,
                identityProvider: identityProvider,
                progressManager: progressManager,
                historyStore: historyStore,
                sourceDisplayName: sourceDisplayName
            )
        )
    }

    init(
        item: MediaSourceItem,
        playerModel: VideoPlayerModel,
        onStopped: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.item = item
        self.onStopped = onStopped
        self.activePlayback = nil
        self.sourceID = nil
        _playerModel = StateObject(wrappedValue: playerModel)
    }

    var body: some View {
        ZStack {
            playerStage

            VStack(spacing: 0) {
                playerHeader
                Spacer(minLength: 0)
                PlaybackControlsView(model: playerModel)
            }
        }
        .frame(minWidth: 760, idealWidth: 960, minHeight: 520, idealHeight: 640)
        .background(Color.black)
        .tint(PierPlayerTheme.accent)
        .environment(\.colorScheme, .dark)
        .task {
            await playerModel.start()
        }
        .onAppear {
            guard let activePlayback, let sourceID else { return }
            activePlaybackToken = activePlayback.register(
                sourceID: sourceID,
                stop: { [weak playerModel] in
                    guard let playerModel else { return }
                    await playerModel.stop()
                },
                forcePersist: { [weak playerModel] in
                    guard let playerModel else { return }
                    await playerModel.forcePersistProgress()
                }
            )
        }
        .onDisappear {
            Task {
                if let activePlayback, let activePlaybackToken {
                    await activePlayback.stop(token: activePlaybackToken)
                } else {
                    await playerModel.stop()
                }
                onStopped()
            }
        }
        .onChange(of: playerModel.snapshot.failure) { _, failure in
            guard let failure else { return }
            let presentation = PlayerFailurePresentation(failure: failure)
            AccessibilityAnnouncement.post(
                "\(presentation.title). \(presentation.message)"
            )
        }
    }

    private var playerHeader: some View {
        HStack(spacing: 11) {
            Image(systemName: "film.fill")
                .foregroundStyle(PierPlayerTheme.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(metadataLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)
            statusLabel

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(PlayerChromeButtonStyle())
            .help("Close Player")
            .accessibilityLabel("Close Player")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var playerStage: some View {
        ZStack {
            VideoSurfaceView(displayLayer: playerModel.renderer.displayLayer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            SubtitleOverlayView(text: playerModel.snapshot.subtitleText)
                .padding(.horizontal, 24)
                .padding(.bottom, 104)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            stateOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipped()
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch playerModel.snapshot.state {
        case .connecting, .opening, .buffering, .reconnecting:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text(stateTitle)
                    .font(.callout.weight(.medium))
            }
            .foregroundStyle(.white)
            .padding(14)
            .background(.black.opacity(0.68))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .failed:
            PlayerFailureView(
                presentation: PlayerFailurePresentation(
                    failure: playerModel.snapshot.failure
                ),
                retry: {
                    Task { await playerModel.retry() }
                }
            )
        default:
            EmptyView()
        }
    }

    private var statusLabel: some View {
        Label(stateTitle, systemImage: statusIcon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private var metadataLabel: String {
        var values: [String] = []
        if let size = item.size {
            values.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        switch playerModel.snapshot.videoDecoderMode {
        case .videoToolbox: values.append("Hardware Decode")
        case .software: values.append("Software Decode")
        case .none: break
        }
        return values.joined(separator: " | ")
    }

    private var stateTitle: String {
        switch playerModel.snapshot.state {
        case .idle: "Ready"
        case .connecting: "Connecting"
        case .opening: "Opening"
        case .buffering(.initial): "Buffering"
        case .buffering(.seek): "Seeking"
        case .buffering(.recovery): "Recovering"
        case .buffering(.underrun): "Buffering"
        case .playing: "Playing"
        case .paused: "Paused"
        case .reconnecting: "Reconnecting"
        case .ended: "Ended"
        case .failed: "Playback Failed"
        }
    }

    private var statusIcon: String {
        switch playerModel.snapshot.state {
        case .playing: "play.fill"
        case .paused: "pause.fill"
        case .ended: "checkmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        default: "arrow.triangle.2.circlepath"
        }
    }
}

private struct PlayerFailureView: View {
    let presentation: PlayerFailurePresentation
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: presentation.systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(presentation.title)
                .font(.headline)
            Text(presentation.message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if presentation.canRetry {
                Button(action: retry) {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }

            DisclosureGroup("Technical Details") {
                Text(presentation.technicalDetails)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.62))
                    .textSelection(.enabled)
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: 360, alignment: .leading)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 480)
    }
}
