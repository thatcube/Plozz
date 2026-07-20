#if os(iOS)
import AppRuntime
import CoreUI
import FeatureAuthCore
import Foundation
import MediaTransportHTTP
import MediaTransportWebDAV
import SwiftUI

struct PlozziOSAddWebDAVShareView: View {
    private enum Authentication: String, CaseIterable, Identifiable {
        case anonymous
        case password
        case bearer

        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    let appModel: PlozziOSAppModel

    @State private var address = ""
    @State private var authentication: Authentication = .password
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var displayName = ""
    @State private var trustPinData: Data?
    @State private var pendingTrustPin: Data?
    @State private var isValidated = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let probe = WebDAVOnboardingProbe()

    var body: some View {
        Form {
            SettingsSectionGroup("WebDAV server") {
                TextField(
                    "https://server.example/dav",
                    text: $address
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            }

            SettingsSectionGroup("Authentication") {
                Picker("Method", selection: $authentication) {
                    Text("Username & Password").tag(Authentication.password)
                    Text("Bearer Token").tag(Authentication.bearer)
                    Text("Anonymous").tag(Authentication.anonymous)
                }
                if authentication == .password {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                } else if authentication == .bearer {
                    SecureField("Bearer token", text: $token)
                }
            }

            SettingsSectionGroup {
                Button(
                    isValidated ? "Connection Verified" : "Verify Connection",
                    systemImage: isValidated ? "checkmark.circle.fill" : "network"
                ) {
                    Task { await verifyConnection() }
                }
                .disabled(parsedURL == nil || isLoading)
                if isLoading {
                    ProgressView("Connecting…")
                }
            } footer: {
                if parsedURL?.scheme?.lowercased() == "http" {
                    Text("HTTP sends reusable credentials without encryption. Prefer HTTPS.")
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
        .navigationTitle("Add WebDAV Share")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }
                .disabled(!isValidated || isLoading)
            }
        }
        .onChange(of: address) { _, _ in resetValidation() }
        .onChange(of: authentication) { _, _ in resetValidation() }
        .onChange(of: username) { _, _ in resetValidation() }
        .onChange(of: password) { _, _ in resetValidation() }
        .onChange(of: token) { _, _ in resetValidation() }
        .alert(
            "Trust This Certificate?",
            isPresented: Binding(
                get: { pendingTrustPin != nil },
                set: { if !$0 { pendingTrustPin = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingTrustPin = nil
            }
            Button("Trust & Connect") {
                guard let pin = pendingTrustPin else { return }
                pendingTrustPin = nil
                trustPinData = pin
                Task { await validate(using: .pinnedLeaf(sha256: pin)) }
            }
        } message: {
            Text(fingerprintText(pendingTrustPin))
        }
    }

    private var parsedURL: URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private var credential: WebDAVCredential {
        switch authentication {
        case .anonymous:
            .anonymous
        case .password:
            .password(username: username, password: password, policy: .automatic)
        case .bearer:
            .bearerToken(token)
        }
    }

    private var accountAuth: MediaShareWebDAVAuth {
        switch authentication {
        case .anonymous:
            .anonymous
        case .password:
            .password(username: username, password: password)
        case .bearer:
            .bearer(token: token)
        }
    }

    @MainActor
    private func verifyConnection() async {
        guard let url = parsedURL else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        if url.scheme?.lowercased() == "https" {
            switch await probe.preflightTrust(url: url) {
            case .systemTrusted:
                trustPinData = nil
                await validate(using: .system)
            case let .needsApproval(sha256):
                pendingTrustPin = sha256
            case .unreachable:
                errorMessage = "Couldn’t reach this WebDAV server."
            }
        } else {
            trustPinData = nil
            await validate(using: .system)
        }
    }

    @MainActor
    private func validate(using trust: WebDAVOnboardingTrust) async {
        guard let url = parsedURL else { return }
        switch await probe.validate(
            url: url,
            credential: credential,
            trust: trust
        ) {
        case .success:
            isValidated = true
            errorMessage = nil
        case let .failure(error):
            isValidated = false
            errorMessage = message(for: error)
        }
    }

    private func save() {
        guard let url = parsedURL else { return }
        let fingerprint = trustPinData.flatMap { try? SHA256Fingerprint(bytes: $0) }
        if appModel.addWebDAVShare(
            baseURL: url,
            auth: accountAuth,
            trustPin: fingerprint,
            displayName: displayName
        ) {
            dismiss()
        } else {
            errorMessage = appModel.accountError
        }
    }

    private func resetValidation() {
        isValidated = false
        trustPinData = nil
        errorMessage = nil
    }

    private func message(for error: WebDAVOnboardingError) -> String {
        switch error {
        case .invalidURL: "The WebDAV address is invalid."
        case .notSecure: "This server rejected credentials over HTTP."
        case .unreachable: "Couldn’t reach this WebDAV server."
        case .untrusted: "The server certificate could not be trusted."
        case .authenticationFailed: "The WebDAV credentials were rejected."
        case .notWebDAV: "This address is not a WebDAV endpoint."
        case .forbidden: "Access to this WebDAV folder was denied."
        case .serverError: "The WebDAV server reported an error."
        case .cancelled: "The connection was cancelled."
        }
    }

    private func fingerprintText(_ data: Data?) -> String {
        guard let data else { return "" }
        return data.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
#endif
