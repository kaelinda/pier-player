import Foundation

public struct SubtitleTimeline: Sendable {
    public private(set) var isEnabled = false
    public private(set) var lastSeekTime: TimeInterval = 0
    private var cues: [SubtitleCue] = []

    public init() {}

    public mutating func select(_ cues: [SubtitleCue]?) {
        guard let cues else {
            self.cues = []
            isEnabled = false
            return
        }
        self.cues = cues.sorted {
            $0.startTime == $1.startTime
                ? $0.endTime < $1.endTime
                : $0.startTime < $1.startTime
        }
        isEnabled = true
    }

    public mutating func seek(to time: TimeInterval) {
        lastSeekTime = time.isFinite ? max(0, time) : 0
    }

    public func activeCues(at time: TimeInterval) -> [SubtitleCue] {
        guard isEnabled, time.isFinite else { return [] }
        return cues.filter { $0.startTime <= time && time < $0.endTime }
    }
}
