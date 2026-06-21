#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Reusable container that renders the four canonical async states the same way
/// everywhere: loading, empty, error (with retry), and loaded content.
///
/// Centralising this satisfies the "clear loading/error/empty states" UX
/// requirement without each screen reinventing it.
public struct ContentStateView<Value: Sendable, Content: View>: View {
    private let state: LoadState<Value>
    private let onRetry: () -> Void
    private let content: (Value) -> Content
    private let emptyMessage: String

    public init(
        state: LoadState<Value>,
        emptyMessage: String = "Nothing here yet.",
        onRetry: @escaping () -> Void,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.state = state
        self.emptyMessage = emptyMessage
        self.onRetry = onRetry
        self.content = content
    }

    public var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView()
                .scaleEffect(1.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .loaded(value):
            content(value)

        case .empty:
            messageView(
                icon: "tray",
                title: emptyMessage,
                showRetry: true
            )

        case let .failed(error):
            messageView(
                icon: error == .serverUnreachable ? "wifi.slash" : "exclamationmark.triangle",
                title: error.userMessage,
                showRetry: true
            )
        }
    }

    private func messageView(icon: String, title: String, showRetry: Bool) -> some View {
        VStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 800)
            if showRetry {
                Button("Try Again", action: onRetry)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#endif
