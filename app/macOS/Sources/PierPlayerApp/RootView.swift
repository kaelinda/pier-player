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
    @State private var pendingSourceRemoval: SourceRemovalRequest?
    @State private var sourceRemovalError: SourceRemovalErrorPresentation?

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
        .confirmationDialog(
            pendingSourceRemoval?.title ?? "Remove Source?",
            isPresented: sourceRemovalConfirmationPresented,
            titleVisibility: .visible,
            presenting: pendingSourceRemoval
        ) { request in
            Button("Remove Source", role: .destructive) {
                removeSource(request)
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
        .alert(item: $sourceRemovalError) { error in
            Alert(
                title: Text("Could Not Remove Source"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onChange(of: model.configuredSources.map(\.id), initial: true) { _, sourceIDs in
            selectedDestination = destination.reconciled(with: sourceIDs)
        }
    }

    private var sourceSidebar: some View {
        RootSidebarContent(
            sources: model.configuredSources,
            isRestoring: model.isRestoring,
            selection: $selectedDestination,
            addSource: { isAddingSource = true },
            showSourceInformation: showSourceInformation,
            editSource: editSource,
            removeSource: requestSourceRemoval
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
        case let .source(sourceID):
            ContentUnavailableView {
                Label("Credentials Required", systemImage: "lock.fill")
            } description: {
                Text("Enter the SMB username and password for this device.")
            } actions: {
                Button("Reconnect") { editSource(sourceID) }
            }
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

    private var sourceRemovalConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingSourceRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    pendingSourceRemoval = nil
                }
            }
        )
    }

    private func requestSourceRemoval(_ id: UUID) {
        guard let source = model.configuredSource(id: id) else { return }
        pendingSourceRemoval = SourceRemovalRequest(
            id: source.id,
            displayName: source.displayName
        )
    }

    private func removeSource(_ request: SourceRemovalRequest) {
        Task {
            do {
                try await model.removeSource(id: request.id)
            } catch {
                sourceRemovalError = SourceRemovalErrorPresentation(
                    message: AppModel.connectionErrorMessage(for: error)
                )
            }
        }
    }

    private func showSourceInformation(_ id: UUID) {
        guard let source = model.configuredSource(id: id) else { return }
        sourceManagementSheet = .information(SMBSourceDetails(source: source))
    }

    private func editSource(_ id: UUID) {
        guard let source = model.configuredSource(id: id) else { return }
        sourceManagementSheet = .edit(SMBSourceDetails(source: source))
    }
}

struct SourceRemovalRequest: Identifiable, Equatable {
    let id: UUID
    let displayName: String

    var title: String { "Remove \"\(displayName)\"?" }

    var message: String {
        "Pier Player will disconnect this source and remove its saved credentials. "
            + "Media files on the server will not be deleted."
    }
}

private struct SourceRemovalErrorPresentation: Identifiable {
    let id = UUID()
    let message: String
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
    let sources: [AppModel.ConfiguredSource]
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
                .foregroundStyle(sources.isEmpty ? Color.secondary : PierPlayerTheme.accent)
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
    let source: AppModel.ConfiguredSource

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(PierPlayerTheme.accent.opacity(0.14))
                Image(systemName: source.connectionState == .connected
                    ? "externaldrive.connected.to.line.below"
                    : "externaldrive.badge.person.crop")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PierPlayerTheme.accent)
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
                if source.connectionState == .needsCredential {
                    Text("Credentials Required")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
