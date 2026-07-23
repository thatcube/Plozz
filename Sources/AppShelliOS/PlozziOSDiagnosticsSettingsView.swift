#if os(iOS)
import CoreModels
import CoreNetworking
import CoreUI
import CrashReporting
import Foundation
import SwiftUI
import UIKit

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
        List {
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
                        "On by default during the beta; you can turn it off any time. When enabled, anonymous crash details help improve Plozz. Server addresses, media titles, profile names, and credentials are never included."
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
        .settingsPageSurface()
        .navigationTitle("Help & Diagnostics")
        .onChange(of: crashReporting.settings.isEnabled) {
            appModel.applyCrashReportingPreference()
            sendStatus = nil
        }
    }
}

private struct PlozziOSRecentActivityView: View {
    @State private var entries = PlozzLog.recentEntries(limit: 500)
    @State private var selectedCategory: String? = nil
    @State private var searchText = ""
    @State private var justCopied = false

    /// Distinct categories present, for the filter menu.
    private var categories: [String] {
        Array(Set(entries.map(\.category))).sorted()
    }

    /// Newest-first entries after applying the category + text filters.
    private var filtered: [PlozzLog.LogEntry] {
        entries.reversed().filter { entry in
            if let selectedCategory, entry.category != selectedCategory { return false }
            if !searchText.isEmpty,
               !entry.message.localizedCaseInsensitiveContains(searchText),
               !entry.category.localizedCaseInsensitiveContains(searchText) { return false }
            return true
        }
    }

    private var shareText: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return filtered.reversed()
            .map { "\(formatter.string(from: $0.date)) [\($0.level.rawValue)] \($0.category): \($0.message)" }
            .joined(separator: "\n")
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView(
                    entries.isEmpty ? "No Recent Activity" : "No Matches",
                    systemImage: entries.isEmpty ? "waveform.slash" : "line.3.horizontal.decrease.circle",
                    description: Text(entries.isEmpty
                        ? "Activity recorded during this app session will appear here."
                        : "No log entries match the current filter.")
                )
            } else {
                ForEach(filtered) { entry in
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
        .settingsPageSurface()
        .navigationTitle("Recent Activity")
        .searchable(text: $searchText, prompt: "Search messages")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Category", selection: $selectedCategory) {
                        Text("All Categories").tag(String?.none)
                        ForEach(categories, id: \.self) { cat in
                            Text(cat.capitalized).tag(String?.some(cat))
                        }
                    }
                } label: {
                    Label(selectedCategory?.capitalized ?? "Filter",
                          systemImage: selectedCategory == nil
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill")
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    entries = PlozzLog.recentEntries(limit: 500)
                }
                // Copy is the reliable path: a toolbar ShareLink's sheet can present
                // with unresponsive buttons on iPad, so copying to the clipboard is
                // the dependable way to get the (filtered) log out for a bug report.
                Button {
                    UIPasteboard.general.string = shareText
                    justCopied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); justCopied = false }
                } label: {
                    Label(justCopied ? "Copied" : "Copy",
                          systemImage: justCopied ? "checkmark" : "doc.on.doc")
                }
                .disabled(filtered.isEmpty)
                ShareLink(item: shareText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(filtered.isEmpty)
            }
        }
    }
}
#endif
