import SwiftUI

struct PlaybackQueuePlayerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var queue: PlaybackQueueState
    @State private var startMode: PlaybackStartMode

    init(
        entries: [PlaybackQueueEntry],
        startIndex: Int = 0,
        startMode: PlaybackStartMode = .automatic,
        autoplayEnabled: Bool = true
    ) {
        _queue = State(
            initialValue: PlaybackQueueState(
                entries: entries,
                startIndex: startIndex,
                autoplayEnabled: autoplayEnabled
            )
        )
        _startMode = State(initialValue: startMode)
    }

    var body: some View {
        if let current = queue.current,
           let source = model.source(id: current.sourceID) {
            let diagnostics = model.makePlaybackDiagnosticDependencies()
            VideoPlayerSheet(
                item: current.media,
                source: source.source,
                diagnosticRecorder: diagnostics.recorder,
                diagnosticContext: diagnostics.context,
                identityProvider: diagnostics.identityProvider,
                progressManager: diagnostics.progressManager,
                startMode: startMode,
                queuePosition: queue.positionLabel,
                autoplayEnabled: queue.autoplayEnabled,
                canGoPrevious: queue.canRetreat,
                canGoNext: queue.canAdvance,
                onPrevious: moveToPrevious,
                onNext: moveToNext,
                onToggleAutoplay: toggleAutoplay,
                onPlaybackEnded: playbackEnded
            )
            .id(current.id)
        } else {
            ContentUnavailableView {
                Label("Video Unavailable", systemImage: "film.slash")
            } description: {
                Text("The file source is no longer connected.")
            }
            .frame(
                minWidth: 760,
                idealWidth: 960,
                minHeight: 520,
                idealHeight: 640
            )
        }
    }

    private func moveToNext() {
        guard queue.advance() else { return }
        startMode = .automatic
    }

    private func moveToPrevious() {
        guard queue.retreat() else { return }
        startMode = .automatic
    }

    private func playbackEnded() {
        guard queue.autoplayEnabled else { return }
        moveToNext()
    }

    private func toggleAutoplay() {
        queue.toggleAutoplay()
    }
}
