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
                diagnosticsPanel
                recentActivityPanel
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .navigationTitle("Help & Diagnostics")
    }

    // MARK: - Report a Problem

    private var reportPanel: some View {
        SettingsPanel(
            title: "Report a Problem",
            footer: "Scan the code with your phone to open a pre-filled bug report on GitHub — Apple TV has no keyboard, so you finish typing on your phone. No account? Email \(Self.feedbackEmail). For crashes or screenshots, use TestFlight’s built-in feedback. Your servers, logins and tokens are never included."
        ) {
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Found a bug?")
                        .font(.title3.weight(.semibold))
                    Text("The report is pre-filled with your Plozz version and device so you don’t have to type it. Just describe what happened.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    infoRow("Open on your phone", report.newIssueShortURL)
                    infoRow("Or email", Self.feedbackEmail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 12) {
                    // "M" correction keeps the longer pre-filled issue URL
                    // scannable at 10 feet (About's short repo link uses "H").
                    SettingsQRCode(string: report.newIssueURLString, correctionLevel: "M")
                        .frame(width: 200, height: 200)
                    Text("Scan to file a\nGitHub issue")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Diagnostics controls

    private var diagnosticsPanel: some View {
        SettingsPanel(
            title: "Diagnostics",
            footer: "Overlays live playback stats (codec, bitrate, buffer, memory) on top of the video. A power-user aid for diagnosing playback issues — leave it off for normal watching. Saved on this profile."
        ) {
            Toggle(isOn: $diagnostics.settings.isEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Playback Diagnostics Overlay")
                        .font(.headline)
                    Text(diagnostics.settings.isEnabled ? "On" : "Off")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Recent activity (read-only, redacted)

    private var recentActivityPanel: some View {
        SettingsPanel(
            title: "Recent Activity",
            footer: "The most recent app log lines, kept only on this Apple TV and already stripped of tokens and secrets. Shown so a maintainer can ask what Plozz was doing when a bug happened."
        ) {
            let entries = PlozzLog.recentEntries(limit: 40)
            if entries.isEmpty {
                Text("No activity recorded yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries.reversed()) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.category)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 120, alignment: .leading)
                            Text(entry.message)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 220, alignment: .leading)
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
