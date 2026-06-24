#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// TV-friendly Quick Connect screen: shows the big code, a live expiry timer,
/// and Cancel / Try Again, plus an optional low-emphasis secondary action.
public struct QuickConnectView: View {
    /// A low-emphasis alternative action rendered beneath the main controls
    /// (e.g. "Sign in with username & password"). Kept visually subordinate so
    /// Quick Connect remains the primary path.
    public struct SecondaryAction {
        public let title: String
        public let handler: () -> Void
        public init(title: String, handler: @escaping () -> Void) {
            self.title = title
            self.handler = handler
        }
    }

    @State private var viewModel: QuickConnectViewModel
    private let serverName: String
    private let onCancel: () -> Void
    private let secondaryAction: SecondaryAction?

    @FocusState private var focused: Control?
    private enum Control: Hashable { case cancel, retry, secondary }

    public init(
        viewModel: QuickConnectViewModel,
        serverName: String,
        onCancel: @escaping () -> Void,
        secondaryAction: SecondaryAction? = nil
    ) {
        _viewModel = State(initialValue: viewModel)
        self.serverName = serverName
        self.onCancel = onCancel
        self.secondaryAction = secondaryAction
    }

    private func cancel() {
        viewModel.cancel()
        onCancel()
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

            if let secondaryAction {
                Button {
                    secondaryAction.handler()
                } label: {
                    Label(secondaryAction.title, systemImage: "person.fill")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .focused($focused, equals: .secondary)
                .padding(.top, 4)
            }
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Default focus lands on Cancel, not the low-priority sign-in link, so a
        // press of the remote backs out rather than opening password entry.
        .defaultFocus($focused, .cancel)
        // The remote's Menu/back button should return to the server picker.
        .onExitCommand { cancel() }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .requesting:
            ProgressView("Requesting a code…")
                .font(.title2)

        case let .awaitingApproval(code, expiresAt):
            VStack(spacing: 28) {
                Text(code)
                    .font(.plozzCode(size: 96))
                    .tracking(12)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))

                ExpiryCountdown(expiresAt: expiresAt, lifetime: viewModel.codeLifetime)
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
                cancel()
            } label: {
                Text("Cancel").frame(minWidth: 200)
            }
            .focused($focused, equals: .cancel)

            if case .error = viewModel.phase {
                Button {
                    viewModel.retry()
                } label: {
                    Text("Try Again").frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .focused($focused, equals: .retry)
            }
        }
    }
}

/// Animated ring that depletes over the life of the current code, with the
/// seconds remaining at its centre. The sole, self-evident signal that a code
/// is time-limited — it shifts to a warning tint as the deadline nears.
private struct ExpiryCountdown: View {
    let expiresAt: Date
    let lifetime: TimeInterval

    var body: some View {
        TimelineView(.animation) { context in
            let remaining = max(0, expiresAt.timeIntervalSince(context.date))
            let fraction = lifetime > 0 ? remaining / lifetime : 0
            let tint: Color = remaining <= 15 ? .orange : .accentColor

            ZStack {
                Circle()
                    .stroke(tint.opacity(0.18), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(remaining.rounded(.up)))")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
            }
            .frame(width: 104, height: 104)
            .animation(.easeOut(duration: 0.3), value: tint)
            .accessibilityLabel("Code expires in \(Int(remaining.rounded(.up))) seconds")
        }
    }
}

#endif
