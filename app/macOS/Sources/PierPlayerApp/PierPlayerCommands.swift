import SwiftUI

private struct AddSMBSourceActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct RefreshMediaLibraryActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ClearPlaybackHistoryActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var addSMBSourceAction: (() -> Void)? {
        get { self[AddSMBSourceActionKey.self] }
        set { self[AddSMBSourceActionKey.self] = newValue }
    }

    var refreshMediaLibraryAction: (() -> Void)? {
        get { self[RefreshMediaLibraryActionKey.self] }
        set { self[RefreshMediaLibraryActionKey.self] = newValue }
    }

    var clearPlaybackHistoryAction: (() -> Void)? {
        get { self[ClearPlaybackHistoryActionKey.self] }
        set { self[ClearPlaybackHistoryActionKey.self] = newValue }
    }
}

struct PierPlayerCommands: Commands {
    @FocusedValue(\.addSMBSourceAction) private var addSMBSource
    @FocusedValue(\.refreshMediaLibraryAction) private var refreshMediaLibrary
    @FocusedValue(\.clearPlaybackHistoryAction) private var clearPlaybackHistory

    var body: some Commands {
        CommandMenu("Library") {
            Button("Add Source") {
                addSMBSource?()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(addSMBSource == nil)

            Button("Refresh Media Library") {
                refreshMediaLibrary?()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(refreshMediaLibrary == nil)

            Divider()

            Button("Clear Playback History") {
                clearPlaybackHistory?()
            }
            .disabled(clearPlaybackHistory == nil)
        }
    }
}
