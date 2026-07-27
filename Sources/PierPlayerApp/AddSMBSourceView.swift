import SwiftUI

struct AddSMBSourceView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var host = ""
    @State private var share = ""
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var requiresEncryption = false
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Source") {
                    TextField("Name", text: $displayName)
                    TextField("Host", text: $host, prompt: Text("nas.local"))
                    TextField("Share", text: $share, prompt: Text("Media"))
                }

                Section("Credentials") {
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                    TextField("Domain", text: $domain, prompt: Text("Optional"))
                }

                Section("Security") {
                    Toggle("Require SMB encryption", isOn: $requiresEncryption)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Connect") {
                    connect()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect || isConnecting)
            }
            .padding(16)
        }
        .frame(width: 460, height: 440)
        .navigationTitle("Add SMB Source")
        .interactiveDismissDisabled(isConnecting)
    }

    private var canConnect: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !share.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func connect() {
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                try await model.addSMBSource(
                    displayName: displayName,
                    host: host,
                    share: share,
                    username: username,
                    password: password,
                    domain: domain,
                    requiresEncryption: requiresEncryption
                )
                dismiss()
            } catch {
                errorMessage = AppModel.connectionErrorMessage(for: error)
                isConnecting = false
            }
        }
    }
}
