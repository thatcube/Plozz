#if canImport(SwiftUI)
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

        case let .awaitingApproval(code, expiresAt):
            VStack(spacing: 24) {
                Text(code)
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .tracking(12)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))

                ExpiryCountdown(expiresAt: expiresAt, lifetime: viewModel.codeLifetime)

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

/// Animated ring + numeric countdown showing how long the current code stays
/// valid. Depletes smoothly and shifts to a warning colour as time runs low.
private struct ExpiryCountdown: View {
    let expiresAt: Date
    let lifetime: TimeInterval

    var body: some View {
        TimelineView(.animation) { context in
            let remaining = max(0, expiresAt.timeIntervalSince(context.date))
            let fraction = lifetime > 0 ? remaining / lifetime : 0
            let isUrgent = remaining <= 15
            let tint: Color = isUrgent ? .orange : .accentColor

            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(tint.opacity(0.2), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(remaining.rounded(.up)))")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .frame(width: 120, height: 120)

                Text("Code expires soon — a new one appears automatically")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#endif
