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
                // tvOS requires at least one focusable element on a pushed
                // view, otherwise focus is unanchored and Menu/Back falls
                // through to the system and exits the app. An enabled but
                // inert button keeps focus inside this view so Back pops.
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

/// Open-source credits & licensing — the one acceptable level deeper from the
/// inline About section on the main Settings page. Each credit is a focusable
/// inverted-card so the page is reachable on the 10-foot UI and Menu/Back pops
/// reliably (a fully non-interactive page can trap focus and quit the app).
struct AttributionsDetailView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Attributions & Licensing").font(.largeTitle.bold())

                Text("Plozz is free and open source under the GPL-3.0 license with an App Store exception. It is not affiliated with, endorsed, or certified by any of the projects or services listed below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                attribution(
                    "Media Servers",
                    "Jellyfin is a free software media system; Plozz is an unofficial client and is not affiliated with the Jellyfin project. Plex is a trademark of Plex, Inc.; Plozz is an unofficial client and is not endorsed by Plex, Inc."
                )
                attribution(
                    "Brand Marks",
                    "The Plex and Jellyfin logos are used nominatively to identify which server type an account connects to. They are unmodified and are not used as Plozz branding."
                )
                attribution(
                    "AetherEngine",
                    "Plozzigen playback is powered by AetherEngine by Vincent Herbst, licensed under the LGPL-3.0 with an App Store / DRM exception. Source: github.com/superuser404notfound/AetherEngine"
                )
                attribution(
                    "FFmpeg",
                    "Audio/video decoding uses FFmpeg libraries (libavcodec, libavformat, libavutil, libswresample, libswscale, libavfilter) licensed under the LGPL/GPL. ffmpeg.org"
                )
                attribution(
                    "mpv & mpvkit",
                    "Fallback playback uses mpv (licensed under GPL-2.0+) and the FFmpeg-family libraries (libass, dav1d, libplacebo) packaged by the mpvkit project."
                )
                attribution(
                    "libdovi",
                    "Dolby Vision metadata parsing uses libdovi, licensed under the MIT license."
                )
                attribution(
                    "TMDB",
                    "This product uses the TMDB API but is not endorsed or certified by TMDB. Artwork and metadata are provided by TMDB (themoviedb.org)."
                )
                attribution(
                    "OMDb & AniList",
                    "Additional ratings are sourced from the OMDb API (omdbapi.com) and AniList (anilist.co). Neither endorses or is affiliated with Plozz."
                )
                attribution(
                    "Wikidata",
                    "Fallback artwork lookup uses the Wikidata Query Service (wikidata.org), available under the CC0 public domain dedication."
                )
                attribution(
                    "YouTubeKit",
                    "Trailer playback uses YouTubeKit by Alexander Eichhorn, licensed under the MIT license."
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

/// A single focusable credit card with the shared inverted-card focus look.
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
