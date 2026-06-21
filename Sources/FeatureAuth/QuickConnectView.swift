import SwiftUI
import CoreModels

/// TV-friendly Quick Connect screen: shows the big code, status, and Cancel/Retry.
public struct QuickConnectView: View {
    @State private var viewModel: QuickConnectViewModel
    private let serverName: String
    private let onCancel: () -> Void

    public init(
        viewModel: QuickConnectViewModel,
        serverName: String,
        onCancel: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.serverName = serverName
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 32) {
            VStack(spacing: 8) {
                Text("Sign in to \(serverName)")
                    .font(.largeTitle).bold()
                Text("Open Jellyfin on your phone or computer, go to **Quick Connect**, and enter this code.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }

            content

            controls
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .requesting:
            ProgressView("Requesting a code…")
                .font(.title2)

        case let .awaitingApproval(code):
            VStack(spacing: 16) {
                Text(code)
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .tracking(12)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
                Label("Waiting for approval…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }

        case .success:
            Label("Signed in!", systemImage: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(.green)

        case let .error(message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 24) {
            Button(role: .cancel) {
                viewModel.cancel()
                onCancel()
            } label: {
                Text("Cancel").frame(minWidth: 200)
            }

            if case .error = viewModel.phase {
                Button {
                    viewModel.retry()
                } label: {
                    Text("Try Again").frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
