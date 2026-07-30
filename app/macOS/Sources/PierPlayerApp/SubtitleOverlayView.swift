import SwiftUI

struct SubtitleOverlayView: View {
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.system(size: 20, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 2)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.black.opacity(0.62))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(maxWidth: 760)
                .accessibilityLabel("Subtitles")
                .accessibilityValue(text)
        }
    }
}
