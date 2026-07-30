import SMBSourceKit
import SwiftUI

enum SidebarDestination: Hashable {
    case library
    case source(UUID)

    func reconciled(with sourceIDs: [UUID]) -> SidebarDestination {
        switch self {
        case .library:
            return .library
        case let .source(sourceID):
            return sourceIDs.contains(sourceID) ? self : .library
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isAddingSource = false
    @State private var selectedDestination: SidebarDestination? = .library

    var body: some View {
        NavigationSplitView {
            sourceSidebar
                .navigationTitle("Pier Player")
        } detail: {
            detailContent
        }
        .navigationSplitViewColumnWidth(min: 224, ideal: 252, max: 320)
        .sheet(isPresented: $isAddingSource) {
            AddSMBSourceView(model: model)
        }
        .onChange(of: model.sources.map(\.id), initial: true) { _, sourceIDs in
            selectedDestination = destination.reconciled(with: sourceIDs)
        }
    }

    private var sourceSidebar: some View {
        List(selection: $selectedDestination) {
            Section("Library") {
                Label("Media Library", systemImage: "rectangle.stack.fill")
                    .tag(SidebarDestination.library)
            }

            Section("File Sources") {
                if model.isRestoring {
                    restoringRow
                } else if model.sources.isEmpty {
                    emptySourcesRow
                } else {
                    ForEach(model.sources) { source in
                        SourceSidebarRow(source: source)
                            .tag(SidebarDestination.source(source.id))
                            .contextMenu {
                                Button(role: .destructive) {
                                    removeSource(source.id)
                                } label: {
                                    Label("Remove Source", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarFooter
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch destination {
        case .library:
            MediaLibraryView(
                destination: destinationBinding,
                addSource: { isAddingSource = true }
            )
        case let .source(sourceID) where model.source(id: sourceID) != nil:
            NavigationStack {
                SourceBrowserView(sourceID: sourceID, path: "/")
            }
            .id(sourceID)
        case .source:
            MediaLibraryView(
                destination: destinationBinding,
                addSource: { isAddingSource = true }
            )
        }
    }

    private var destination: SidebarDestination {
        selectedDestination ?? .library
    }

    private var destinationBinding: Binding<SidebarDestination> {
        Binding(
            get: { destination },
            set: { selectedDestination = $0 }
        )
    }

    private var restoringRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Restoring Sources")
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
    }

    private var emptySourcesRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.questionmark")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text("No Sources")
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 32)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(model.sources.isEmpty ? Color.secondary : Color.green)
                .frame(width: 7, height: 7)

            Text(sourceCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                isAddingSource = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Add SMB Source")
            .accessibilityLabel("Add SMB Source")
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var sourceCountLabel: String {
        switch model.sources.count {
        case 0: "Offline"
        case 1: "1 Source"
        default: "\(model.sources.count) Sources"
        }
    }

    private func removeSource(_ id: UUID) {
        Task {
            await model.removeSource(id: id)
        }
    }
}

private struct SourceSidebarRow: View {
    let source: AppModel.ConnectedSource

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.teal.opacity(0.14))
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.teal)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(source.configuration.host)/\(source.configuration.share)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
