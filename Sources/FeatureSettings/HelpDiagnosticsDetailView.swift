#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreNetworking
import CoreUI

public struct SearchIndexDiagnosticsSnapshot: Equatable, Sendable {
    public var documentCount: Int
    public var databaseBytes: UInt64
    public var isBuilding: Bool
    public var queuedScopes: Int
    public var pausedReason: String?

    public init(
        documentCount: Int = 0,
        databaseBytes: UInt64 = 0,
        isBuilding: Bool = false,
        queuedScopes: Int = 0,
        pausedReason: String? = nil
    ) {
        self.documentCount = documentCount
        self.databaseBytes = databaseBytes
        self.isBuilding = isBuilding
        self.queuedScopes = queuedScopes
        self.pausedReason = pausedReason
    }
}

/// Level-2 "Help & Diagnostics" page: the user-facing bug-report path plus the
/// on-device diagnostics controls.
///
/// tvOS has no keyboard-friendly text entry and no browser, and Plozz ships with
/// no backend — so the report flow is a **QR code to a pre-filled GitHub issue**
/// the user opens on their phone (with a short manual URL + a feedback email as
/// fallbacks). The pre-filled body carries a small, non-secret environment
/// summary; nothing that could contain a token ever leaves the device. Recent
/// activity from the `PlozzLog` ring buffer is shown read-only for transparency
/// and inherits its redaction (see `PlozzLog.LogEntry`).
struct HelpDiagnosticsDetailView: View {
    let appVersion: String
    let appBuild: String
    let repoURL: String
    let accounts: [Account]
    @Bindable var diagnostics: DiagnosticsSettingsModel
    @Bindable var crashReporting: CrashReportingSettingsModel
    /// Whether this build shipped with a crash-reporting endpoint. When `false`
    /// the opt-in is shown disabled with a note (there's nowhere to send reports).
    let crashReportingConfigured: Bool
    let searchIndexStatus: @Sendable () async -> SearchIndexDiagnosticsSnapshot
    let rebuildSearchIndex: @Sendable () async -> Void
    @State private var searchStatus = SearchIndexDiagnosticsSnapshot()
    @State private var confirmSearchRebuild = false

    /// Email surfaced as a no-GitHub-account fallback for reporting problems.
    private static let feedbackEmail = "feedback@plozz.app"

    private var report: DiagnosticsReport {
        DiagnosticsReport(
            appVersion: appVersion,
            appBuild: appBuild,
            providers: providerSummary,
            repoURL: repoURL,
            recentLogTail: PlozzLog.recentLogText(limit: 8)
        )
    }

    /// Distinct signed-in providers (Jellyfin/Plex), or "none" when signed out.
    private var providerSummary: String {
        let names = accounts.map { $0.server.provider.displayName }
        var seen = Set<String>()
        let distinct = names.filter { seen.insert($0).inserted }
        return distinct.isEmpty ? "none" : distinct.joined(separator: ", ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                reportPanel
                sendDiagnosticsPanel
                crashReportingPanel
                diagnosticsPanel
                searchIndexPanel
                recentActivityPanel
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .task {
            searchStatus = await searchIndexStatus()
        }
        .confirmationDialog(
            "Rebuild description search?",
            isPresented: $confirmSearchRebuild,
            titleVisibility: .visible
        ) {
            Button("Rebuild Search Index", role: .destructive) {
                Task {
                    await rebuildSearchIndex()
                    searchStatus = await searchIndexStatus()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Title search keeps working while Plozz rebuilds descriptions locally.")
        }
    }

    /// Whether the on-demand diagnostics upload can run right now: the build
    /// shipped with a crash-reporting endpoint AND the user has opted in.
    private var canSendDiagnostics: Bool {
        crashReportingConfigured && crashReporting.settings.isEnabled
    }

    // MARK: - Report a Problem

    private var reportPanel: some View {
        FocusableSettingsPanel(title: "Report a Problem") {
            VStack(alignment: .leading, spacing: 20) {
                Text("Scan the code or go to the link to submit a GitHub issue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .top, spacing: 36) {
                    VStack(alignment: .leading, spacing: 12) {
                        infoRow("GitHub", report.newIssueShortURL)
                        infoRow("Email", Self.feedbackEmail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 12) {
                        // "L" correction: the pre-filled issue URL now carries a
                        // short recent-activity tail as well, so we trade error
                        // correction for capacity to keep the QR scannable at 10
                        // feet. It's shown on a clean screen (no print damage to
                        // recover from), so low correction is fine here.
                        SettingsQRCode(string: report.newIssueURLString, correctionLevel: "L")
                            .frame(width: 200, height: 200)
                        Text("Scan to report\na bug")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Send to Developer (surfaced here so it's discoverable, not buried)

    /// The fastest bug-report path for anyone who's turned on crash reporting:
    /// one tap sends the redacted recent-activity log straight to the developer.
    /// Placed right under "Report a Problem" so people actually find it instead
    /// of only stumbling on it deep inside the Recent Activity page.
    private var sendDiagnosticsPanel: some View {
        SendDiagnosticsCard(
            canSend: canSendDiagnostics,
            idleDescription: "Something not working? Send your recent activity straight to the developer — the quickest way to help track down a bug. Sent anonymously: no logins, tokens, servers, or titles.",
            disabledDescription: "Turn on Share Crash Reports below to enable this. Your recent activity is then sent anonymously — no logins, tokens, servers, or titles."
        )
    }

    // MARK: - Crash reporting (opt-in, off by default)

    @ViewBuilder
    private var crashReportingPanel: some View {
        if crashReportingConfigured {
            SettingsPanel(
                title: "Crash Reports",
                footer: "When on, Plozz sends an anonymous report if it crashes or freezes, so bugs can be fixed faster. Reports include only the crash itself plus your app version, tvOS version and device model — never your servers, logins, tokens, or what you were watching. Off by default; applies to this Apple TV."
            ) {
                Toggle("Share Crash Reports", isOn: $crashReporting.settings.isEnabled)
                    .toggleStyle(SettingsSwitchToggleStyle())
            }
        } else {
            // No DSN baked in ⇒ the toggle can't do anything, so it's disabled
            // (and thus unfocusable). Make the whole panel focusable instead so
            // it stays reachable/readable and doesn't create a focus dead-zone.
            FocusableSettingsPanel(
                title: "Crash Reports",
                footer: "This build has no crash-reporting endpoint configured, so nothing can be sent. Crash reporting is available in TestFlight and release builds."
            ) {
                Toggle("Share Crash Reports", isOn: .constant(false))
                    .toggleStyle(SettingsSwitchToggleStyle())
                    .disabled(true)
                    .opacity(0.5)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Diagnostics controls

    private var diagnosticsPanel: some View {
        SettingsPanel(
            title: "Diagnostics",
            footer: "Playback Diagnostics overlays live playback stats (codec, bitrate, buffer, memory) on top of the video. Home Performance Overlay shows a live Home rendering HUD. Both are power-user aids — leave them off for normal watching. Saved on this profile."
        ) {
            Toggle("Playback Diagnostics Overlay", isOn: $diagnostics.settings.isEnabled)
                .toggleStyle(SettingsSwitchToggleStyle())

            Toggle("Home Performance Overlay", isOn: $diagnostics.settings.homePerformanceOverlayEnabled)
                .toggleStyle(SettingsSwitchToggleStyle())
        }
    }

    private var searchIndexPanel: some View {
        SettingsPanel(
            title: "Description Search",
            footer: "Built and stored only on this Apple TV. Queries, titles and descriptions are never sent to an AI service."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                infoRow("Titles", searchStatus.documentCount.formatted())
                infoRow(
                    "Storage",
                    ByteCountFormatter.string(
                        fromByteCount: Int64(searchStatus.databaseBytes),
                        countStyle: .file
                    )
                )
                infoRow(
                    "Status",
                    searchStatus.isBuilding
                        ? "Building (\(searchStatus.queuedScopes) remaining)"
                        : (searchStatus.pausedReason.map { "Paused: \($0)" } ?? "Ready")
                )
                Button("Rebuild Search Index") {
                    confirmSearchRebuild = true
                }
                .buttonStyle(SettingsFocusButtonStyle())
            }
        }
    }

    // MARK: - Recent activity (read-only, redacted) — opens its own page

    private var recentActivityPanel: some View {
        SettingsPanel(
            footer: "The most recent app log lines, kept only on this Apple TV and already stripped of tokens and secrets. Shown so a maintainer can ask what Plozz was doing when a bug happened."
        ) {
            NavigationLink(value: SettingsRoute.recentActivity) {
                SettingsRowLabel(icon: "list.bullet.rectangle", title: "Recent Activity") {
                    Text("The latest app log lines from this Apple TV")
                        .font(.subheadline)
                        .settingsRowSecondary()
                        .lineLimit(1)
                } trailing: {
                    HStack(spacing: 16) {
                        Text(recentActivityCountLabel)
                            .font(.subheadline)
                            .settingsRowSecondary()
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .settingsRowSecondary()
                    }
                }
            }
            .buttonStyle(SettingsFocusButtonStyle())
        }
    }

    private var recentActivityCountLabel: String {
        let count = PlozzLog.recentEntries(limit: 500).count
        guard count > 0 else { return "None yet" }
        return count == 1 ? "1 line" : "\(count) lines"
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 150, alignment: .leading)
            Text(value)
            Spacer(minLength: 0)
        }
        .font(.headline)
    }
}

#endif
