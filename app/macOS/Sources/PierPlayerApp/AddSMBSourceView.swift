import SwiftUI

struct AddSMBSourceView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft = SMBSourceFormDraft()
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            SMBSourceForm(
                draft: $draft,
                passwordPrompt: "Password",
                passwordHelp: nil,
                errorMessage: errorMessage
            )
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .interactiveDismissDisabled(isConnecting)
    }

    private var header: some View {
        SourceSheetHeader(
            title: "Add SMB Source",
            subtitle: "Network Storage",
            systemImage: "externaldrive.badge.plus"
        )
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if isConnecting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Connecting")
            }

            Button {
                connect()
            } label: {
                Label(isConnecting ? "Connecting" : "Connect", systemImage: "network")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.canSubmit || isConnecting)
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        .background(.bar)
    }

    private func connect() {
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                try await model.addSMBSource(
                    displayName: draft.displayName,
                    host: draft.host,
                    share: draft.share,
                    username: draft.username,
                    password: draft.password,
                    domain: draft.normalizedDomain,
                    requiresEncryption: draft.requiresEncryption
                )
                dismiss()
            } catch {
                errorMessage = AppModel.connectionErrorMessage(for: error)
                isConnecting = false
                AccessibilityAnnouncement.post(errorMessage ?? "Connection failed.")
            }
        }
    }
}
