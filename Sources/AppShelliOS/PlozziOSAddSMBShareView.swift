#if os(iOS)
import CoreUI
import Foundation
import ProviderShare
import SwiftUI

struct PlozziOSAddSMBShareView: View {
    @Environment(\.dismiss) private var dismiss

    let appModel: PlozziOSAppModel

    @State private var host = ""
    @State private var portText = ""
    @State private var share = ""
    @State private var username = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var discoveredShares: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            SettingsSectionGroup("SMB server") {
                TextField("Host or IP address", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port (optional)", text: $portText)
                    .keyboardType(.numberPad)
            }

            SettingsSectionGroup("Sign in") {
                TextField("Username (optional)", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password (optional)", text: $password)
                Button("Find Shares", systemImage: "magnifyingglass") {
                    Task { await findShares() }
                }
                .disabled(!canProbe || isLoading)
            } footer: {
                Text("Leave both fields empty for a guest share.")
            }

            SettingsSectionGroup("Share") {
                TextField("Share name", text: $share)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Connecting…")
                    }
                } else {
                    ForEach(discoveredShares, id: \.self) { item in
                        Button {
                            share = item
                        } label: {
                            HStack {
                                Label(item, systemImage: "folder")
                                Spacer()
                                if share == item {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }

            SettingsSectionGroup("Display") {
                TextField("Name (optional)", text: $displayName)
            }

            if let errorMessage {
                SettingsSectionGroup {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Add SMB Share")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if appModel.addSMBShare(
                        host: host,
                        port: parsedPort,
                        share: share,
                        username: username,
                        password: password,
                        displayName: displayName
                    ) {
                        dismiss()
                    } else {
                        errorMessage = appModel.accountError
                    }
                }
                .disabled(!canSave || isLoading)
            }
        }
    }

    private var parsedPort: Int? {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Int(trimmed)
    }

    private var hasValidPort: Bool {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        guard let port = Int(trimmed) else { return false }
        return (1...65_535).contains(port)
    }

    private var canProbe: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && hasValidPort
    }

    private var canSave: Bool {
        canProbe && !share.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @MainActor
    private func findShares() async {
        isLoading = true
        errorMessage = nil
        discoveredShares = []
        defer { isLoading = false }

        do {
            discoveredShares = try await SMBShareEnumerator.listShares(
                host: host.trimmingCharacters(in: .whitespaces),
                port: parsedPort,
                username: username.trimmingCharacters(in: .whitespaces),
                password: password
            )
            if discoveredShares.isEmpty {
                errorMessage = "No browsable shares were found. You can type the share name manually."
            }
        } catch let error as SMBShareEnumerator.ListError {
            switch error {
            case .authenticationRequired:
                errorMessage = "This server requires a username and password."
            case .credentialsRejected:
                errorMessage = "The username or password is incorrect."
            case .unreachable:
                errorMessage = "Couldn’t connect to this SMB server."
            case .timedOut:
                errorMessage = "The SMB server took too long to respond."
            case let .failed(message):
                errorMessage = message
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
