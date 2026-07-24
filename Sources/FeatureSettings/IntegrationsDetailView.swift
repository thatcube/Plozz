#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import TraktService
import SimklService
import AniListService
import MALService
import LastFmService

struct IntegrationsDetailView: View {
    let trakt: TraktService
    let simkl: SimklService
    let anilist: AniListService
    let mal: MALService
    let lastfm: LastFmService
    @Bindable var playback: PlaybackSettingsModel
    let serverCount: Int

    var body: some View {
        SettingsSplitLayout(title: "Trackers", sections: sections)
            .task {
                // Load all statuses up front so the left list's value
                // summaries are correct before any row is focused.
                async let t: Void = trakt.refreshStatus()
                async let s: Void = simkl.refreshStatus()
                async let a: Void = anilist.refreshStatus()
                async let m: Void = mal.refreshStatus()
                async let l: Void = lastfm.refreshStatus()
                _ = await (t, s, a, m, l)
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

        return [trackers, watchStatus]
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
                        .background(.white, in: RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control))

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
                        .background(.white, in: RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control))

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
                .background(.white, in: RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control))

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
                .background(.white, in: RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control))

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
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control))
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
                Text(PlozzAttributions.introduction)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(PlozzAttributions.entries) { entry in
                    AttributionCard(
                        title: entry.title,
                        text: entry.detail,
                        licenses: entry.licenses
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
    }

}

/// A single focusable credit card with the shared inverted-card focus look
/// and optional license badge pills.
private struct AttributionCard: View {
    let title: String
    let text: String
    var licenses: [PlozzAttributionLicense] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.headline.weight(.semibold))
                Spacer()
                ForEach(licenses) { badge in
                    licenseBadge(badge)
                }
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .plozzFocusableCard(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(licenses.map(\.label).joined(separator: ", ")). \(text)")
    }

    private func licenseBadge(_ license: PlozzAttributionLicense) -> some View {
        Text(license.label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(licenseTint(license.family).opacity(0.7))
            )
    }

    private func licenseTint(_ family: PlozzAttributionLicense.Family) -> Color {
        switch family {
        case .gpl:
            Color(red: 0.85, green: 0.25, blue: 0.25)
        case .lgpl:
            Color(red: 0.9, green: 0.45, blue: 0.2)
        case .mit:
            Color(red: 0.2, green: 0.65, blue: 0.35)
        case .apache:
            Color(red: 0.2, green: 0.5, blue: 0.8)
        case .bsd:
            Color(red: 0.4, green: 0.55, blue: 0.7)
        case .cc0:
            Color(red: 0.5, green: 0.5, blue: 0.5)
        case .isc:
            Color(red: 0.3, green: 0.6, blue: 0.5)
        case .ofl:
            Color(red: 0.45, green: 0.45, blue: 0.8)
        case .api:
            Color(red: 0.55, green: 0.4, blue: 0.7)
        }
    }
}

#endif
