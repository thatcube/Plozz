#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import ProviderPlex

/// TV-friendly Plex sign-in screen: shows the big link code with a live expiry
/// timer, then (if the account has several servers) a server picker. Mirrors
/// `QuickConnectView`'s structure so both providers feel consistent.
public struct PlexLinkView: View {
    @State private var viewModel: PlexAuthViewModel
    private let onCancel: () -> Void

    @FocusState private var focused: Control?
    private enum Control: Hashable { case cancel, retry }

    public init(
        viewModel: PlexAuthViewModel,
        onCancel: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onCancel = onCancel
    }

    private func cancel() {
        viewModel.cancel()
        onCancel()
    }

    public var body: some View {
        VStack(spacing: 32) {
            content

            controls
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($focused, .cancel)
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

        case let .awaitingLink(code, expiresAt):
            HStack(alignment: .top, spacing: 80) {
                VStack(spacing: 28) {
                    Text("Scan with your phone")
                        .font(.title2).bold()
                        .fixedSize(horizontal: true, vertical: false)
                    BrandQRCodeView(
                        payload: Self.linkURL(for: code),
                        moduleColor: .white,
                        size: 440
                    )
                }

                orDivider

                VStack(spacing: 24) {
                    Text("Or enter a code")
                        .font(.title2).bold()

                    VStack(spacing: 4) {
                        Text("Go to")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("plex.tv/link")
                            .font(.system(size: 52, weight: .heavy, design: .rounded))
                            .foregroundStyle(PlexBrand.gold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }

                    Text(code)
                        .font(.plozzCode(size: 84))
                        .tracking(10)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 44)
                        .padding(.vertical, 20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))

                    PlexExpiryCountdown(expiresAt: expiresAt, lifetime: viewModel.codeLifetime)
                }
                .frame(maxWidth: 560)
            }

        case .loadingServers:
            ProgressView("Finding your Plex servers…")
                .font(.title2)

        case let .selectingServer(servers):
            ServerList(servers: servers) { viewModel.selectServers($0) }

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

    private var orDivider: some View {
        VStack(spacing: 16) {
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(width: 2)
                .frame(maxHeight: .infinity)
            Text("OR")
                .font(.title3).bold()
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(width: 2)
                .frame(maxHeight: .infinity)
        }
        .frame(height: 500)
    }

    /// The activation URL the QR encodes: scanning it on a phone opens
    /// plex.tv/link with the code pre-filled.
    static func linkURL(for code: String) -> String {
        "https://plex.tv/link?code=\(code)"
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

/// Multi-select picker shown when a Plex account can reach more than one server.
/// Mirrors the Settings checklist affordance: tap a row to toggle its checkmark,
/// then Continue to add every checked server at once.
private struct ServerList: View {
    let servers: [PlexServerCandidate]
    let onContinue: ([PlexServerCandidate]) -> Void

    @State private var selected: Set<String>
    @FocusState private var focusedContinue: Bool

    init(servers: [PlexServerCandidate], onContinue: @escaping ([PlexServerCandidate]) -> Void) {
        self.servers = servers
        self.onContinue = onContinue
        // Preselect owned servers — the ones people almost always want.
        _selected = State(initialValue: Set(servers.filter(\.isOwned).map(\.id)))
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Choose your servers")
                    .font(.largeTitle).bold()
                Text("Select the Plex servers you'd like to add. You can add or remove servers anytime in Settings.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(servers) { server in
                        Button {
                            toggle(server.id)
                        } label: {
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(server.name).font(.headline)
                                    Text(server.isOwned ? "Owned" : "Shared")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: selected.contains(server.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundStyle(selected.contains(server.id) ? Color.accentColor : .secondary)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SettingsFocusButtonStyle())
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: 900)

            Button {
                onContinue(servers.filter { selected.contains($0.id) })
            } label: {
                Text("Continue").frame(minWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty)
            .focused($focusedContinue)
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

/// Animated ring that depletes over the life of the current code, mirroring the
/// Quick Connect countdown.
private struct PlexExpiryCountdown: View {
    let expiresAt: Date
    let lifetime: TimeInterval

    var body: some View {
        TimelineView(.animation) { context in
            let remaining = max(0, expiresAt.timeIntervalSince(context.date))
            let fraction = lifetime > 0 ? remaining / lifetime : 0
            let tint: Color = remaining <= 30 ? .orange : .accentColor

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
