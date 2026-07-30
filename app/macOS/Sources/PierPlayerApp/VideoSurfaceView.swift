import AVFoundation
import AppKit
import SwiftUI

struct VideoSurfaceView: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> VideoSurfaceHostView {
        VideoSurfaceHostView(displayLayer: displayLayer)
    }

    func updateNSView(_ nsView: VideoSurfaceHostView, context: Context) {
        nsView.attach(displayLayer)
    }
}

final class VideoSurfaceHostView: NSView {
    private weak var displayLayer: AVSampleBufferDisplayLayer?

    init(displayLayer: AVSampleBufferDisplayLayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        attach(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(_ displayLayer: AVSampleBufferDisplayLayer) {
        guard self.displayLayer !== displayLayer else { return }
        self.displayLayer?.removeFromSuperlayer()
        self.displayLayer = displayLayer
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        displayLayer?.frame = bounds
    }
}
