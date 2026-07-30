import MediaSourceKit
import PlaybackCore
import SwiftUI

struct VideoPlayerSheet: View {
    let item: MediaSourceItem
    @StateObject private var playerModel: VideoPlayerModel
    @Environment(\.dismiss) private var dismiss

    @MainActor
    init(item: MediaSourceItem, source: any MediaSource) {
        self.item = item
        _playerModel = StateObject(
            wrappedValue: VideoPlayerModel(item: item, source: source)
        )
    }

    init(item: MediaSourceItem, playerModel: VideoPlayerModel) {
        self.item = item
        _playerModel = StateObject(wrappedValue: playerModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            playerHeader
            Divider()
            playerStage
            Divider()
            PlaybackControlsView(model: playerModel)
        }
        .frame(minWidth: 760, idealWidth: 960, minHeight: 520, idealHeight: 640)
        .background(Color.black)
        .task {
            await playerModel.start()
        }
        .onDisappear {
            Task { await playerModel.stop() }
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

    private var playerStage: some View {
        ZStack(alignment: .bottom) {
            VideoSurfaceView(displayLayer: playerModel.renderer.displayLayer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            SubtitleOverlayView(text: playerModel.snapshot.subtitleText)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)

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
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .failed(let message):
            PlayerFailureView(message: message)
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
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("Playback Failed")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 480)
    }
}
