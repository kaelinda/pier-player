import SwiftUI

struct PlaybackHistorySection: View {
    let title: String
    let items: [PlaybackHistoryItem]
    let play: (MediaLibraryItem) -> Void
    let playFromBeginning: (MediaLibraryItem) -> Void
    let remove: (String) -> Void

    var body: some View {
        MediaLibrarySection(title: title, count: items.count) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        PlaybackHistoryCard(
                            item: item,
                            play: play,
                            playFromBeginning: playFromBeginning,
                            remove: remove
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

struct PlaybackHistoryCard: View {
    let item: PlaybackHistoryItem
    let play: (MediaLibraryItem) -> Void
    let playFromBeginning: (MediaLibraryItem) -> Void
    let remove: (String) -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let media = item.media {
                Button {
                    play(media)
                } label: {
                    cardContent
                }
                .buttonStyle(MediaCardButtonStyle())
                .contextMenu { contextMenu(for: media) }
            } else {
                cardContent
                    .contextMenu { contextMenu(for: nil) }
            }
        }
        .frame(width: MediaLibraryDesign.historyCardWidth, alignment: .leading)
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .offset(y: isHovering ? -2 : 0)
        .scaleEffect(isHovering ? 1.012 : 1)
        .animation(
            reduceMotion ? nil : MediaLibraryDesign.hoverAnimation,
            value: isHovering
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(item.isUnavailable ? "Remove from history using the context menu" : "Opens the video player")
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            artwork
                .frame(
                    width: MediaLibraryDesign.historyCardWidth,
                    height: MediaLibraryDesign.historyArtworkHeight
                )
                .overlay(alignment: .bottom) {
                    progressBar
                }
                .overlay(alignment: .topTrailing) {
                    statusBadge
                        .padding(9)
                }
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MediaLibraryDesign.cardCornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: MediaLibraryDesign.cardCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(
                        isFocused
                            ? Color.accentColor
                            : Color.primary.opacity(isHovering ? 0.24 : 0.12),
                        lineWidth: isFocused ? 2 : 1
                    )
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.sourceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(statusText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(item.isUnavailable ? .orange : .secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let media = item.media {
            MediaArtwork(item: media)
                .overlay {
                    if isHovering {
                        Image(systemName: item.progress.isCompleted ? "arrow.counterclockwise" : "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 38, height: 38)
                            .background(.regularMaterial, in: Circle())
                            .overlay {
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.26))
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
        } else {
            ZStack {
                RoundedRectangle(
                    cornerRadius: MediaLibraryDesign.cardCornerRadius,
                    style: .continuous
                )
                .fill(.quaternary)
                Image(systemName: "film.slash")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: MediaLibraryDesign.cardCornerRadius,
                    style: .continuous
                )
                .fill(.black.opacity(0.08))
            }
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if !item.isUnavailable {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.black.opacity(0.38))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * item.fractionCompleted)
                }
                .frame(height: 4)
                .padding(.horizontal, 9)
                .padding(.bottom, 8)
            }
            .frame(height: 18)
        }
    }

    private var statusBadge: some View {
        Group {
            if item.isUnavailable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if item.progress.isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("\(item.percentageCompleted)%")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
        .frame(minWidth: 27, minHeight: 24)
        .padding(.horizontal, 5)
        .background(.black.opacity(0.54), in: Capsule())
        .accessibilityHidden(true)
    }

    private var statusText: String {
        if item.isUnavailable {
            return "Source unavailable"
        }
        if item.progress.isCompleted {
            return "Completed · Replay"
        }
        return "\(item.percentageCompleted)% · \(PlaybackHistoryPresentation.displayRemainingTime(item.remainingTime)) left"
    }

    @ViewBuilder
    private func contextMenu(for media: MediaLibraryItem?) -> some View {
        if let media {
            Button(item.progress.isCompleted ? "Replay" : "Continue Watching") {
                play(media)
            }
            Button("Play from Beginning") {
                playFromBeginning(media)
            }
            Divider()
        }
        Button("Remove from History", role: .destructive) {
            remove(item.id)
        }
    }

    private var accessibilityLabel: String {
        if item.isUnavailable {
            return "\(item.title), \(item.sourceName), unavailable"
        }
        if item.progress.isCompleted {
            return "\(item.title), completed, replay"
        }
        return "\(item.title), \(item.percentageCompleted)% complete, \(PlaybackHistoryPresentation.displayRemainingTime(item.remainingTime)) remaining"
    }
}
