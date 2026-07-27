import PlaybackCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: PlaybackSnapshot = .idle

    let playbackSession: PlaybackSession

    init(playbackSession: PlaybackSession = PlaybackSession()) {
        self.playbackSession = playbackSession
    }

    var phaseLabel: String {
        switch snapshot.state {
        case .idle: "Idle"
        case .connecting: "Connecting"
        case .opening: "Opening"
        case .buffering: "Buffering"
        case .playing: "Playing"
        case .paused: "Paused"
        case .reconnecting: "Reconnecting"
        case .ended: "Ended"
        case .failed: "Failed"
        }
    }
}
