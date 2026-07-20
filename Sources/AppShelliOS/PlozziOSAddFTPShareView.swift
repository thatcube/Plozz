#if os(iOS)
import AppRuntime
import CoreUI
import Foundation
import MediaTransportFTP
import SwiftUI

struct PlozziOSAddFTPShareView: View {
    private enum Security: String, CaseIterable, Identifiable {
        case ftp
        case ftps

        var id: Self { self }
        var defaultPort: String { self == .ftps ? "990" : "21" }
    }

    private enum Authentication: String, CaseIterable, Identifiable {
        case anonymous
        case password

        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    let appModel: PlozziOSAppModel

    @State private var security: Security = .ftp
    @State private var authentication: Authentication = .anonymous
    @State private var host = ""
    @State private var port = "21"
    @State private var username = ""
    @State private var password = ""
    @State private var path = "/"
    @State private var displayName = ""
    @State private var directories: [FTPDirectoryItem] = []
    @State private var isVerified = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let probe = FTPOnboardingProbe()

    var body: some View {
        Form {
            SettingsSectionGroup("Connection") {
                Picker("Security", selection: $security) {
                    Text("FTP").tag(Security.ftp)
                    Text("FTPS (Implicit TLS)").tag(Security.ftps)
                }
                TextField("Host", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
            } footer: {
                if security == .ftp {
                    Text("FTP sends credentials and media without encryption.")
                } else {
                    Text("FTPS uses TLS from connection start. Explicit TLS (AUTH TLS) is not supported.")
                }
            }

            SettingsSectionGroup("Authentication") {
                Picker("Method", selection: $authentication) {
                    Text("Anonymous").tag(Authentication.anonymous)
                    Text("Username & Password").tag(Authentication.password)
                }
                if authentication == .password {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
            }

            SettingsSectionGroup("Folder") {
                TextField("Path", text: $path)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if isVerified {
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
                    isVerified ? "Connection Verified" : "Verify & Browse",
                    systemImage: isVerified ? "checkmark.circle.fill" : "network"
                ) {
                    Task { await loadDirectories() }
                }
                .disabled(!canConnect || isLoading)
                if isLoading {
                    ProgressView("Connecting…")
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
        .settingsPageSurface()
        .navigationTitle("Add FTP Share")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!isVerified || isLoading)
            }
        }
        .onChange(of: security) { _, newValue in
            port = newValue.defaultPort
            resetVerification()
        }
        .onChange(of: authentication) { _, _ in resetVerification() }
        .onChange(of: host) { _, _ in resetVerification() }
        .onChange(of: port) { _, _ in resetVerification() }
        .onChange(of: username) { _, _ in resetVerification() }
        .onChange(of: password) { _, _ in resetVerification() }
    }

    private var parsedPort: Int? {
        guard let value = Int(port), (1...65_535).contains(value) else {
            return nil
        }
        return value
    }

    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && parsedPort != nil
    }

    private var normalizedPath: String {
        MediaShareAccountConfigurationService.normalizedFilesystemPath(path)
    }

    private var parentPath: String {
        let parent = URL(fileURLWithPath: normalizedPath)
            .deletingLastPathComponent()
            .path
        return parent.isEmpty ? "/" : parent
    }

    private var credentials: (username: String, password: String) {
        switch authentication {
        case .anonymous:
            ("", "")
        case .password:
            (username.trimmingCharacters(in: .whitespaces), password)
        }
    }

    @MainActor
    private func loadDirectories() async {
        guard let parsedPort else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        path = normalizedPath
        let result = await probe.listDirectories(
            host: host.trimmingCharacters(in: .whitespaces),
            port: parsedPort,
            isImplicitTLS: security == .ftps,
            username: credentials.username,
            password: credentials.password,
            trustPinSHA256: nil,
            path: normalizedPath
        )
        switch result {
        case let .success(items):
            directories = items
            isVerified = true
        case .authenticationFailed:
            isVerified = false
            errorMessage = "The FTP credentials were rejected."
        case .unreachable:
            isVerified = false
            errorMessage = "Couldn’t reach this FTP server."
        case let .failed(reason):
            isVerified = false
            errorMessage = reason
        case .cancelled:
            isVerified = false
            errorMessage = "The connection was cancelled."
        }
    }

    private func save() {
        guard let parsedPort else { return }
        var components = URLComponents()
        components.scheme = security.rawValue
        components.host = host.trimmingCharacters(in: .whitespaces)
        components.port = parsedPort == Int(security.defaultPort) ? nil : parsedPort
        components.path = normalizedPath == "/" ? "" : normalizedPath
        guard let baseURL = components.url else {
            errorMessage = "The FTP address is invalid."
            return
        }
        let auth: MediaShareFTPAuth = authentication == .anonymous
            ? .anonymous
            : .password(username: username, password: password)
        if appModel.addFTPShare(
            baseURL: baseURL,
            auth: auth,
            displayName: displayName
        ) {
            dismiss()
        } else {
            errorMessage = appModel.accountError
        }
    }

    private func resetVerification() {
        isVerified = false
        directories = []
        errorMessage = nil
    }
}
#endif
