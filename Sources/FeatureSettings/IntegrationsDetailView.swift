#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import TraktService
import SeerService
import SimklService
import AniListService
import MALService
import LastFmService

struct IntegrationsDetailView: View {
    let trakt: TraktService
    let simkl: SimklService
    let seer: SeerService
    let anilist: AniListService
    let mal: MALService
    let lastfm: LastFmService
    @Bindable var playback: PlaybackSettingsModel
    let serverCount: Int
    /// Hosts of already-configured media servers (Jellyfin/Plex/etc.), used to
    /// give Seerr auto-discovery a near-instant hit when it's co-hosted on the
    /// same box — very common for self-hosted setups.
    var knownServerHosts: [String] = []

    var body: some View {
        SettingsSplitLayout(title: "Integrations", sections: sections)
            .task {
                // Load all statuses up front so the left list's value
                // summaries are correct before any row is focused.
                async let t: Void = trakt.refreshStatus()
                async let s: Void = simkl.refreshStatus()
                async let a: Void = anilist.refreshStatus()
                async let m: Void = mal.refreshStatus()
                async let l: Void = lastfm.refreshStatus()
                async let se: Void = seer.refreshStatus()
                _ = await (t, s, a, m, l, se)
            }
    }

    private var sections: [SettingsSplitSection] {
        @Bindable var playback = playback

        let trackers = SettingsSplitSection(id: "trackers", header: "Trackers", rows: [
            SettingsSplitRow(
                id: "trakt",
                title: "Trakt",
                description: "Scrobble and sync your Jellyfin watch history to Trakt.",
            ) {
                if case let .connecting(userCode, verificationURL, expiresAt) = trakt.phase {
                    DeviceCodeConnectingView(
                        serviceName: "Trakt",
                        userCode: userCode,
                        verificationURL: verificationURL,
                        expiresAt: expiresAt,
                        codeLifetime: trakt.codeLifetime,
                        onCancel: { trakt.cancelConnect() }
                    )
                } else {
                    trackerActionBar(
                        phase: traktRowPhase,
                        onConnect: { trakt.connect() },
                        onCancel: { trakt.cancelConnect() },
                        onDisconnect: { Task { await trakt.disconnect() } }
                    )
                }
            },
            SettingsSplitRow(
                id: "simkl",
                title: "Simkl",
                description: "Sync your watch history and track what to watch next with Simkl.",
            ) {
                if case let .connecting(userCode, verificationURL, expiresAt) = simkl.phase {
                    DeviceCodeConnectingView(
                        serviceName: "Simkl",
                        userCode: userCode,
                        verificationURL: verificationURL,
                        expiresAt: expiresAt,
                        codeLifetime: simkl.codeLifetime,
                        onCancel: { simkl.cancelConnect() }
                    )
                } else {
                    trackerActionBar(
                        phase: simklRowPhase,
                        onConnect: { simkl.connect() },
                        onCancel: { simkl.cancelConnect() },
                        onDisconnect: { Task { await simkl.disconnect() } }
                    )
                }
            },
            SettingsSplitRow(
                id: "anilist",
                title: "AniList",
                description: "Track anime and manga progress on your AniList profile.",
            ) {
                if case .awaitingToken = anilist.phase {
                    AniListTokenEntryView(anilist: anilist)
                } else {
                    trackerActionBar(
                        phase: anilistRowPhase,
                        onConnect: { anilist.connect() },
                        onCancel: { anilist.cancelConnect() },
                        onDisconnect: { Task { await anilist.disconnect() } }
                    )
                }
            },
            SettingsSplitRow(
                id: "mal",
                title: "MyAnimeList",
                description: "Track anime and manga progress on your MyAnimeList profile.",
            ) {
                if case .awaitingAuthorizationCode = mal.phase {
                    MALAuthorizationCodeEntryView(mal: mal)
                } else {
                    trackerActionBar(
                        phase: malRowPhase,
                        onConnect: { mal.connect() },
                        onCancel: { mal.cancelConnect() },
                        onDisconnect: { Task { await mal.disconnect() } }
                    )
                }
            },
            SettingsSplitRow(
                id: "lastfm",
                title: "Last.fm",
                description: "Scrobble the music you play in Plozz to your Last.fm profile.",
            ) {
                if case let .connecting(authURL, _) = lastfm.phase {
                    LastFmConnectingView(
                        authURL: authURL,
                        onCancel: { lastfm.cancelConnect() }
                    )
                } else {
                    trackerActionBar(
                        phase: lastfmRowPhase,
                        onConnect: { lastfm.connect() },
                        onCancel: { lastfm.cancelConnect() },
                        onDisconnect: { Task { await lastfm.disconnect() } }
                    )
                }
            }
        ])

        let watchStatus = SettingsSplitSection(id: "watch-status", header: "Watch Status", rows: [
            SettingsSplitRow(
                id: "sync-across-servers",
                title: "Sync across all my servers",
                description: canSyncAcrossServers
                    ? (playback.settings.syncWatchAcrossServers
                        ? "Watching, resuming, or marking any media as watched updates every server that has it, keeping the same progress everywhere."
                        : "Only the server you watched on is updated.")
                    : "Add another server to sync watch status across servers.",
            ) {
                Toggle("Sync across all my servers", isOn: $playback.settings.syncWatchAcrossServers)
                    .disabled(!canSyncAcrossServers)
            }
        ])

        let discover = SettingsSplitSection(id: "discover", header: "Discover", rows: [
            SettingsSplitRow(
                id: "seerr",
                title: "Seerr",
                description: "Connect a Seerr server (formerly Overseerr or Jellyseerr) to surface trending titles in the Home hero and request movies & shows right from your Apple TV.",
            ) {
                SeerConfigurationView(seer: seer, knownServerHosts: knownServerHosts)
            }
        ])

        return [discover, trackers, watchStatus]
    }

    /// The status + action controls shown in a tracker's detail pane for every
    /// phase except the active connecting flow (which renders its own QR / code
    /// entry with its own Cancel). Reuses the same phase vocabulary as the old
    /// `TrackerRow` so behaviour is unchanged — just relocated to the detail pane.
    @ViewBuilder
    private func trackerActionBar(
        phase: TrackerRowPhase,
        onConnect: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onDisconnect: @escaping () -> Void
    ) -> some View {
        switch phase {
        case .loading:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Checking status…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .unavailable:
            Text("This tracker isn't configured in this build.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .disconnected:
            Button(action: onConnect) {
                Label("Connect", systemImage: "link")
            }
        case .connecting:
            Button(role: .cancel, action: onCancel) {
                Text("Cancel")
            }
        case let .connected(username):
            VStack(alignment: .leading, spacing: 18) {
                Label("Connected as \(username)", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Button(role: .destructive, action: onDisconnect) {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            }
        case .error:
            VStack(alignment: .leading, spacing: 18) {
                Label("Couldn't connect", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Button(action: onConnect) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: - Row phase mapping

    private var canSyncAcrossServers: Bool { serverCount >= 2 }

    private var traktRowPhase: TrackerRowPhase {
        switch trakt.phase {
        case .unknown: .loading
        case .unavailable: .unavailable
        case .disconnected: .disconnected
        case .connecting: .connecting
        case let .connected(name): .connected(name)
        case .error: .error
        }
    }

    private var simklRowPhase: TrackerRowPhase {
        switch simkl.phase {
        case .unknown: .loading
        case .unavailable: .unavailable
        case .disconnected: .disconnected
        case .connecting: .connecting
        case let .connected(name): .connected(name)
        case .error: .error
        }
    }

    private var anilistRowPhase: TrackerRowPhase {
        switch anilist.phase {
        case .unknown: .loading
        case .unavailable: .unavailable
        case .disconnected: .disconnected
        case .awaitingToken: .connecting
        case let .connected(name): .connected(name)
        case .error: .error
        }
    }

    private var malRowPhase: TrackerRowPhase {
        switch mal.phase {
        case .unknown: .loading
        case .unavailable: .unavailable
        case .disconnected: .disconnected
        case .awaitingAuthorizationCode: .connecting
        case let .connected(name): .connected(name)
        case .error: .error
        }
    }

    private var lastfmRowPhase: TrackerRowPhase {
        switch lastfm.phase {
        case .unknown: .loading
        case .unavailable: .unavailable
        case .disconnected: .disconnected
        case .connecting: .connecting
        case let .connected(name): .connected(name)
        case .error: .error
        }
    }
}

// MARK: - Tracker phase

/// The state a tracker row can be in (abstracted from service-specific enums).
enum TrackerRowPhase: Equatable {
    case loading
    case unavailable
    case disconnected
    case connecting
    case connected(String)
    case error
}

// MARK: - AniList Relay Code Entry (expanded panel)

struct AniListTokenEntryView: View {
    let anilist: AniListService
    @State private var codeInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan the QR code or visit the URL on your phone, sign in to AniList, then enter the code shown:")
                .font(.callout)
                .foregroundStyle(.secondary)

            if case let .awaitingToken(authorizationURL) = anilist.phase {
                HStack(alignment: .center, spacing: 32) {
                    QRCodeView(authorizationURL)
                        .frame(width: 160, height: 160)
                        .padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("plozz.app/anilist")
                            .font(.title3.weight(.semibold))
                        TextField("Enter code", text: $codeInput)
                        HStack(spacing: 16) {
                            Button("Connect") {
                                Task { await anilist.submitToken(codeInput) }
                            }
                            .disabled(codeInput.trimmingCharacters(in: .whitespaces).count < 4)
                            Button("Cancel", role: .cancel) {
                                anilist.cancelConnect()
                            }
                        }
                    }
                }
            }
        }
    }
}

struct MALAuthorizationCodeEntryView: View {
    let mal: MALService
    @State private var codeInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan the QR code or visit the URL on your phone, sign in to MyAnimeList, then enter the code shown:")
                .font(.callout)
                .foregroundStyle(.secondary)

            if case let .awaitingAuthorizationCode(authorizationURL) = mal.phase {
                HStack(alignment: .center, spacing: 32) {
                    QRCodeView(authorizationURL)
                        .frame(width: 160, height: 160)
                        .padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("plozz.app/myanimelist")
                            .font(.title3.weight(.semibold))
                        TextField("Enter code", text: $codeInput)
                        HStack(spacing: 16) {
                            Button("Connect") {
                                mal.submitAuthorizationCode(codeInput)
                            }
                            .disabled(codeInput.trimmingCharacters(in: .whitespacesAndNewlines).count < 4)
                            Button("Cancel", role: .cancel) {
                                mal.cancelConnect()
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shared Components

/// Last.fm desktop-auth connecting view. Shows a QR to the Last.fm approval page;
/// the user scans it and approves on their phone (NO code typed on the TV), and
/// the service polls in the background until it flips to Connected.
struct LastFmConnectingView: View {
    let authURL: String
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 32) {
            QRCodeView(authURL)
                .frame(width: 180, height: 180)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 12) {
                Text("Scan to connect Last.fm")
                    .font(.title2.weight(.semibold))
                Text("Scan the code with your phone and approve access on Last.fm. There's no code to type — this screen updates automatically once you approve.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460, alignment: .leading)
                HStack(spacing: 14) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for approval…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
                Button(role: .cancel, action: onCancel) {
                    Text("Cancel")
                }
                .padding(.top, 16)
            }

            Spacer(minLength: 0)
        }
    }
}

/// Reusable device-code connecting view (QR + code + countdown) for Trakt/Simkl.
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
        // Simkl uses path-based PIN URLs (e.g. simkl.com/pin/ABC12)
        if verificationURL.contains("simkl.com/pin") {
            let base = verificationURL.hasSuffix("/") ? verificationURL : verificationURL + "/"
            return "\(base)\(encoded)"
        }
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
                    "Plozzigen playback is powered by AetherEngine by Vincent Herbst. Source: github.com/superuser404notfound/AetherEngine",
                    licenses: [.lgpl("LGPL-3.0")]
                )
                attribution(
                    "FFmpeg",
                    "Audio/video decoding uses FFmpeg libraries (libavcodec, libavformat, libavutil, libswresample, libswscale, libavfilter, libavdevice). ffmpeg.org",
                    licenses: [.lgpl("LGPL-2.1+")]
                )
                attribution(
                    "mpv & mpvkit",
                    "Fallback playback uses mpv packaged by the mpvkit project. github.com/nicxleo/mpvkit",
                    licenses: [.gpl("GPL-2.0+")]
                )
                attribution(
                    "libdovi",
                    "Dolby Vision metadata parsing uses libdovi.",
                    licenses: [.mit()]
                )
                attribution(
                    "libass & Text Rendering",
                    "Subtitle rendering uses libass, FreeType, HarfBuzz, Fribidi, and Unibreak.",
                    licenses: [.isc(), .lgpl("LGPL-2.1"), .mit()]
                )
                attribution(
                    "dav1d",
                    "AV1 video decoding uses dav1d by VideoLAN.",
                    licenses: [.bsd("BSD-2")]
                )
                attribution(
                    "libplacebo & MoltenVK",
                    "GPU-accelerated video rendering uses libplacebo and MoltenVK for Vulkan-to-Metal translation.",
                    licenses: [.lgpl("LGPL-2.1"), .apache()]
                )
                attribution(
                    "GnuTLS & Networking",
                    "TLS and network transport use GnuTLS, Nettle, GMP, AMSMB2, and OpenSSL.",
                    licenses: [.lgpl("LGPL-2.1"), .lgpl("LGPL-3.0"), .apache()]
                )
                attribution(
                    "libbluray",
                    "Blu-ray disc structure parsing uses libbluray.",
                    licenses: [.lgpl("LGPL-2.1")]
                )
                attribution(
                    "TMDB",
                    "This product uses the TMDB API but is not endorsed or certified by TMDB. Artwork and metadata are provided by TMDB (themoviedb.org).",
                    licenses: [.api()]
                )
                attribution(
                    "OMDb & AniList",
                    "Additional ratings are sourced from the OMDb API (omdbapi.com) and AniList (anilist.co). Neither endorses or is affiliated with Plozz.",
                    licenses: [.api()]
                )
                attribution(
                    "Watch Tracking",
                    "Watch-history sync integrations — Trakt (trakt.tv), Simkl (simkl.com), AniList (anilist.co), and MyAnimeList (myanimelist.net) — use their respective public APIs. None endorses or is affiliated with Plozz.",
                    licenses: [.api()]
                )
                attribution(
                    "Wikidata",
                    "Fallback artwork lookup uses the Wikidata Query Service (wikidata.org).",
                    licenses: [.cc0()]
                )
                attribution(
                    "Fonts",
                    "The default subtitle typeface is Atkinson Hyperlegible, © 2020 Braille Institute of America, Inc., chosen for its legibility from a distance. UI accent type uses Bungee by David Jonathan Ross. Both are used under the SIL Open Font License 1.1.",
                    licenses: [.ofl()]
                )
                attribution(
                    "YouTubeKit",
                    "Trailer playback uses YouTubeKit by Alexander Eichhorn.",
                    licenses: [.mit()]
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
    }

    private func attribution(_ title: String, _ text: String, licenses: [LicenseBadge] = []) -> some View {
        AttributionCard(title: title, text: text, licenses: licenses)
    }
}

/// A single focusable credit card with the shared inverted-card focus look
/// and optional license badge pills.
private struct AttributionCard: View {
    let title: String
    let text: String
    var licenses: [LicenseBadge] = []

    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var focusFill: Color { colorScheme == .dark ? .white : .black }
    private var focusForeground: Color { colorScheme == .dark ? .black : .white }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.headline.weight(.semibold))
                Spacer()
                ForEach(licenses) { badge in
                    badge.view(focused: isFocused)
                }
            }
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
        .accessibilityLabel("\(title). \(licenses.map(\.label).joined(separator: ", ")). \(text)")
    }
}

/// A license badge model with a tint color category.
private struct LicenseBadge: Identifiable {
    let id: String
    let label: String
    let tint: Color

    func view(focused: Bool) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(focused ? Color.black : .white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(focused ? tint.opacity(0.85) : tint.opacity(0.7))
            )
    }

    // Factory presets for common license families
    static func gpl(_ version: String = "GPL-3.0") -> LicenseBadge {
        LicenseBadge(id: version, label: version, tint: Color(red: 0.85, green: 0.25, blue: 0.25))
    }
    static func lgpl(_ version: String = "LGPL-3.0") -> LicenseBadge {
        LicenseBadge(id: version, label: version, tint: Color(red: 0.9, green: 0.45, blue: 0.2))
    }
    static func mit() -> LicenseBadge {
        LicenseBadge(id: "MIT", label: "MIT", tint: Color(red: 0.2, green: 0.65, blue: 0.35))
    }
    static func apache() -> LicenseBadge {
        LicenseBadge(id: "Apache-2.0", label: "Apache-2.0", tint: Color(red: 0.2, green: 0.5, blue: 0.8))
    }
    static func bsd(_ variant: String = "BSD-2") -> LicenseBadge {
        LicenseBadge(id: variant, label: variant, tint: Color(red: 0.4, green: 0.55, blue: 0.7))
    }
    static func cc0() -> LicenseBadge {
        LicenseBadge(id: "CC0", label: "CC0", tint: Color(red: 0.5, green: 0.5, blue: 0.5))
    }
    static func isc() -> LicenseBadge {
        LicenseBadge(id: "ISC", label: "ISC", tint: Color(red: 0.3, green: 0.6, blue: 0.5))
    }
    static func ofl() -> LicenseBadge {
        LicenseBadge(id: "OFL-1.1", label: "OFL-1.1", tint: Color(red: 0.45, green: 0.45, blue: 0.8))
    }
    static func api() -> LicenseBadge {
        LicenseBadge(id: "API", label: "API", tint: Color(red: 0.55, green: 0.4, blue: 0.7))
    }
}

/// Detail-pane controls for the Seerr integration. Unlike the OAuth trackers
/// (device-code flows), Seerr is self-hosted, so this collects a server URL and
/// an admin API key, then drives ``SeerService/connect(baseURL:apiKey:userId:)``
/// and reflects the resulting ``SeerConnectionPhase``.
private struct SeerConfigurationView: View {
    let seer: SeerService
    var knownServerHosts: [String] = []

    @State private var urlText: String = ""
    @State private var apiKeyText: String = ""
    @State private var didPrefill = false
    @State private var discovered: [DiscoveredSeerServer] = []
    @State private var discoveryScanning = false
    private let discovery = SeerDiscovery()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch seer.phase {
            case let .connected(summary):
                connectedView(summary: summary)
            default:
                entryView
            }
        }
        .onAppear {
            guard !didPrefill else { return }
            didPrefill = true
            if let saved = seer.savedBaseURLString { urlText = saved }
        }
    }

    @ViewBuilder
    private var entryView: some View {
        VStack(alignment: .leading, spacing: 16) {
            discoveredSection

            TextField("Server address (e.g. https://requests.example.com)", text: $urlText)
                .textContentType(.URL)
                #if os(tvOS) || os(iOS)
                .keyboardType(.URL)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                #endif

            SecureField("Admin API key", text: $apiKeyText)
                .textContentType(.password)
                #if os(tvOS) || os(iOS)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                #endif

            if case .connecting = seer.phase {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(action: connect) {
                    Label("Connect", systemImage: "link")
                }
                .disabled(!canConnect)
            }

            if case let .failed(message) = seer.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await scanForServers() }
    }

    /// Auto-discovered Seerr servers on the local network — tapping a row
    /// fills the address field, but the API key still has to be entered by
    /// hand (finding a server needs no auth; connecting to it does).
    @ViewBuilder
    private var discoveredSection: some View {
        if discoveryScanning || !discovered.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("On your network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if discoveryScanning {
                        ProgressView().controlSize(.small)
                    }
                }
                ForEach(discovered) { server in
                    Button {
                        urlText = server.baseURL.absoluteString
                    } label: {
                        HStack {
                            Label(server.baseURL.host ?? server.baseURL.absoluteString, systemImage: "server.rack")
                            Spacer()
                            if let version = server.version {
                                Text("v\(version)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func scanForServers() async {
        discoveryScanning = true
        defer { discoveryScanning = false }
        for await server in discovery.discover(hostHints: knownServerHosts) {
            if !discovered.contains(where: { $0.id == server.id }) {
                discovered.append(server)
            }
        }
    }

    @ViewBuilder
    private func connectedView(summary: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Connected", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            if !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let host = seer.savedBaseURLString {
                Text(host)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                seer.disconnect()
                apiKeyText = ""
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        }
    }

    private var canConnect: Bool {
        SeerConfig.normalizedBaseURL(from: urlText) != nil
            && !apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func connect() {
        guard let url = SeerConfig.normalizedBaseURL(from: urlText) else { return }
        let key = apiKeyText
        Task { await seer.connect(baseURL: url, apiKey: key) }
    }
}
#endif
