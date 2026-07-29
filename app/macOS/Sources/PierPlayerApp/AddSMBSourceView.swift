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
        VStack(spacing: 0) {
            header
            Divider()
            connectionForm
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .interactiveDismissDisabled(isConnecting)
        .onAppear {
            focusedField = .displayName
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.teal.opacity(0.14))
                Image(systemName: "externaldrive.badge.plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.teal)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("Add SMB Source")
                    .font(.title3.weight(.semibold))
                Text("Network Storage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 76)
        .background(.bar)
    }

    private var connectionForm: some View {
        Form {
            Section("Source") {
                LabeledContent("Name") {
                    TextField("Source name", text: $displayName, prompt: Text("Home NAS"))
                        .labelsHidden()
                        .focused($focusedField, equals: .displayName)
                }
                LabeledContent("Host") {
                    TextField("Host", text: $host, prompt: Text("nas.local"))
                        .labelsHidden()
                        .focused($focusedField, equals: .host)
                }
                LabeledContent("Share") {
                    TextField("Share", text: $share, prompt: Text("Media"))
                        .labelsHidden()
                        .focused($focusedField, equals: .share)
                }
            }

            Section("Credentials") {
                LabeledContent("Username") {
                    TextField("Username", text: $username)
                        .labelsHidden()
                        .focused($focusedField, equals: .username)
                }
                LabeledContent("Password") {
                    SecureField("Password", text: $password)
                        .labelsHidden()
                        .focused($focusedField, equals: .password)
                }
                LabeledContent("Domain") {
                    TextField("Domain", text: $domain, prompt: Text("Optional"))
                        .labelsHidden()
                        .focused($focusedField, equals: .domain)
                }
            }

            Section("Security") {
                Toggle("Require SMB encryption", isOn: $requiresEncryption)
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
            .disabled(!canConnect || isConnecting)
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        .background(.bar)
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
