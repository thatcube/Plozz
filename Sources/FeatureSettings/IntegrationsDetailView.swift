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
    @Bindable var playback: PlaybackSettingsModel
    let serverCount: Int
    @Namespace private var trackerFocus

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Trackers").font(.largeTitle.bold())
                    Text("Connected per profile. Watches are tracked no matter which server you're on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Unified tracker card — all services in one dense panel
                VStack(alignment: .leading, spacing: 0) {
                    // Trakt
                    VStack(alignment: .leading, spacing: 24) {
                        TrackerRow(name: "Trakt", phase: traktRowPhase, onConnect: { trakt.connect() }, onCancel: { trakt.cancelConnect() }, onDisconnect: { Task { await trakt.disconnect() } })
                            .task { await trakt.refreshStatus() }
                        if case let .connecting(userCode, verificationURL, expiresAt) = trakt.phase {
                            DeviceCodeConnectingView(serviceName: "Trakt", userCode: userCode, verificationURL: verificationURL, expiresAt: expiresAt, codeLifetime: trakt.codeLifetime, onCancel: { trakt.cancelConnect() })
                        }
                        sectionDivider
                    }
                    .padding(.bottom, 24)
                    .prefersDefaultFocus(true, in: trackerFocus)
                    .focusSection()

                    // Simkl
                    VStack(alignment: .leading, spacing: 24) {
                        TrackerRow(name: "Simkl", phase: simklRowPhase, onConnect: { simkl.connect() }, onCancel: { simkl.cancelConnect() }, onDisconnect: { Task { await simkl.disconnect() } })
                            .task { await simkl.refreshStatus() }
                        if case let .connecting(userCode, verificationURL, expiresAt) = simkl.phase {
                            DeviceCodeConnectingView(serviceName: "Simkl", userCode: userCode, verificationURL: verificationURL, expiresAt: expiresAt, codeLifetime: simkl.codeLifetime, onCancel: { simkl.cancelConnect() })
                        }
                        sectionDivider
                    }
                    .padding(.bottom, 24)
                    .focusSection()

                    // AniList
                    VStack(alignment: .leading, spacing: 24) {
                        TrackerRow(name: "AniList", phase: anilistRowPhase, onConnect: { anilist.connect() }, onCancel: { anilist.cancelConnect() }, onDisconnect: { Task { await anilist.disconnect() } })
                            .task { await anilist.refreshStatus() }
                        if case .awaitingToken = anilist.phase {
                            AniListTokenEntryView(anilist: anilist)
                        }
                        sectionDivider
                    }
                    .padding(.bottom, 24)
                    .focusSection()

                    // MyAnimeList
                    VStack(alignment: .leading, spacing: 24) {
                        TrackerRow(name: "MyAnimeList", phase: malRowPhase, onConnect: { mal.connect() }, onCancel: { mal.cancelConnect() }, onDisconnect: { Task { await mal.disconnect() } })
                            .task { await mal.refreshStatus() }
                        if case .awaitingAuthorizationCode = mal.phase {
                            MALAuthorizationCodeEntryView(mal: mal)
                        }
                    }
                    .focusSection()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
                .background(
                    RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

                SettingsPanel(
                    title: "Watch Status",
                    footer: canSyncAcrossServers
                        ? (playback.settings.syncWatchAcrossServers
                            ? "Marking or resuming a title updates every server that has it."
                            : "Only the server you watched on is updated.")
                        : "Add another server to sync watch status across servers."
                ) {
                    Toggle("Sync across all my servers", isOn: $playback.settings.syncWatchAcrossServers)
                        .disabled(!canSyncAcrossServers)
                }
            }
            .focusScope(trackerFocus)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
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

    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, -27)
    }
}

// MARK: - Unified Tracker Row

/// The state a tracker row can be in (abstracted from service-specific enums).
enum TrackerRowPhase: Equatable {
    case loading
    case unavailable
    case disconnected
    case connecting
    case connected(String)
    case error
}

/// A single row inside the unified tracker card. Shows the service name, a
/// status badge, and a connect/disconnect action — all on one line. Mirrors the
/// `LabeledSettingRow` density pattern from Appearance.
struct TrackerRow: View {
    let name: String
    let phase: TrackerRowPhase
    let onConnect: () -> Void
    let onCancel: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text(name)
                .font(.headline.weight(.semibold))
                .frame(width: 180, alignment: .leading)

            switch phase {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                Spacer()

            case .unavailable:
                Text("Not configured")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Spacer()

            case .disconnected:
                Spacer()
                Button(action: onConnect) {
                    Label("Connect", systemImage: "link")
                }

            case .connecting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .cancel, action: onCancel) {
                    Text("Cancel")
                        .font(.subheadline)
                }

            case let .connected(username):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text(username)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive, action: onDisconnect) {
                    Label("Disconnect", systemImage: "xmark.circle")
                        .font(.subheadline)
                }

            case .error:
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Error")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onConnect) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                }
            }
        }
    }
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
    static func api() -> LicenseBadge {
        LicenseBadge(id: "API", label: "API", tint: Color(red: 0.55, green: 0.4, blue: 0.7))
    }
}
#endif
