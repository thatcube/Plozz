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

    @Environment(\.themePalette) private var palette
    @FocusState private var focused: Control?
    private enum Control: Hashable { case cancel, retry, continueServers }

    /// Which servers are checked on the multi-select step. Lifted here (from the
    /// old `ServerList`) so the Continue button can live beside Cancel in the
    /// shared footer and share this focus scope.
    @State private var selectedServerIDs = Set<String>()
    @State private var didSeedSelection = false
    /// Drives the "start over?" confirmation before a cancel that would abandon
    /// the in-progress sign-in.
    @State private var showCancelConfirm = false

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

    /// Cancel, but confirm first on the server-select step — the user has signed
    /// in and picked servers there, so a stray Menu press / Cancel shouldn't
    /// silently throw the sign-in away and start over. Earlier steps (waiting on
    /// the code, loading) back out immediately.
    private func requestCancel() {
        if case .selectingServer = viewModel.phase {
            showCancelConfirm = true
        } else {
            cancel()
        }
    }

    public var body: some View {
        VStack(spacing: 24) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // As low as we can sit without entering tvOS's overscan/no-go zone:
            // ~40pt above the inner edge of the safe area.
            controls
        }
        .padding(.horizontal, 60)
        .padding(.top, 60)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($focused, defaultControl)
        .onExitCommand { requestCancel() }
        .onAppear { viewModel.startIfNeeded() }
        .onDisappear { viewModel.cancel() }
        .onChange(of: viewModel.phase) { _, newPhase in
            // When the server picker appears, land focus on Continue (not Cancel).
            if case .selectingServer = newPhase { focused = .continueServers }
        }
        .confirmationDialog(
            "Start over?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Start Over", role: .destructive) { cancel() }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("You'll go back to the start and no server will be added.")
        }
    }

    /// The button focus should rest on when the screen (or a new phase) appears.
    private var defaultControl: Control {
        if case .selectingServer = viewModel.phase { return .continueServers }
        return .cancel
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .requesting:
            ProgressView("Requesting a code…")
                .font(.title2)

        case let .awaitingLink(code, authorizationURL, expiresAt):
            HStack(alignment: .top, spacing: 64) {
                VStack(spacing: 28) {
                    Text("Scan with your phone")
                        .font(.title3).bold()
                        .fixedSize(horizontal: true, vertical: false)
                    BrandQRCodeView(
                        payload: authorizationURL.absoluteString,
                        size: 460
                    )
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 0) {
                    Text("Or enter a code at")
                        .font(.title3).bold()

                    Spacer(minLength: 0)

                    VStack(spacing: 24) {
                        Text("plex.tv/link")
                            .font(.system(size: 64, weight: .bold))
                            .foregroundStyle(PlexBrand.gold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)

                        HStack(spacing: 32) {
                            Text(code)
                                .font(.plozzCode(size: 96))
                                .tracking(12)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .padding(.horizontal, 48)
                                .padding(.vertical, 24)
                                .background { codePanel }

                            PlexExpiryCountdown(
                                expiresAt: expiresAt,
                                lifetime: viewModel.codeLifetime
                            )
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { manualLinkPanel }
            }
            // Bound the row to the QR column's height so both choices remain
            // balanced instead of stretching into the footer.
            .fixedSize(horizontal: false, vertical: true)

        case .loadingServers:
            ProgressView("Finding your Plex servers…")
                .font(.title2)

        case let .selectingServer(servers):
            ServerList(servers: servers, selected: $selectedServerIDs)
                .onAppear { seedSelectionIfNeeded(servers) }

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

    private var manualLinkPanel: some View {
        let shape = RoundedRectangle(
            cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius,
            style: .continuous
        )
        return shape
            .fill(palette.cardSurface)
            .overlay {
                shape.strokeBorder(palette.cardBorder.opacity(0.45), lineWidth: 1)
            }
    }

    private var codePanel: some View {
        let shape = RoundedRectangle(
            cornerRadius: PlozzTheme.Metrics.Radius.panel,
            style: .continuous
        )
        return shape
            .fill(palette.cardSurface)
            .overlay {
                shape.fill(Color.black.opacity(palette.isLight ? 0.06 : 0.26))
            }
    }

    @ViewBuilder
    private var controls: some View {
        if case let .selectingServer(servers) = viewModel.phase {
            // Continue (default focus) stacked above Cancel, matching the other
            // onboarding steps. Cancel here abandons the whole add, so confirm.
            VStack(spacing: 16) {
                Button {
                    viewModel.selectServers(servers.filter { selectedServerIDs.contains($0.id) })
                } label: {
                    Text("Continue").frame(minWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedServerIDs.isEmpty)
                .focused($focused, equals: .continueServers)

                Button(role: .cancel) {
                    requestCancel()
                } label: {
                    Text("Cancel").frame(minWidth: 260)
                }
                .focused($focused, equals: .cancel)
            }
        } else {
            HStack(spacing: 24) {
                Button(role: .cancel) {
                    requestCancel()
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

    /// Preselect owned servers (the ones people almost always want) the first
    /// time the picker is shown.
    private func seedSelectionIfNeeded(_ servers: [PlexServerCandidate]) {
        guard !didSeedSelection else { return }
        didSeedSelection = true
        selectedServerIDs = Set(servers.filter(\.isOwned).map(\.id))
    }
}

/// Multi-select picker shown when a Plex account can reach more than one server.
/// Mirrors the Settings checklist affordance: tap a row to toggle its checkmark.
/// The Continue/Cancel buttons live in the hosting view's footer.
private struct ServerList: View {
    let servers: [PlexServerCandidate]
    @Binding var selected: Set<String>

    var body: some View {
        VStack(spacing: 24) {
            Text("Choose your servers")
                .font(.title).bold()

            // Clipped scroll wrapped in a card (matching Settings). Inner gutters
            // give the row focus fill/shadow room so it isn't clipped by the card.
            PlozzScrollCard {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(servers) { server in
                            Button {
                                toggle(server.id)
                            } label: {
                                ServerCheckRow(
                                    name: server.name,
                                    subtitle: server.isOwned ? "Owned" : "Shared",
                                    isSelected: selected.contains(server.id)
                                )
                            }
                            .buttonStyle(SettingsFocusButtonStyle())
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 28)
                }
            }
            .frame(maxWidth: 900, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

/// One selectable server row. The checkmark reads the shared row-focus
/// environment so it inverts on a focused card (black check on the white dark
/// mode card / white check on the black light mode card) instead of vanishing.
private struct ServerCheckRow: View {
    let name: String
    let subtitle: String
    let isSelected: Bool

    @Environment(\.settingsRowIsFocused) private var focused
    @Environment(\.settingsRowFocusForeground) private var focusFg

    private var markColor: Color {
        if focused { return focusFg }
        return isSelected ? .accentColor : .secondary
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .settingsRowSecondary()
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(markColor)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
