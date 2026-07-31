import Foundation
import SwiftUI

enum SourceManagementAction: CaseIterable {
    case information
    case edit
    case remove

    var title: String {
        switch self {
        case .information: "Get Info"
        case .edit: "Edit Source"
        case .remove: "Remove Source"
        }
    }
}

struct SMBSourceDetails: Equatable, Identifiable {
    let id: UUID
    let displayName: String
    let host: String
    let share: String
    let username: String
    let domain: String?
    let requiresEncryption: Bool

    init(
        id: UUID,
        displayName: String,
        host: String,
        share: String,
        username: String,
        domain: String?,
        requiresEncryption: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.share = share
        self.username = username
        self.domain = domain
        self.requiresEncryption = requiresEncryption
    }

    init(source: AppModel.ConnectedSource) {
        self.init(
            id: source.id,
            displayName: source.displayName,
            host: source.configuration.host,
            share: source.configuration.share,
            username: source.username,
            domain: source.configuration.domain,
            requiresEncryption: source.configuration.requiresEncryption
        )
    }

    var address: String {
        "smb://\(host)/\(share)"
    }

    var domainText: String {
        domain ?? "Not Set"
    }

    var encryptionText: String {
        requiresEncryption ? "Required" : "Not Required"
    }
}

struct SMBSourceFormDraft: Equatable {
    var displayName: String
    var host: String
    var share: String
    var username: String
    var password: String
    var domain: String
    var requiresEncryption: Bool

    init(
        displayName: String = "",
        host: String = "",
        share: String = "",
        username: String = "",
        password: String = "",
        domain: String = "",
        requiresEncryption: Bool = false
    ) {
        self.displayName = displayName
        self.host = host
        self.share = share
        self.username = username
        self.password = password
        self.domain = domain
        self.requiresEncryption = requiresEncryption
    }

    init(details: SMBSourceDetails) {
        self.init(
            displayName: details.displayName,
            host: details.host,
            share: details.share,
            username: details.username,
            domain: details.domain ?? "",
            requiresEncryption: details.requiresEncryption
        )
    }

    var canSubmit: Bool {
        !displayName.trimmed.isEmpty
            && !host.trimmed.isEmpty
            && !share.trimmed.isEmpty
            && !username.trimmed.isEmpty
    }

    var replacementPassword: String? {
        password.isEmpty ? nil : password
    }

    var normalizedDomain: String? {
        domain.trimmed.isEmpty ? nil : domain
    }
}

struct SourceEditInteractionState: Equatable {
    let isSaving: Bool

    var allowsDismissal: Bool { !isSaving }
    var allowsEditing: Bool { !isSaving }
}

struct SourceInformationView: View {
    let details: SMBSourceDetails
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SourceSheetHeader(
                title: details.displayName,
                subtitle: "SMB Source Information",
                systemImage: "externaldrive.connected.to.line.below"
            )
            Divider()
            informationForm
            Divider()
            footer
        }
        .frame(width: 520, height: 430)
    }

    private var informationForm: some View {
        Form {
            Section("Source Details") {
                LabeledContent("Address") {
                    Text(details.address)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                LabeledContent("Username", value: details.username)
                LabeledContent("Domain", value: details.domainText)
                LabeledContent("Encryption", value: details.encryptionText)
                LabeledContent("Source ID") {
                    Text(details.id.uuidString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
        .background(.bar)
    }
}

struct EditSMBSourceView: View {
    @ObservedObject var model: AppModel
    let details: SMBSourceDetails

    @Environment(\.dismiss) private var dismiss
    @State private var draft: SMBSourceFormDraft
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(model: AppModel, details: SMBSourceDetails) {
        self.model = model
        self.details = details
        _draft = State(initialValue: SMBSourceFormDraft(details: details))
    }

    var body: some View {
        let interaction = SourceEditInteractionState(isSaving: isSaving)
        VStack(spacing: 0) {
            SourceSheetHeader(
                title: "Edit SMB Source",
                subtitle: details.displayName,
                systemImage: "externaldrive.badge.wifi"
            )
            Divider()
            SMBSourceForm(
                draft: $draft,
                passwordPrompt: "Keep current password",
                passwordHelp: "Leave blank to keep the current password.",
                errorMessage: errorMessage
            )
            .disabled(!interaction.allowsEditing)
            Divider()
            footer
        }
        .frame(width: 520, height: 590)
        .interactiveDismissDisabled(isSaving)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(!SourceEditInteractionState(isSaving: isSaving).allowsDismissal)

            Spacer()

            if isSaving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Saving Source")
            }

            Button {
                save()
            } label: {
                Label(isSaving ? "Saving" : "Save Changes", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.canSubmit || isSaving)
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        .background(.bar)
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await model.updateSMBSource(
                    id: details.id,
                    displayName: draft.displayName,
                    host: draft.host,
                    share: draft.share,
                    username: draft.username,
                    replacementPassword: draft.replacementPassword,
                    domain: draft.normalizedDomain,
                    requiresEncryption: draft.requiresEncryption
                )
                dismiss()
            } catch {
                errorMessage = AppModel.connectionErrorMessage(for: error)
                isSaving = false
            }
        }
    }
}

struct SMBSourceForm: View {
    @Binding var draft: SMBSourceFormDraft
    let passwordPrompt: String
    let passwordHelp: String?
    let errorMessage: String?

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case displayName
        case host
        case share
        case username
        case password
        case domain
    }

    var body: some View {
        Form {
            Section("Source") {
                LabeledContent("Name") {
                    TextField("Source name", text: $draft.displayName, prompt: Text("Home NAS"))
                        .labelsHidden()
                        .focused($focusedField, equals: .displayName)
                }
                LabeledContent("Host") {
                    TextField("Host", text: $draft.host, prompt: Text("nas.local"))
                        .labelsHidden()
                        .focused($focusedField, equals: .host)
                }
                LabeledContent("Share") {
                    TextField("Share", text: $draft.share, prompt: Text("Media"))
                        .labelsHidden()
                        .focused($focusedField, equals: .share)
                }
            }

            Section("Credentials") {
                LabeledContent("Username") {
                    TextField("Username", text: $draft.username)
                        .labelsHidden()
                        .focused($focusedField, equals: .username)
                }
                LabeledContent("Password") {
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField(passwordPrompt, text: $draft.password)
                            .labelsHidden()
                            .focused($focusedField, equals: .password)
                        if let passwordHelp {
                            Text(passwordHelp)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Domain") {
                    TextField("Domain", text: $draft.domain, prompt: Text("Optional"))
                        .labelsHidden()
                        .focused($focusedField, equals: .domain)
                }
            }

            Section("Security") {
                Toggle("Require SMB encryption", isOn: $draft.requiresEncryption)
            }

            if let errorMessage {
                Section {
                    Label {
                        Text(errorMessage)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            focusedField = .displayName
        }
    }
}

struct SourceSheetHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.teal.opacity(0.14))
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.teal)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 76)
        .background(.bar)
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
