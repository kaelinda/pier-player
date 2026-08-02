import MediaAccessibility
import SwiftUI

struct SubtitleOverlayView: View {
    let text: String?

    @ScaledMetric(relativeTo: .title3) private var baseFontSize = 20
    @State private var appearance = SubtitleAppearance.system

    var body: some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.system(
                    size: baseFontSize * appearance.relativeCharacterSize,
                    weight: .semibold
                ))
                .multilineTextAlignment(.center)
                .foregroundStyle(appearance.foregroundColor)
                .shadow(color: .black, radius: 2)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(appearance.backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(maxWidth: 760)
                .accessibilityLabel("Subtitles")
                .accessibilityValue(text)
                .onReceive(NotificationCenter.default.publisher(
                    for: SubtitleAppearance.settingsChangedNotification
                )) { _ in
                    appearance = .system
                }
        }
    }
}

struct SubtitleAppearance {
    let foregroundColor: Color
    let backgroundColor: Color
    let relativeCharacterSize: CGFloat

    static let settingsChangedNotification = Notification.Name(
        kMACaptionAppearanceSettingsChangedNotification as String
    )

    static var system: SubtitleAppearance {
        var foregroundBehavior = MACaptionAppearanceBehavior.useContentIfAvailable
        let foreground = MACaptionAppearanceCopyForegroundColor(
            .user,
            &foregroundBehavior
        ).takeRetainedValue()
        let foregroundOpacity = MACaptionAppearanceGetForegroundOpacity(.user, nil)

        var backgroundBehavior = MACaptionAppearanceBehavior.useContentIfAvailable
        let background = MACaptionAppearanceCopyBackgroundColor(
            .user,
            &backgroundBehavior
        ).takeRetainedValue()
        let backgroundOpacity = MACaptionAppearanceGetBackgroundOpacity(.user, nil)

        let relativeCharacterSize = MACaptionAppearanceGetRelativeCharacterSize(.user, nil)

        return SubtitleAppearance(
            foregroundColor: foregroundBehavior == .useValue
                ? Color(foreground).opacity(foregroundOpacity)
                : .white,
            backgroundColor: backgroundBehavior == .useValue
                ? Color(background).opacity(backgroundOpacity)
                : .black.opacity(0.62),
            relativeCharacterSize: max(0.5, relativeCharacterSize)
        )
    }
}
