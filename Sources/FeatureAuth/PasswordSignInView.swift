#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureAuthCore

/// TV-friendly username/password sign-in screen. The lower-priority sibling of
/// `QuickConnectView`, reached from its secondary action.
public struct PasswordSignInView: View {
    @State private var viewModel: PasswordSignInViewModel
    private let serverName: String
    private let providerName: String
    private let onBack: () -> Void

    @FocusState private var focusedField: Field?
    private enum Field { case username, password }

    public init(
        viewModel: PasswordSignInViewModel,
        serverName: String,
        providerName: String = "Jellyfin",
        onBack: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.serverName = serverName
        self.providerName = providerName
        self.onBack = onBack
    }

    public var body: some View {
        VStack(spacing: 32) {
            OnboardingHeader(
                "Sign in to \(serverName)",
                subtitle: "Enter your \(providerName) username and password."
            )

            // A Form gives the native tvOS grouped-row appearance and the
            // standard full-screen keyboard when a field is selected.
            Form {
                TextField("Username", text: $viewModel.username)
                    .textContentType(.username)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }

                SecureField("Password", text: $viewModel.password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit { viewModel.submit() }
            }
            .frame(maxWidth: 700, maxHeight: 320)

            if case let .error(message) = viewModel.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 700)
            }

            HStack(spacing: 24) {
                Button(role: .cancel) {
                    back()
                } label: {
                    Text("Back").frame(minWidth: 200)
                }

                Button {
                    viewModel.submit()
                } label: {
                    Group {
                        if case .submitting = viewModel.phase {
                            ProgressView()
                        } else {
                            Text("Sign In")
                        }
                    }
                    .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSubmit)
            }
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The remote's Menu/back button returns to the Quick Connect screen.
        .onExitCommand { back() }
        .onAppear { focusedField = .username }
        .onDisappear { viewModel.cancel() }
    }

    private func back() {
        viewModel.cancel()
        onBack()
    }
}

#endif
