#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import TraktService

struct IntegrationsDetailView: View {
    let trakt: TraktService

    private var traktFooter: String? {
        switch trakt.phase {
        case .connecting, .connected:
            return nil
        default:
            return "Connect Trakt to automatically scrobble what you watch to your Trakt.tv history. Each profile connects to its own Trakt account."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Integrations").font(.largeTitle.bold())
                SettingsPanel(title: "Trakt", footer: traktFooter) {
                    TraktConnectionView(trakt: trakt)
                }
            }
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
    }
}

/// The Trakt connect/disconnect flow rendered inside the Integrations panel.
///
/// Driven entirely by the observable `TraktService.phase`, so connecting in
/// one place and the live device-code prompt stay in sync. The device-code
/// flow is the TV-friendly OAuth grant: we show a short code and the user
/// approves it at `trakt.tv/activate` on a phone or computer.
struct TraktConnectionView: View {
    let trakt: TraktService

    private enum Field: Hashable { case connect, cancel, disconnect, retry }
    @FocusState private var focus: Field?

    private enum PhaseTag: Equatable { case unknown, unavailable, disconnected, connecting, connected, error }
    private var phaseTag: PhaseTag {
        switch trakt.phase {
        case .unknown: return .unknown
        case .unavailable: return .unavailable
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .connected: return .connected
        case .error: return .error
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch trakt.phase {
            case .unknown:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Checking Trakt connection…")
                        .foregroundStyle(.secondary)
                }

            case .unavailable:
                Text("Trakt sync isn't configured in this build. Add a Trakt client id and secret to enable it.")
                    .foregroundStyle(.secondary)

            case .disconnected:
                Button(action: { trakt.connect() }) {
                    Label("Connect to Trakt", systemImage: "link")
                }
                .focused($focus, equals: .connect)
                .frame(maxWidth: .infinity, alignment: .leading)

            case let .connecting(userCode, verificationURL, expiresAt):
                connectingView(userCode: userCode, verificationURL: verificationURL, expiresAt: expiresAt)

            case let .connected(username):
                connectedView(username: username)

            case let .error(message):
                VStack(alignment: .leading, spacing: 12) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                    Button(action: { trakt.connect() }) {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                    .focused($focus, equals: .retry)
                }
            }
        }
        .task { await trakt.refreshStatus() }
        .onChange(of: phaseTag) { _, tag in
            guard focus != nil else { return }
            switch tag {
            case .connecting: focus = .cancel
            case .disconnected: focus = .connect
            case .connected: focus = .disconnect
            case .error: focus = .retry
            default: break
            }
        }
    }

    private func connectingView(userCode: String, verificationURL: String, expiresAt: Date) -> some View {
        HStack(alignment: .center, spacing: 32) {
            QRCodeView(activationURL(userCode: userCode, verificationURL: verificationURL))
                .frame(width: 180, height: 180)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))

            Text("OR")
                .font(.title3.weight(.bold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Text(displayURL(verificationURL))
                    .font(.title2.weight(.semibold))
                Text(userCode)
                    .font(.plozzCode(size: 52))
                    .tracking(8)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                HStack(spacing: 14) {
                    TraktExpiryCountdown(expiresAt: expiresAt, lifetime: trakt.codeLifetime)
                        .frame(width: 64, height: 64)
                    Text("Waiting for approval…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button(role: .cancel, action: { trakt.cancelConnect() }) {
                    Text("Cancel")
                }
                .focused($focus, equals: .cancel)
                .padding(.top, 16)
            }

            Spacer(minLength: 0)
        }
    }

    private func activationURL(userCode: String, verificationURL: String) -> String {
        let encoded = userCode.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? userCode
        return "\(verificationURL)?code=\(encoded)"
    }

    private func connectedView(username: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(username).font(.headline)
                Text("Your watches sync to Trakt")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                Task { await trakt.disconnect() }
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
            .focused($focus, equals: .disconnect)
        }
    }

    private func displayURL(_ url: String) -> String {
        var trimmed = url
        for prefix in ["https://", "http://"] where trimmed.hasPrefix(prefix) {
            trimmed.removeFirst(prefix.count)
        }
        return trimmed
    }
}

/// Compact ring that depletes over the life of the current Trakt device code,
/// with the seconds remaining at its centre, shifting to a warning tint as
/// the deadline nears. The code auto-refreshes on expiry, so this just resets.
struct TraktExpiryCountdown: View {
    let expiresAt: Date
    let lifetime: TimeInterval

    var body: some View {
        TimelineView(.animation) { context in
            let remaining = max(0, expiresAt.timeIntervalSince(context.date))
            let fraction = lifetime > 0 ? remaining / lifetime : 0
            let tint: Color = remaining <= 30 ? .orange : .accentColor

            ZStack {
                Circle()
                    .stroke(tint.opacity(0.18), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(Self.format(remaining, lifetime: lifetime))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
            }
            .animation(.easeOut(duration: 0.3), value: tint)
            .accessibilityLabel("Code expires in \(Self.format(remaining, lifetime: lifetime))")
        }
    }

    private static func format(_ remaining: TimeInterval, lifetime: TimeInterval) -> String {
        let cap = lifetime > 0 ? Int(lifetime.rounded(.up)) - 1 : Int.max
        let total = min(Int(remaining.rounded(.up)), cap)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct AboutDetailView: View {
    let version: String
    let build: String
    let repoURL: String
    let canSignOut: Bool
    let onSignOutAll: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("About").font(.largeTitle.bold())
                SettingsPanel(title: "About") {
                    SettingsAboutSection(version: version, build: build, repoURL: repoURL)
                }
                if canSignOut {
                    SettingsPanel(title: "Sign Out") {
                        Button(role: .destructive, action: onSignOutAll) {
                            Label("Sign Out of All Accounts", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
    }
}
#endif
