#if canImport(SwiftUI)
import CoreUI
import FeatureAuth
import Foundation
import SwiftUI

/// "Add a WebDAV share" screen: enter an address + credentials, approve a
/// self-signed certificate if needed (trust-on-first-use), browse the server's
/// folders via PROPFIND, and pick a root. Mirrors `AddShareView`'s card style;
/// all logic lives in `AddWebDAVShareViewModel`.
struct AddWebDAVShareView: View {
    let onBack: () -> Void
    let onConfigured: (WebDAVShareConfiguration) -> Void

    @State private var viewModel = AddWebDAVShareViewModel()
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case back
        case address
        case authMode
        case username
        case password
        case bearer
        case connect
        case approveTrust
        case rejectTrust
        case folder(String)
        case useFolder
        case displayName
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    switch viewModel.step {
                    case .enterAddress: addressStep
                    case .confirmTrust(let sha256): trustStep(sha256: sha256)
                    case .browsing: browseStep
                    case .done(let config):
                        // Hand back once; the parent dismisses the flow.
                        Color.clear.onAppear { onConfigured(config) }
                    }
                }
                .frame(maxWidth: WebDAVShareMetrics.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 48)
                .padding(.vertical, 32)
                .padding(.top, proxy.safeAreaInsets.top)
                .padding(.bottom, proxy.safeAreaInsets.bottom)
            }
            .scrollClipDisabled()
            .ignoresSafeArea(.container, edges: .vertical)
        }
        .defaultFocus($focusedField, .address)
        .onExitCommand(perform: handleExit)
        .onAppear { focusedField = .address }
        .onChange(of: viewModel.step) { _, _ in focusedField = defaultFocus() }
    }

    private func handleExit() {
        switch viewModel.step {
        case .enterAddress: onBack()
        case .confirmTrust: viewModel.rejectTrust()
        case .browsing, .done: viewModel.rejectTrust()
        }
    }

    private func defaultFocus() -> Field {
        switch viewModel.step {
        case .enterAddress: return .address
        case .confirmTrust: return .approveTrust
        case .browsing: return .useFolder
        case .done: return .back
        }
    }

    // MARK: - Step 1: address + credentials

    private var addressStep: some View {
        Group {
            header(
                title: "Add a WebDAV Share",
                subtitle: "Enter the server’s web address and how to sign in.",
                back: onBack
            )
            WebDAVPanel(title: "Address", footer: "For example https://nas.local/dav. Defaults to https:// if you omit it.") {
                TextField("https://nas.local/dav", text: $viewModel.address)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .address)
            }
            WebDAVPanel(title: "Sign in") {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("How to sign in", selection: $viewModel.authMode) {
                        Text("Anonymous").tag(WebDAVAuthMode.anonymous)
                        Text("Username & password").tag(WebDAVAuthMode.usernamePassword)
                        Text("Bearer token").tag(WebDAVAuthMode.bearer)
                    }
                    .pickerStyle(.segmented)
                    .focused($focusedField, equals: .authMode)

                    switch viewModel.authMode {
                    case .anonymous:
                        Text("No sign-in — for public/read-only shares.")
                            .font(.footnote).foregroundStyle(.secondary)
                    case .usernamePassword:
                        TextField("Username", text: $viewModel.username)
                            .textContentType(.username).autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focusedField, equals: .username)
                        SecureField("Password", text: $viewModel.password)
                            .textContentType(.password)
                            .focused($focusedField, equals: .password)
                    case .bearer:
                        SecureField("Bearer token", text: $viewModel.bearerToken)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .bearer)
                    }
                }
            }
            if let error = viewModel.errorMessage {
                InlineErrorMessage(LocalizedStringKey(error), systemImage: "exclamationmark.triangle")
            }
            Button {
                Task { await viewModel.connect() }
            } label: {
                if viewModel.isWorking {
                    ProgressView()
                } else {
                    Text("Connect")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canConnect || viewModel.isWorking)
            .focused($focusedField, equals: .connect)
        }
    }

    // MARK: - Step 2: trust approval (TOFU)

    private func trustStep(sha256: Data) -> some View {
        Group {
            header(
                title: "Verify Certificate",
                subtitle: "This server’s certificate isn’t trusted automatically (it may be self-signed).",
                back: { viewModel.rejectTrust() }
            )
            WebDAVPanel(
                title: "Certificate fingerprint",
                footer: "Only approve this if the SHA-256 fingerprint matches your server. Approving pins this exact certificate; a future change will require re-approval."
            ) {
                Text(Self.formatFingerprint(sha256))
                    .font(.system(.body, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.primary)
            }
            if let error = viewModel.errorMessage {
                InlineErrorMessage(LocalizedStringKey(error), systemImage: "exclamationmark.triangle")
            }
            HStack(spacing: 20) {
                Button("Approve & Continue") {
                    Task { await viewModel.approveTrust() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isWorking)
                .focused($focusedField, equals: .approveTrust)

                Button("Cancel") { viewModel.rejectTrust() }
                    .buttonStyle(.bordered)
                    .focused($focusedField, equals: .rejectTrust)
            }
        }
    }

    // MARK: - Step 3: folder picker

    private var browseStep: some View {
        Group {
            header(
                title: "Choose a Folder",
                subtitle: LocalizedStringKey("Currently at \(viewModel.currentPath)"),
                back: { viewModel.rejectTrust() }
            )
            if viewModel.currentPath != "/" {
                Button {
                    Task { await viewModel.loadFolders(at: Self.parentPath(of: viewModel.currentPath)) }
                } label: {
                    Label("Up one level", systemImage: "arrow.up.left")
                }
                .buttonStyle(.bordered)
            }
            WebDAVPanel(title: "Folders", titleAccessory: {
                if viewModel.isWorking { ProgressView() }
            }) {
                if viewModel.folders.isEmpty {
                    Label(
                        viewModel.isWorking ? "Loading…" : "No sub-folders here.",
                        systemImage: viewModel.isWorking ? "hourglass" : "folder"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 12) {
                        ForEach(viewModel.folders) { folder in
                            Button {
                                Task { await viewModel.loadFolders(at: folder.path) }
                            } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: "folder.fill").foregroundStyle(.secondary)
                                    Text(folder.name).font(.headline)
                                    Spacer(minLength: 12)
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 12)
                                .padding(.horizontal, 12)
                            }
                            .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
                            .focused($focusedField, equals: .folder(folder.path))
                        }
                    }
                }
            }
            WebDAVPanel(
                title: "Display name (optional)",
                footer: "What to call this share on the Home screen."
            ) {
                TextField("Display name", text: $viewModel.displayName)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .displayName)
            }
            if let error = viewModel.errorMessage {
                InlineErrorMessage(LocalizedStringKey(error), systemImage: "exclamationmark.triangle")
            }
            Button("Use This Folder") { viewModel.useCurrentFolder() }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isWorking)
                .focused($focusedField, equals: .useFolder)
        }
    }

    // MARK: - Shared pieces

    private func header(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        back: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Button(action: back) {
                Label("Back", systemImage: "chevron.backward")
            }
            .buttonStyle(.bordered)
            .focused($focusedField, equals: .back)
            OnboardingHeader(title, subtitle: subtitle)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 40)
    }

    static func parentPath(of path: String) -> String {
        var trimmed = path
        if trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let slash = trimmed.lastIndex(of: "/"), slash != trimmed.startIndex else { return "/" }
        return String(trimmed[..<slash])
    }

    /// Colon-grouped uppercase hex, wrapped for on-screen verification.
    static func formatFingerprint(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

private enum WebDAVShareMetrics {
    static let contentMaxWidth: CGFloat = 900
}

/// Local titled card matching `AddShareView`'s `SharePanel`.
private struct WebDAVPanel<Content: View, Accessory: View>: View {
    var title: String
    var footer: LocalizedStringKey?
    var titleAccessory: () -> Accessory
    var content: () -> Content

    init(
        title: String,
        footer: LocalizedStringKey? = nil,
        @ViewBuilder titleAccessory: @escaping () -> Accessory = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.titleAccessory = titleAccessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.0)
                    .foregroundStyle(.secondary)
                Spacer()
                titleAccessory()
            }
            content()
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
#endif
