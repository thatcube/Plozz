#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// TV-friendly username/password sign-in screen. The lower-priority sibling of
/// `QuickConnectView`, reached from its secondary action.
public struct PasswordSignInView: View {
    @State private var viewModel: PasswordSignInViewModel
    private let serverName: String
    private let onBack: () -> Void

    @FocusState private var focusedField: Field?
    private enum Field { case username, password }

    public init(
        viewModel: PasswordSignInViewModel,
        serverName: String,
        onBack: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.serverName = serverName
        self.onBack = onBack
    }

    public var body: some View {
        VStack(spacing: 32) {
            VStack(spacing: 8) {
                Text("Sign in to \(serverName)")
                    .font(.largeTitle).bold()
                Text("Enter your Jellyfin username and password.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }

            VStack(spacing: 20) {
                TextField("Username", text: $viewModel.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }

                SecureField("Password", text: $viewModel.password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit { viewModel.submit() }
            }
            .frame(maxWidth: 700)

            if case let .error(message) = viewModel.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 700)
            }

            HStack(spacing: 24) {
                Button(role: .cancel) {
                    viewModel.cancel()
                    onBack()
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
        .onAppear { focusedField = .username }
        .onDisappear { viewModel.cancel() }
    }
}

#endif
