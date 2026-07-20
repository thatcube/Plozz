#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import FeatureAuthCore
import Foundation
import MediaTransportSFTP
import SwiftUI

struct PlozziOSAddSFTPShareView: View {
    @Environment(\.dismiss) private var dismiss
    let appModel: PlozziOSAppModel

    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
    @State private var path = "/"
    @State private var displayName = ""
    @State private var approvedHostKey: Data?
    @State private var pendingHostKey: Data?
    @State private var directories: [SFTPDirectoryItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let probe = SFTPOnboardingProbe()

    var body: some View {
        Form {
            SettingsSectionGroup("SFTP server") {
                TextField("Host", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
            }

            SettingsSectionGroup("Authentication") {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
            }

            SettingsSectionGroup("Folder") {
                TextField("Path", text: $path)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if approvedHostKey != nil {
                    Button("Browse This Folder", systemImage: "folder") {
                        Task { await loadDirectories() }
                    }
                    if normalizedPath != "/" {
                        Button("Parent Folder", systemImage: "arrow.up") {
                            path = parentPath
                            Task { await loadDirectories() }
                        }
                    }
                    ForEach(directories, id: \.path) { directory in
                        Button {
                            path = directory.path
                            Task { await loadDirectories() }
                        } label: {
                            Label(directory.name, systemImage: "folder")
                        }
                    }
                }
            }

            SettingsSectionGroup {
                Button(
                    approvedHostKey == nil ? "Verify & Capture Host Key" : "Connection Verified",
                    systemImage: approvedHostKey == nil ? "lock.shield" : "checkmark.circle.fill"
                ) {
                    Task { await verifyConnection() }
                }
                .disabled(!canConnect || isLoading)
                if isLoading {
                    ProgressView("Connecting…")
                }
            } footer: {
                Text("Plozz pins the server’s SSH host key after you approve its fingerprint.")
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
        .settingsPageSurface()
        .navigationTitle("Add SFTP Share")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(approvedHostKey == nil || isLoading)
            }
        }
        .onChange(of: host) { _, _ in resetVerification() }
        .onChange(of: port) { _, _ in resetVerification() }
        .onChange(of: username) { _, _ in resetVerification() }
        .onChange(of: password) { _, _ in resetVerification() }
        .alert(
            "Trust This SSH Host Key?",
            isPresented: Binding(
                get: { pendingHostKey != nil },
                set: { if !$0 { pendingHostKey = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingHostKey = nil
            }
            Button("Trust & Browse") {
                approvedHostKey = pendingHostKey
                pendingHostKey = nil
                Task { await loadDirectories() }
            }
        } message: {
            Text(fingerprintText(pendingHostKey))
        }
    }

    private var parsedPort: Int? {
        guard let value = Int(port), (1...65_535).contains(value) else {
            return nil
        }
        return value
    }

    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && parsedPort != nil
    }

    private var normalizedPath: String {
        MediaShareAccountConfigurationService.normalizedFilesystemPath(path)
    }

    private var parentPath: String {
        let url = URL(fileURLWithPath: normalizedPath)
        let parent = url.deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    @MainActor
    private func verifyConnection() async {
        guard let parsedPort else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        switch await probe.captureHostKey(
            host: host.trimmingCharacters(in: .whitespaces),
            port: parsedPort,
            username: username.trimmingCharacters(in: .whitespaces),
            password: password
        ) {
        case let .success(hostKeySHA256):
            pendingHostKey = hostKeySHA256
        case .unreachable:
            errorMessage = "Couldn’t reach this SFTP server."
        case .authenticationFailed:
            errorMessage = "The SFTP credentials were rejected."
        case let .failed(reason):
            errorMessage = reason
        case .cancelled:
            errorMessage = "The connection was cancelled."
        }
    }

    @MainActor
    private func loadDirectories() async {
        guard let parsedPort, let approvedHostKey else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        path = normalizedPath
        switch await probe.listDirectories(
            host: host.trimmingCharacters(in: .whitespaces),
            port: parsedPort,
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            hostKeySHA256: approvedHostKey,
            path: normalizedPath
        ) {
        case let .success(items):
            directories = items
        case .authenticationFailed:
            errorMessage = "The SFTP credentials were rejected."
        case .unreachable:
            errorMessage = "Couldn’t reach this SFTP server."
        case let .failed(reason):
            errorMessage = reason
        case .cancelled:
            errorMessage = "The connection was cancelled."
        }
    }

    private func save() {
        guard let parsedPort,
              let approvedHostKey,
              let fingerprint = try? SHA256Fingerprint(bytes: approvedHostKey) else {
            return
        }
        if appModel.addSFTPShare(
            host: host,
            port: parsedPort,
            path: normalizedPath,
            username: username,
            password: password,
            hostKeyPin: fingerprint,
            displayName: displayName
        ) {
            dismiss()
        } else {
            errorMessage = appModel.accountError
        }
    }

    private func resetVerification() {
        approvedHostKey = nil
        pendingHostKey = nil
        directories = []
        errorMessage = nil
    }

    private func fingerprintText(_ data: Data?) -> String {
        guard let data else { return "" }
        return "SHA256 " + data.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
#endif
