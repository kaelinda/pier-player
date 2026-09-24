import SwiftUI

enum MediaLibraryDesign {
    static let cardCornerRadius: CGFloat = 8
    static let recentCardWidth: CGFloat = 248
    static let recentArtworkHeight: CGFloat = 140
    static let sourceCardWidth: CGFloat = 220
    static let sourceCardHeight: CGFloat = 78
    static let hoverAnimationDuration = 0.16
}

struct MediaLibrarySection<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            content
        }
    }
}

struct RecentMediaCard: View {
    let item: MediaLibraryItem
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                MediaArtwork(item: item)
                    .frame(
                        width: MediaLibraryDesign.recentCardWidth,
                        height: MediaLibraryDesign.recentArtworkHeight
                    )
                    .shadow(
                        color: .black.opacity(isHovering ? 0.16 : 0),
                        radius: isHovering ? 10 : 4,
                        y: isHovering ? 5 : 2
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: MediaLibraryDesign.cardCornerRadius,
                            style: .continuous
                        )
                        .strokeBorder(
                            borderColor,
                            lineWidth: isFocused ? 2 : 1
                        )
                    }
                    .overlay {
                        if isHovering {
                            playOverlay
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                    }

                mediaLabels
            }
            .frame(width: MediaLibraryDesign.recentCardWidth, alignment: .leading)
        }
        .buttonStyle(MediaCardButtonStyle())
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .offset(y: isHovering ? -2 : 0)
        .scaleEffect(isHovering ? 1.012 : 1)
        .animation(
            reduceMotion
                ? nil
                : .easeOut(duration: MediaLibraryDesign.hoverAnimationDuration),
            value: isHovering
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the video player")
    }

    private var mediaLabels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(MediaLibraryPresentation.displayTitle(for: item))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(item.sourceName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var borderColor: Color {
        isFocused
            ? .accentColor
            : Color.primary.opacity(isHovering ? 0.24 : 0.12)
    }

    private var playOverlay: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(.black.opacity(0.62), in: Circle())
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        "\(MediaLibraryPresentation.displayTitle(for: item)), \(item.sourceName)"
    }
}

struct PosterMediaCard: View {
    let item: MediaLibraryItem
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                MediaArtwork(item: item)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .shadow(
                        color: .black.opacity(isHovering ? 0.16 : 0),
                        radius: isHovering ? 10 : 4,
                        y: isHovering ? 5 : 2
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: MediaLibraryDesign.cardCornerRadius,
                            style: .continuous
                        )
                        .strokeBorder(
                            borderColor,
                            lineWidth: isFocused ? 2 : 1
                        )
                    }
                    .overlay {
                        if isHovering {
                            playOverlay
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(MediaLibraryPresentation.displayTitle(for: item))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.sourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MediaCardButtonStyle())
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .offset(y: isHovering ? -2 : 0)
        .scaleEffect(isHovering ? 1.012 : 1)
        .animation(
            reduceMotion
                ? nil
                : .easeOut(duration: MediaLibraryDesign.hoverAnimationDuration),
            value: isHovering
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the video player")
    }

    private var borderColor: Color {
        isFocused
            ? .accentColor
            : Color.primary.opacity(isHovering ? 0.24 : 0.12)
    }

    private var playOverlay: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(.black.opacity(0.62), in: Circle())
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        "\(MediaLibraryPresentation.displayTitle(for: item)), \(item.sourceName)"
    }
}

struct MediaSourceCard: View {
    let source: MediaLibrarySourceSummary
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(
                        cornerRadius: MediaLibraryDesign.cardCornerRadius,
                        style: .continuous
                    )
                    .fill(.quaternary)
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(source.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("Browse Files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(
                width: MediaLibraryDesign.sourceCardWidth,
                height: MediaLibraryDesign.sourceCardHeight
            )
            .background(
                .thinMaterial,
                in: RoundedRectangle(
                    cornerRadius: MediaLibraryDesign.cardCornerRadius,
                    style: .continuous
                )
            )
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
                    borderColor,
                    lineWidth: isFocused ? 2 : 1
                )
            }
        }
        .buttonStyle(MediaCardButtonStyle())
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .offset(y: isHovering ? -1 : 0)
        .animation(
            reduceMotion
                ? nil
                : .easeOut(duration: MediaLibraryDesign.hoverAnimationDuration),
            value: isHovering
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source.displayName)
        .accessibilityHint("Opens the file browser")
    }

    private var borderColor: Color {
        isFocused
            ? .accentColor
            : Color.primary.opacity(isHovering ? 0.22 : 0.1)
    }
}

private struct MediaCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.1),
                value: configuration.isPressed
            )
    }
}

struct MediaArtwork: View {
    let item: MediaLibraryItem

    private let symbols = [
        "film.fill",
        "play.rectangle.fill",
        "video.fill",
        "movieclapper.fill",
        "rectangle.stack.fill",
        "tv.fill",
    ]

    private let palettes: [(base: Color, accent: Color)] = [
        (Color(red: 0.08, green: 0.25, blue: 0.29), Color(red: 0.18, green: 0.66, blue: 0.63)),
        (Color(red: 0.25, green: 0.15, blue: 0.27), Color(red: 0.85, green: 0.42, blue: 0.55)),
        (Color(red: 0.15, green: 0.21, blue: 0.29), Color(red: 0.90, green: 0.72, blue: 0.36)),
        (Color(red: 0.26, green: 0.20, blue: 0.16), Color(red: 0.83, green: 0.48, blue: 0.29)),
        (Color(red: 0.12, green: 0.25, blue: 0.22), Color(red: 0.47, green: 0.71, blue: 0.43)),
        (Color(red: 0.25, green: 0.18, blue: 0.21), Color(red: 0.79, green: 0.46, blue: 0.39)),
        (Color(red: 0.18, green: 0.19, blue: 0.28), Color(red: 0.50, green: 0.65, blue: 0.85)),
        (Color(red: 0.24, green: 0.23, blue: 0.14), Color(red: 0.76, green: 0.70, blue: 0.36)),
    ]

    var body: some View {
        GeometryReader { proxy in
            let style = MediaLibraryPresentation.posterStyle(for: item)
            let palette = palettes[style.paletteIndex % palettes.count]

            ZStack {
                palette.base

                Rectangle()
                    .fill(palette.accent.opacity(0.72))
                    .frame(width: proxy.size.width * 1.45, height: proxy.size.height * 0.42)
                    .rotationEffect(.degrees(-16))
                    .offset(y: proxy.size.height * 0.23)

                Image(systemName: symbols[style.symbolIndex % symbols.count])
                    .font(.system(size: min(proxy.size.width, proxy.size.height) * 0.25, weight: .medium))
                    .foregroundStyle(.white.opacity(0.94))
                    .shadow(color: palette.base.opacity(0.42), radius: 3, y: 1)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: MediaLibraryDesign.cardCornerRadius,
                    style: .continuous
                )
            )
            .overlay(alignment: .bottomTrailing) {
                extensionBadge
                    .padding(8)
            }
        }
        .accessibilityHidden(true)
    }

    private var extensionBadge: some View {
        Text(fileExtension)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(.black.opacity(0.58))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var fileExtension: String {
        let value = (item.media.name as NSString).pathExtension.uppercased()
        return value.isEmpty ? "VIDEO" : value
    }
}
