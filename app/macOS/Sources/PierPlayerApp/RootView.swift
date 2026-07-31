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
    @State private var sourceManagementSheet: SourceManagementSheet?

    var body: some View {
        NavigationSplitView {
            sourceSidebar
                .navigationTitle("Pier Player")
                .navigationSplitViewColumnWidth(min: 224, ideal: 252, max: 320)
        } detail: {
            detailContent
        }
        .sheet(isPresented: $isAddingSource) {
            AddSMBSourceView(model: model)
        }
        .sheet(item: $sourceManagementSheet) { sheet in
            switch sheet {
            case let .information(details):
                SourceInformationView(details: details)
            case let .edit(details):
                EditSMBSourceView(model: model, details: details)
            }
        }
        .onChange(of: model.sources.map(\.id), initial: true) { _, sourceIDs in
            selectedDestination = destination.reconciled(with: sourceIDs)
        }
    }

    private var sourceSidebar: some View {
        RootSidebarContent(
            sources: model.sources,
            isRestoring: model.isRestoring,
            selection: $selectedDestination,
            addSource: { isAddingSource = true },
            showSourceInformation: showSourceInformation,
            editSource: editSource,
            removeSource: removeSource
        )
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
            .id(SourceBrowserIdentity(
                sourceID: sourceID,
                sourceRevision: model.sourceRevision
            ))
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

    private func removeSource(_ id: UUID) {
        Task {
            await model.removeSource(id: id)
        }
    }

    private func showSourceInformation(_ id: UUID) {
        guard let source = model.source(id: id) else { return }
        sourceManagementSheet = .information(SMBSourceDetails(source: source))
    }

    private func editSource(_ id: UUID) {
        guard let source = model.source(id: id) else { return }
        sourceManagementSheet = .edit(SMBSourceDetails(source: source))
    }
}

private enum SourceManagementSheet: Identifiable {
    case information(SMBSourceDetails)
    case edit(SMBSourceDetails)

    var id: String {
        switch self {
        case let .information(details): "information-\(details.id)"
        case let .edit(details): "edit-\(details.id)"
        }
    }
}

private struct SourceBrowserIdentity: Hashable {
    let sourceID: UUID
    let sourceRevision: Int
}

struct RootSidebarContent: View {
    let sources: [AppModel.ConnectedSource]
    let isRestoring: Bool
    @Binding var selection: SidebarDestination?
    let addSource: () -> Void
    let showSourceInformation: (UUID) -> Void
    let editSource: (UUID) -> Void
    let removeSource: (UUID) -> Void

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("Media Library", systemImage: "rectangle.stack.fill")
                    .tag(SidebarDestination.library)
            }

            Section("File Sources") {
                if isRestoring {
                    restoringRow
                } else if sources.isEmpty {
                    emptySourcesRow
                } else {
                    ForEach(sources) { source in
                        SourceSidebarRow(source: source)
                            .tag(SidebarDestination.source(source.id))
                            .contextMenu {
                                Button {
                                    showSourceInformation(source.id)
                                } label: {
                                    Label(
                                        SourceManagementAction.information.title,
                                        systemImage: "info.circle"
                                    )
                                }

                                Button {
                                    editSource(source.id)
                                } label: {
                                    Label(
                                        SourceManagementAction.edit.title,
                                        systemImage: "pencil"
                                    )
                                }

                                Divider()

                                Button(role: .destructive) {
                                    removeSource(source.id)
                                } label: {
                                    Label(
                                        SourceManagementAction.remove.title,
                                        systemImage: "trash"
                                    )
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
        .accessibilityLabel("Pier Player Sidebar")
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
            Image(systemName: sources.isEmpty ? "externaldrive" : "externaldrive.connected.to.line.below")
                .font(.caption.weight(.medium))
                .foregroundStyle(sources.isEmpty ? Color.secondary : Color.teal)
                .frame(width: 16)

            Text(sourceCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                addSource()
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
        switch sources.count {
        case 0: "No Sources"
        case 1: "1 Source"
        default: "\(sources.count) Sources"
        }
    }
}

private struct SourceSidebarRow: View {
    let source: AppModel.ConnectedSource

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
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
