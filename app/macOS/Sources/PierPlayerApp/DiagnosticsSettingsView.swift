import AppKit
import DiagnosticsKit
import SwiftUI
import UniformTypeIdentifiers

enum DiagnosticsSettingsCopy {
    static let detailedDiagnostics = "Detailed Diagnostics"
    static let storageUsage = "Storage Usage"
    static let recentSessions = "Recent Sessions"
    static let export = "Export"
    static let reveal = "Reveal in Finder"
    static let clear = "Clear History"
}

extension UTType {
    static let pierDiagnosticBundle = UTType(
        exportedAs: "app.pier-player.diagnostics",
        conformingTo: .package
    )
}

struct DiagnosticBundleDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.pierDiagnosticBundle]

    let entries: [String: Data]

    init(fileWrapper: FileWrapper) throws {
        guard let wrappers = fileWrapper.fileWrappers else {
            throw CocoaError(.fileReadCorruptFile)
        }
        entries = try wrappers.mapValues { wrapper in
            guard let data = wrapper.regularFileContents else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return data
        }
    }

    init(configuration: ReadConfiguration) throws {
        try self.init(fileWrapper: configuration.file)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(directoryWithFileWrappers: entries.mapValues(
            FileWrapper.init(regularFileWithContents:)
        ))
    }
}

struct DiagnosticsSettingsView: View {
    @ObservedObject var viewModel: DiagnosticsViewModel
    let diagnosticsDirectory: URL

    @State private var now = Date()
    @State private var isConfirmingClear = false
    @State private var isPresentingExporter = false
    @State private var exportDocument: DiagnosticBundleDocument?
    @State private var operationError: DiagnosticsSettingsOperationError?

    var body: some View {
        DiagnosticsSettingsContentView(
            snapshot: viewModel.snapshot,
            now: now,
            selectedRunIDs: $viewModel.selectedRunIDs,
            isExporting: viewModel.isExporting,
            setDetailedEnabled: setDetailedEnabled,
            export: prepareExport,
            reveal: revealDiagnostics,
            clear: { isConfirmingClear = true }
        )
        .frame(width: 520, height: 560)
        .task {
            await viewModel.start()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
        .confirmationDialog(
            "Clear Diagnostic History?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Closed Sessions", role: .destructive) {
                Task { await viewModel.clearHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current session remains active.")
        }
        .fileExporter(
            isPresented: $isPresentingExporter,
            document: exportDocument,
            contentType: .pierDiagnosticBundle,
            defaultFilename: "Pier-Diagnostics.pierdiag"
        ) { result in
            if case .failure = result {
                operationError = .exportFailed
            }
            exportDocument = nil
        }
        .alert(item: $operationError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func setDetailedEnabled(_ enabled: Bool) {
        Task { await viewModel.setDetailedEnabled(enabled) }
    }

    private func revealDiagnostics() {
        NSWorkspace.shared.activateFileViewerSelecting([diagnosticsDirectory])
    }

    private func prepareExport() {
        Task {
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
                "pier-diagnostics-\(UUID().uuidString).pierdiag",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: destination) }
            do {
                try await viewModel.exportSelectedRuns(to: destination)
                let wrapper = try FileWrapper(url: destination, options: .immediate)
                exportDocument = try DiagnosticBundleDocument(fileWrapper: wrapper)
                isPresentingExporter = true
            } catch {
                operationError = .exportFailed
            }
        }
    }
}

struct DiagnosticsSettingsContentView: View {
    let snapshot: DiagnosticStatusSnapshot
    let now: Date
    @Binding var selectedRunIDs: Set<UUID>
    let isExporting: Bool
    let setDetailedEnabled: @MainActor @Sendable (Bool) -> Void
    let export: @MainActor @Sendable () -> Void
    let reveal: @MainActor @Sendable () -> Void
    let clear: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            statusHeader
            detailedControl
            storageSection
            warningSection
            recentRunsSection
            commandRow
        }
        .padding(22)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: modeIcon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(modeColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local Diagnostics")
                    .font(.title3.weight(.semibold))
                Text(modeLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(modeBadge)
                .font(.caption.weight(.semibold))
                .foregroundStyle(modeColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Diagnostics Mode: \(modeBadge)")
    }

    private var detailedControl: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(DiagnosticsSettingsCopy.detailedDiagnostics)
                    .font(.body.weight(.medium))
                if let remainingLabel {
                    Text(remainingLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Toggle(
                DiagnosticsSettingsCopy.detailedDiagnostics,
                isOn: Binding(
                    get: { snapshot.detailedUntil != nil },
                    set: { setDetailedEnabled($0) }
                )
            )
            .labelsHidden()
            .accessibilityLabel(DiagnosticsSettingsCopy.detailedDiagnostics)
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(DiagnosticsSettingsCopy.storageUsage)
                    .font(.body.weight(.medium))
                Spacer()
                Text(storageLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: storageFraction)
                .accessibilityLabel(DiagnosticsSettingsCopy.storageUsage)
                .accessibilityValue(storageLabel)
        }
    }

    @ViewBuilder
    private var warningSection: some View {
        if let warningLabel {
            Label(warningLabel, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
        }
    }

    private var recentRunsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DiagnosticsSettingsCopy.recentSessions)
                .font(.body.weight(.medium))
            if snapshot.recentRuns.isEmpty {
                ContentUnavailableView(
                    "No Recorded Sessions",
                    systemImage: "waveform.path.ecg"
                )
                .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                List(selection: $selectedRunIDs) {
                    ForEach(snapshot.recentRuns, id: \.runID) { run in
                        DiagnosticRunRow(run: run)
                            .tag(run.runID)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 170)
                .accessibilityLabel(DiagnosticsSettingsCopy.recentSessions)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var commandRow: some View {
        HStack(spacing: 8) {
            Button(action: export) {
                Label(DiagnosticsSettingsCopy.export, systemImage: "square.and.arrow.up")
            }
            .disabled(selectedRunIDs.isEmpty || isExporting)
            .help("Export Selected Diagnostics")
            .accessibilityLabel(DiagnosticsSettingsCopy.export)

            Button(action: reveal) {
                Label(DiagnosticsSettingsCopy.reveal, systemImage: "folder")
            }
            .help(DiagnosticsSettingsCopy.reveal)
            .accessibilityLabel(DiagnosticsSettingsCopy.reveal)

            Spacer()

            Button(role: .destructive, action: clear) {
                Label(DiagnosticsSettingsCopy.clear, systemImage: "trash")
            }
            .disabled(!snapshot.recentRuns.contains { $0.endedAt != nil })
            .help(DiagnosticsSettingsCopy.clear)
            .accessibilityLabel(DiagnosticsSettingsCopy.clear)
        }
    }

    private var storageFraction: Double {
        min(
            1,
            max(0, Double(snapshot.storageBytes) / Double(DiagnosticsViewModel.maximumStorageBytes))
        )
    }

    private var storageLabel: String {
        let used = ByteCountFormatter.string(fromByteCount: snapshot.storageBytes, countStyle: .file)
        let maximum = ByteCountFormatter.string(
            fromByteCount: DiagnosticsViewModel.maximumStorageBytes,
            countStyle: .file
        )
        return "\(used) of \(maximum)"
    }

    private var remainingLabel: String? {
        guard let deadline = snapshot.detailedUntil else { return nil }
        let remaining = max(0, Int(deadline.timeIntervalSince(now)))
        return "\(remaining / 60)m \(remaining % 60)s remaining"
    }

    private var modeLabel: String {
        switch snapshot.policy {
        case .standard:
            "Essential events"
        case .detailed:
            "Detailed capture active"
        case .incident:
            "Incident capture active"
        }
    }

    private var modeBadge: String {
        switch snapshot.policy {
        case .standard: "Standard"
        case .detailed: "Detailed"
        case .incident: "Incident"
        }
    }

    private var modeIcon: String {
        snapshot.policy == .incident ? "exclamationmark.triangle.fill" : "waveform.path.ecg"
    }

    private var modeColor: Color {
        switch snapshot.policy {
        case .standard: PierPlayerTheme.accent
        case .detailed: .blue
        case .incident: .orange
        }
    }

    private var warningLabel: String? {
        switch snapshot.warning {
        case .storageUnavailable:
            "Diagnostic storage is unavailable."
        case .storageLimitReached:
            "Diagnostic storage has reached its 100 MB limit."
        case .privacyAuditFailed:
            "The last export did not pass its privacy audit."
        case nil:
            nil
        }
    }
}

private struct DiagnosticRunRow: View {
    let run: DiagnosticRunSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: run.endedAt == nil ? "record.circle" : "checkmark.circle")
                .foregroundStyle(
                    run.endedAt == nil ? PierPlayerTheme.accent : Color.secondary
                )
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.endedAt == nil ? "Current Session" : "Recorded Session")
                    .font(.callout.weight(.medium))
                Text(run.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(run.policy.rawValue.capitalized)
                    .font(.caption)
                Text(ByteCountFormatter.string(fromByteCount: run.byteCount, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private enum DiagnosticsSettingsOperationError: String, Identifiable {
    case exportFailed

    var id: String { rawValue }
    var title: String { "Export Failed" }
    var message: String { "The diagnostic package could not be prepared." }
}
