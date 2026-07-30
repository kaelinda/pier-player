import AppKit
import PlaybackCore
import SwiftUI

struct PlaybackControlsView: View {
    @ObservedObject var model: VideoPlayerModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(timeLabel(model.position))
                    .frame(width: 54, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { model.position },
                        set: { model.updateScrubPosition($0) }
                    ),
                    in: 0...max(model.snapshot.duration, 0.01),
                    onEditingChanged: scrubStateChanged
                )
                .accessibilityLabel("Playback Position")
                Text(timeLabel(model.snapshot.duration))
                    .frame(width: 54, alignment: .leading)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    Task { await model.togglePlayback() }
                } label: {
                    Image(systemName: model.snapshot.intendsToPlay ? "pause.fill" : "play.fill")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(model.snapshot.intendsToPlay ? "Pause" : "Play")
                .accessibilityLabel(model.snapshot.intendsToPlay ? "Pause" : "Play")

                Button {
                    model.toggleMute()
                } label: {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(model.isMuted ? "Unmute" : "Mute")
                .accessibilityLabel(model.isMuted ? "Unmute" : "Mute")

                Slider(
                    value: Binding(
                        get: { model.volume },
                        set: { model.setVolume($0) }
                    ),
                    in: 0...1
                )
                .frame(width: 92)
                .accessibilityLabel("Volume")

                Spacer(minLength: 8)

                trackMenu(
                    title: "Audio",
                    icon: "waveform",
                    tracks: model.audioTracks,
                    includesOff: false
                ) { index in
                    guard let index else { return }
                    Task { await model.selectAudioTrack(index) }
                }

                trackMenu(
                    title: "Subtitles",
                    icon: "captions.bubble",
                    tracks: model.subtitleTracks,
                    includesOff: true
                ) { index in
                    Task { await model.selectSubtitleTrack(index) }
                }

                Button {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Toggle Full Screen")
                .accessibilityLabel("Toggle Full Screen")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 74)
        .background(.bar)
    }

    private func scrubStateChanged(_ editing: Bool) {
        if editing {
            model.beginScrubbing()
        } else {
            Task { await model.endScrubbing() }
        }
    }

    private func trackMenu(
        title: String,
        icon: String,
        tracks: [PlaybackTrack],
        includesOff: Bool,
        selection: @escaping (Int?) -> Void
    ) -> some View {
        Menu {
            if includesOff {
                Button("Off") { selection(nil) }
            }
            ForEach(tracks) { track in
                Button {
                    selection(track.index)
                } label: {
                    if track.isSelected {
                        Label(trackLabel(track), systemImage: "checkmark")
                    } else {
                        Text(trackLabel(track))
                    }
                }
            }
        } label: {
            Label(title, systemImage: icon)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(tracks.isEmpty && !includesOff)
    }

    private func trackLabel(_ track: PlaybackTrack) -> String {
        track.title ?? track.language?.uppercased() ?? track.codecName.uppercased()
    }

    private func timeLabel(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let seconds = Int(time.rounded(.down))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
