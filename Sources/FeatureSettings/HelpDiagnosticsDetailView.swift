#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreNetworking
import CoreUI

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

    /// Email surfaced as a no-GitHub-account fallback for reporting problems.
    private static let feedbackEmail = "feedback@plozz.app"

    private var report: DiagnosticsReport {
        DiagnosticsReport(
            appVersion: appVersion,
            appBuild: appBuild,
            providers: providerSummary,
            repoURL: repoURL
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
                crashReportingPanel
                diagnosticsPanel
                recentActivityPanel
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
    }

    // MARK: - Report a Problem

    private var reportPanel: some View {
        FocusableSettingsPanel(
            title: "Report a Problem",
            footer: "Scan the code, or go to the link on any device, to open a pre-filled bug report on GitHub. Your servers, logins and tokens are never included."
        ) {
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 12) {
                    infoRow("GitHub", report.newIssueShortURL)
                    infoRow("Email", Self.feedbackEmail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 12) {
                    // "M" correction keeps the longer pre-filled issue URL
                    // scannable at 10 feet (About's short repo link uses "H").
                    SettingsQRCode(string: report.newIssueURLString, correctionLevel: "M")
                        .frame(width: 200, height: 200)
                    Text("Scan to report\na bug")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
        }
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
            footer: "Overlays live playback stats (codec, bitrate, buffer, memory) on top of the video. A power-user aid for diagnosing playback issues — leave it off for normal watching. Saved on this profile."
        ) {
            Toggle("Playback Diagnostics Overlay", isOn: $diagnostics.settings.isEnabled)
                .toggleStyle(SettingsSwitchToggleStyle())
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

/// Builds the pre-filled GitHub "new issue" link (and its human-readable short
/// form) plus the small, non-secret environment block embedded in the issue
/// body. Kept as a value type — no view state — so the URL construction is easy
/// to reason about and safe to unit test.
struct DiagnosticsReport {
    let appVersion: String
    let appBuild: String
    let providers: String
    let repoURL: String

    /// tvOS version as `major.minor(.patch)`.
    var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0
            ? "\(v.majorVersion).\(v.minorVersion)"
            : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Hardware identifier, e.g. `AppleTV14,1`.
    var deviceModel: String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        let bytes = mirror.children.compactMap { $0.value as? Int8 }.filter { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let model = String(decoding: bytes, as: UTF8.self)
        return model.isEmpty ? "Apple TV" : model
    }

    /// The environment block appended to every report (non-secret only).
    var environmentBlock: String {
        """
        - Plozz: \(appVersion) (build \(appBuild))
        - tvOS: \(systemVersion)
        - Device: \(deviceModel)
        - Provider(s): \(providers)
        """
    }

    private var issueTitle: String { "[Bug] " }

    private var issueBody: String {
        """
        **What happened?**


        **Steps to reproduce**
        1.\u{0020}

        **What did you expect?**


        ---
        _Environment (auto-filled by Plozz — please keep):_
        \(environmentBlock)
        """
    }

    /// Pre-filled `issues/new` URL. Uses `URLComponents`/`queryItems` so the
    /// title and body are percent-encoded correctly.
    var newIssueURLString: String {
        let base = repoURL.hasSuffix("/") ? String(repoURL.dropLast()) : repoURL
        guard var comps = URLComponents(string: base + "/issues/new") else {
            return base + "/issues/new"
        }
        comps.queryItems = [
            URLQueryItem(name: "labels", value: "bug"),
            URLQueryItem(name: "title", value: issueTitle),
            URLQueryItem(name: "body", value: issueBody)
        ]
        return comps.url?.absoluteString ?? (base + "/issues/new")
    }

    /// Human-readable short form to type manually (no query string).
    var newIssueShortURL: String {
        let base = repoURL.hasSuffix("/") ? String(repoURL.dropLast()) : repoURL
        let host = base.replacingOccurrences(of: "https://", with: "")
        return host + "/issues/new"
    }
}
#endif
