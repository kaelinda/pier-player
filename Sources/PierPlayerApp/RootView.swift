import SwiftUI

struct RootView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List {
                    Section("Sources") {
                        Label("No SMB sources", systemImage: "externaldrive")
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack {
                    Text(model.phaseLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .disabled(true)
                    .help("Add SMB Source")
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
            }
            .navigationTitle("Pier Player")
        } detail: {
            VStack(spacing: 0) {
                ContentUnavailableView(
                    "No Source Selected",
                    systemImage: "play.rectangle",
                    description: Text("Connect an SMB share to browse media.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                playbackControls
            }
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button {
            } label: {
                Image(systemName: "gobackward.10")
            }
            .help("Back 10 Seconds")

            Button {
            } label: {
                Image(systemName: "play.fill")
            }
            .help("Play")

            Slider(value: .constant(0), in: 0...1)
                .frame(minWidth: 180, idealWidth: 320, maxWidth: 520)

            Text("00:00")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)

            Button {
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .help("Audio")
        }
        .buttonStyle(.plain)
        .controlSize(.regular)
        .disabled(true)
        .padding(.horizontal, 18)
        .frame(height: 58)
    }
}
