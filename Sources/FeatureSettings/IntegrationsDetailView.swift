#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import TraktService
import SimklService
import AniListService
import MALService

struct IntegrationsDetailView: View {
    let trakt: TraktService
    let simkl: SimklService
    let anilist: AniListService
    let mal: MALService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Integrations").font(.largeTitle.bold())

                SettingsPanel(title: "Trakt", footer: traktFooter) {
                    TraktConnectionView(trakt: trakt)
                }

                SettingsPanel(title: "Simkl", footer: simklFooter) {
                    SimklConnectionView(simkl: simkl)
                }

                SettingsPanel(title: "AniList", footer: anilistFooter) {
                    AniListConnectionView(anilist: anilist)
                }

                SettingsPanel(title: "MyAnimeList", footer: malFooter) {
                    MALConnectionView(mal: mal)
                }
            }
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
    }

    private var traktFooter: String? {
        switch trakt.phase {
        case .connecting, .connected: return nil
        default: return "Connect Trakt to automatically scrobble what you watch to your Trakt.tv history. Each profile connects to its own Trakt account."
        }
    }

    private var simklFooter: String? {
        switch simkl.phase {
        case .connecting, .connected: return nil
        default: return "Connect Simkl to sync movies, shows, and anime to your Simkl watchlist."
        }
    }

    private var anilistFooter: String? {
        switch anilist.phase {
        case .awaitingToken, .connected: return nil
        default: return "Connect AniList to automatically track your anime progress. Only anime with AniList/MAL metadata will be tracked."
        }
    }

    private var malFooter: String? {
        switch mal.phase {
        case .connecting, .connected: return nil
        default: return "Connect MyAnimeList to automatically update your anime list. Only anime with MAL metadata will be tracked."
        }
    }
}

// MARK: - Trakt Connection View

/// The Trakt connect/disconnect flow rendered inside the Integrations panel.
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
                VStack(alignment: .leading, spacing: 16) {
                    Text("Trakt sync isn't configured in this build. Add a Trakt client id and secret to enable it.")
                        .foregroundStyle(.secondary)
                    Button { /* no-op — anchors focus */ } label: {
                        Label("Trakt unavailable", systemImage: "xmark.circle")
                    }
                    .focused($focus, equals: .connect)
                }

            case .disconnected:
                Button(action: { trakt.connect() }) {
                    Label("Connect to Trakt", systemImage: "link")
                }
                .focused($focus, equals: .connect)
                .frame(maxWidth: .infinity, alignment: .leading)

            case let .connecting(userCode, verificationURL, expiresAt):
                DeviceCodeConnectingView(
                    serviceName: "Trakt",
                    userCode: userCode,
                    verificationURL: verificationURL,
                    expiresAt: expiresAt,
                    codeLifetime: trakt.codeLifetime,
                    onCancel: { trakt.cancelConnect() }
                )

            case let .connected(username):
                TrackerConnectedView(username: username, serviceName: "Trakt") {
                    Task { await trakt.disconnect() }
                }

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
}

// MARK: - Simkl Connection View

struct SimklConnectionView: View {
    let simkl: SimklService

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch simkl.phase {
            case .unknown:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Checking Simkl connection…").foregroundStyle(.secondary)
                }
            case .unavailable:
                Text("Simkl sync isn't configured in this build. Add a Simkl client id and secret to enable it.")
                    .foregroundStyle(.secondary)
            case .disconnected:
                Button(action: { simkl.connect() }) {
                    Label("Connect to Simkl", systemImage: "link")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case let .connecting(userCode, verificationURL, expiresAt):
                DeviceCodeConnectingView(
                    serviceName: "Simkl",
                    userCode: userCode,
                    verificationURL: verificationURL,
                    expiresAt: expiresAt,
                    codeLifetime: simkl.codeLifetime,
                    onCancel: { simkl.cancelConnect() }
                )
            case let .connected(username):
                TrackerConnectedView(username: username, serviceName: "Simkl") {
                    Task { await simkl.disconnect() }
                }
            case let .error(message):
                VStack(alignment: .leading, spacing: 12) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                    Button(action: { simkl.connect() }) {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .task { await simkl.refreshStatus() }
    }
}

// MARK: - AniList Connection View

struct AniListConnectionView: View {
    let anilist: AniListService
    @State private var tokenInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch anilist.phase {
            case .unknown:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Checking AniList connection…").foregroundStyle(.secondary)
                }
            case .unavailable:
                Text("AniList sync isn't configured in this build. Add an AniList client id to enable it.")
                    .foregroundStyle(.secondary)
            case .disconnected:
                Button(action: { anilist.connect() }) {
                    Label("Connect to AniList", systemImage: "link")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case let .awaitingToken(authorizationURL):
                VStack(alignment: .leading, spacing: 16) {
                    Text("Visit this URL on your phone or computer, authorize Plozz, then paste the token below:")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .center, spacing: 32) {
                        QRCodeView(authorizationURL)
                            .frame(width: 160, height: 160)
                            .padding(10)
                            .background(.white, in: RoundedRectangle(cornerRadius: 14))

                        VStack(alignment: .leading, spacing: 12) {
                            Text("anilist.co/api/v2/oauth/authorize")
                                .font(.title3.weight(.semibold))
                            TextField("Paste access token here", text: $tokenInput)
                            HStack(spacing: 16) {
                                Button("Submit Token") {
                                    Task { await anilist.submitToken(tokenInput) }
                                }
                                .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                                Button("Cancel", role: .cancel) {
                                    anilist.cancelConnect()
                                }
                            }
                        }
                    }
                }
            case let .connected(username):
                TrackerConnectedView(username: username, serviceName: "AniList") {
                    Task { await anilist.disconnect() }
                }
            case let .error(message):
                VStack(alignment: .leading, spacing: 12) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                    Button(action: { anilist.connect() }) {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .task { await anilist.refreshStatus() }
    }
}

// MARK: - MAL Connection View

struct MALConnectionView: View {
    let mal: MALService

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch mal.phase {
            case .unknown:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Checking MyAnimeList connection…").foregroundStyle(.secondary)
                }
            case .unavailable:
                Text("MyAnimeList sync isn't configured in this build. Add a MAL client id to enable it.")
                    .foregroundStyle(.secondary)
            case .disconnected:
                Button(action: { mal.connect() }) {
                    Label("Connect to MyAnimeList", systemImage: "link")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case let .connecting(userCode, verificationURL, expiresAt):
                DeviceCodeConnectingView(
                    serviceName: "MyAnimeList",
                    userCode: userCode,
                    verificationURL: verificationURL,
                    expiresAt: expiresAt,
                    codeLifetime: mal.codeLifetime,
                    onCancel: { mal.cancelConnect() }
                )
            case let .connected(username):
                TrackerConnectedView(username: username, serviceName: "MyAnimeList") {
                    Task { await mal.disconnect() }
                }
            case let .error(message):
                VStack(alignment: .leading, spacing: 12) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                    Button(action: { mal.connect() }) {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .task { await mal.refreshStatus() }
    }
}

// MARK: - Shared Components

/// Reusable device-code connecting view (QR + code + countdown) for Trakt/Simkl/MAL.
struct DeviceCodeConnectingView: View {
    let serviceName: String
    let userCode: String
    let verificationURL: String
    let expiresAt: Date
    let codeLifetime: TimeInterval
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 32) {
            QRCodeView(activationURL)
                .frame(width: 180, height: 180)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))

            Text("OR")
                .font(.title3.weight(.bold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Text(displayURL)
                    .font(.title2.weight(.semibold))
                Text(userCode)
                    .font(.plozzCode(size: 52))
                    .tracking(8)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                HStack(spacing: 14) {
                    TraktExpiryCountdown(expiresAt: expiresAt, lifetime: codeLifetime)
                        .frame(width: 64, height: 64)
                    Text("Waiting for approval…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button(role: .cancel, action: onCancel) {
                    Text("Cancel")
                }
                .padding(.top, 16)
            }

            Spacer(minLength: 0)
        }
    }

    private var activationURL: String {
        let encoded = userCode.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? userCode
        return "\(verificationURL)?code=\(encoded)"
    }

    private var displayURL: String {
        var trimmed = verificationURL
        for prefix in ["https://", "http://"] where trimmed.hasPrefix(prefix) {
            trimmed.removeFirst(prefix.count)
        }
        return trimmed
    }
}

/// Shared connected-state view showing username + disconnect button.
struct TrackerConnectedView: View {
    let username: String
    let serviceName: String
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(username).font(.headline)
                Text("Your watches sync to \(serviceName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: onDisconnect) {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        }
    }
}

/// Compact ring that depletes over the life of a device code.
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

/// Open-source credits & licensing.
struct AttributionsDetailView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Attributions & Licensing").font(.largeTitle.bold())

                Text("Plozz is free and open source, and stands on the shoulders of these projects and services. It is not affiliated with, endorsed, or certified by any of them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                attribution(
                    "Media servers",
                    "Jellyfin — the free software media system. Plozz is an unofficial client and is not affiliated with the Jellyfin project. Plex is a trademark of Plex, Inc.; Plozz is an unofficial client and is not affiliated with or endorsed by Plex, Inc."
                )
                attribution(
                    "Brand marks",
                    "The Plex and Jellyfin logos are used nominatively, solely to identify which server type an account connects to. They are unmodified and are not used as Plozz's own branding."
                )
                attribution(
                    "Playback",
                    "Playback is powered by mpv and libmpv (GPL/LGPL), together with the FFmpeg-family libraries (libass, dav1d, libplacebo, libbluray, and related components) packaged by the mpvkit project."
                )
                attribution(
                    "Metadata & Tracking",
                    "This product uses the TMDB API but is not endorsed or certified by TMDB. Additional ratings and metadata are supplied by your media server and by TMDB, OMDb, and AniList. Watch tracking integrations (Trakt, Simkl, AniList, MyAnimeList) use their respective APIs but are not affiliated with those services."
                )
                attribution(
                    "Swift packages",
                    "YouTubeKit and additional open-source Swift packages are used under their respective licenses."
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
    }

    private func attribution(_ title: String, _ text: String) -> some View {
        AttributionCard(title: title, text: text)
    }
}

/// A single focusable credit card.
private struct AttributionCard: View {
    let title: String
    let text: String

    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var focusFill: Color { colorScheme == .dark ? .white : .black }
    private var focusForeground: Color { colorScheme == .dark ? .black : .white }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline.weight(.semibold))
            Text(text)
                .font(.callout)
                .foregroundStyle(isFocused ? AnyShapeStyle(focusForeground.opacity(0.78)) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .foregroundStyle(isFocused ? AnyShapeStyle(focusForeground) : AnyShapeStyle(.primary))
        .background(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .fill(isFocused ? AnyShapeStyle(focusFill) : AnyShapeStyle(.ultraThinMaterial))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(isFocused ? 0 : 0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isFocused ? 0.28 : 0), radius: isFocused ? 14 : 0, y: isFocused ? 6 : 0)
        .focusable()
        .focused($isFocused)
        .animation(.easeOut(duration: 0.16), value: isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(text)")
    }
}
#endif
