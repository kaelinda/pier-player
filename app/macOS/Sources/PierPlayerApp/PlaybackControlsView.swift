import AppKit
import PlaybackCore
import SwiftUI

enum PlaybackControlCopy {
    static func timeLabel(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let roundedSeconds = time.rounded(.down)
        guard roundedSeconds < Double(Int.max) else { return "0:00" }
        let seconds = Int(roundedSeconds)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

struct PlaybackControlsView: View {
    @ObservedObject var model: VideoPlayerModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(PlaybackControlCopy.timeLabel(model.position))
                    .frame(width: 64, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { model.position },
                        set: { model.updateScrubPosition($0) }
                    ),
                    in: 0...max(model.snapshot.duration, 0.01),
                    onEditingChanged: scrubStateChanged
                )
                .accessibilityLabel("Playback Position")
                Text(PlaybackControlCopy.timeLabel(model.snapshot.duration))
                    .frame(width: 64, alignment: .leading)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.68))

            HStack(spacing: 12) {
                Button {
                    Task { await model.togglePlayback() }
                } label: {
                    Image(systemName: model.snapshot.intendsToPlay ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(PierPlayerTheme.accent.opacity(0.9), in: Circle())
                }
                .buttonStyle(PlayerChromeButtonStyle())
                .help(model.snapshot.intendsToPlay ? "Pause" : "Play")
                .accessibilityLabel(model.snapshot.intendsToPlay ? "Pause" : "Play")

                Button {
                    model.toggleMute()
                } label: {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(PlayerChromeButtonStyle())
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
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(PlayerChromeButtonStyle())
                .help("Toggle Full Screen")
                .accessibilityLabel("Toggle Full Screen")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 78)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
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
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(tracks.isEmpty && !includesOff)
    }

    private func trackLabel(_ track: PlaybackTrack) -> String {
        track.title ?? track.language?.uppercased() ?? track.codecName.uppercased()
    }
}

struct PlayerChromeButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.1),
                value: configuration.isPressed
            )
    }
}
