#if os(iOS)
import CoreModels
import CoreNetworking
import CoreUI
import CrashReporting
import Foundation
import SwiftUI

struct PlozziOSDiagnosticsSettingsView: View {
    let appModel: PlozziOSAppModel
    @Bindable var model: DiagnosticsSettingsModel
    @Bindable var crashReporting: CrashReportingSettingsModel
    @State private var diagnosticNote = ""
    @State private var sendStatus: String?

    private var report: DiagnosticsReport {
        let info = Bundle.main.infoDictionary
        let providers = Set(appModel.accounts.map(\.server.provider.displayName))
            .sorted()
            .joined(separator: ", ")
        return DiagnosticsReport(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "Unknown",
            appBuild: info?["CFBundleVersion"] as? String ?? "Unknown",
            providers: providers.isEmpty ? "None" : providers,
            repoURL: "https://github.com/thatcube/Plozz",
            recentLogTail: PlozzLog.recentLogText(limit: 8)
        )
    }

    var body: some View {
        Form {
            SettingsSectionGroup("Get Help") {
                if let issueURL = report.newIssueURL {
                    Link(destination: issueURL) {
                        Label("Report a Problem", systemImage: "ladybug")
                    }
                }
                if let feedbackURL = URL(
                    string: "mailto:hello@plozz.app?subject=Plozz%20Feedback"
                ) {
                    Link(destination: feedbackURL) {
                        Label("Send Feedback", systemImage: "envelope")
                    }
                }
                NavigationLink {
                    PlozziOSRecentActivityView()
                } label: {
                    Label("Recent Activity", systemImage: "clock.arrow.circlepath")
                }
            }

            SettingsSectionGroup {
                Toggle(
                    "Share Crash Reports",
                    isOn: $crashReporting.settings.isEnabled
                )
                .disabled(!appModel.crashReportingController.isConfigured)
            } footer: {
                if appModel.crashReportingController.isConfigured {
                    Text(
                        "Off by default. When enabled, anonymous crash details help improve Plozz. Server addresses, media titles, profile names, and credentials are never included."
                    )
                } else {
                    Text("Crash reporting is unavailable in this build.")
                }
            }

            SettingsSectionGroup("Send Diagnostics") {
                TextField("Optional note", text: $diagnosticNote, axis: .vertical)
                    .lineLimit(2...4)
                Button {
                    appModel.applyCrashReportingPreference()
                    let sent = CrashDiagnostics.send(
                        logText: PlozzLog.recentLogText(limit: 200),
                        note: diagnosticNote.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    sendStatus = sent
                        ? "Diagnostics sent. Thank you."
                        : "Diagnostics could not be sent. Enable crash reports and try again."
                } label: {
                    Label("Send to Developer", systemImage: "paperplane")
                }
                .disabled(
                    !appModel.crashReportingController.isConfigured
                        || !crashReporting.settings.isEnabled
                )

                if let sendStatus {
                    Text(sendStatus)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSectionGroup {
                Toggle("Playback diagnostics", isOn: $model.settings.isEnabled)
                Toggle(
                    "Home performance overlay",
                    isOn: $model.settings.homePerformanceOverlayEnabled
                )
            } footer: {
                Text("Troubleshooting overlays stay on this device and are off by default.")
            }
        }
        .navigationTitle("Help & Diagnostics")
        .onChange(of: crashReporting.settings.isEnabled) {
            appModel.applyCrashReportingPreference()
            sendStatus = nil
        }
    }
}

private struct PlozziOSRecentActivityView: View {
    @State private var entries = PlozzLog.recentEntries(limit: 200)

    private var shareText: String {
        PlozzLog.recentLogText(limit: 200)
    }

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Recent Activity",
                    systemImage: "waveform.slash",
                    description: Text("Activity recorded during this app session will appear here.")
                )
            } else {
                ForEach(entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(entry.category.capitalized)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.message)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("Recent Activity")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    entries = PlozzLog.recentEntries(limit: 200)
                }
                ShareLink(item: shareText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(entries.isEmpty)
            }
        }
    }
}
#endif
