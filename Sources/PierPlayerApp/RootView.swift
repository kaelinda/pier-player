import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Label("Sources", systemImage: "externaldrive.connected.to.line.below")
            }
            .navigationTitle("Pier Player")
        } detail: {
            ContentUnavailableView(
                "Playback Foundation",
                systemImage: "play.rectangle",
                description: Text("SMB and playback adapters are not connected yet.")
            )
        }
    }
}
