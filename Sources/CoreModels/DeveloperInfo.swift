import Foundation

/// One labelled fact shown on the Developer Mode "Device & Build" panel.
public struct DeveloperInfoItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let value: String

    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

/// Gathers the build/runtime facts most useful when triaging a device: which
/// build is actually installed (canonical vs a `--branded` side-by-side app),
/// the release channel, and whether the capabilities that **silently degrade in
/// branded builds** (the shared App Group that backs Top Shelf) are actually
/// available. Nothing here is secret — it's the same info you'd read off an
/// About screen plus a couple of capability probes — so it's safe to show behind
/// the hidden Developer Mode gate and to copy into a bug report.
public enum DeveloperInfo {
    /// The App Group the Top Shelf extension shares with the app. Absent in
    /// `--branded` builds (a fresh App ID can't auto-provision it), which is the
    /// single most common "why is this build behaving differently" cause.
    public static let appGroupID = "group.com.thatcube.Plozz"

    public static func snapshot(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        channel: AppReleaseChannel = .current
    ) -> [DeveloperInfoItem] {
        func string(_ key: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String) ?? "—"
        }

        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "—"
        let bundleID = bundle.bundleIdentifier ?? "—"

        // `--branded` side-by-side apps carry a suffixed bundle id; the canonical
        // app is exactly `com.plozz.app`. Surfacing this removes all doubt about
        // which of the two installed apps you're looking at.
        let isBranded = bundleID != "com.plozz.app"

        let dsn = (bundle.object(forInfoDictionaryKey: "PlozzSentryDSN") as? String) ?? ""
        let trimmedDSN = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        let crashConfigured = !trimmedDSN.isEmpty && !(trimmedDSN.hasPrefix("$(") && trimmedDSN.hasSuffix(")"))

        let appGroupAvailable =
            fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil

        let channelLabel: String
        switch channel {
        case .debug: channelLabel = "Debug"
        case .testflight: channelLabel = "TestFlight"
        case .production: channelLabel = "App Store"
        }

        return [
            DeveloperInfoItem(id: "app", label: "App", value: appName),
            DeveloperInfoItem(id: "build-kind", label: "Build", value: isBranded ? "Branded (side-by-side)" : "Canonical"),
            DeveloperInfoItem(id: "bundle-id", label: "Bundle ID", value: bundleID),
            DeveloperInfoItem(id: "version", label: "Version", value: string("CFBundleShortVersionString")),
            DeveloperInfoItem(id: "build-number", label: "Build #", value: string("CFBundleVersion")),
            DeveloperInfoItem(id: "channel", label: "Channel", value: channelLabel),
            DeveloperInfoItem(id: "app-group", label: "App Group", value: appGroupAvailable ? "Available" : "Unavailable (Top Shelf off)"),
            DeveloperInfoItem(id: "crash-endpoint", label: "Crash Endpoint", value: crashConfigured ? "Configured" : "Not configured"),
        ]
    }

    /// A plain-text rendering of the snapshot suitable for the iOS "Copy" action
    /// and pasting into a bug report.
    public static func copyText(
        _ items: [DeveloperInfoItem],
        extra: [DeveloperInfoItem] = []
    ) -> String {
        (items + extra)
            .map { "\($0.label): \($0.value)" }
            .joined(separator: "\n")
    }
}
