import Foundation

/// App metadata helpers.
public enum AppInfo {
    /// Marketing version from the app bundle, e.g. "1.0".
    public static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "1.0"
    }

    /// Build number from the app bundle (CFBundleVersion). Baked into the
    /// generated project at project-generation time (see tools/generate-project.sh)
    /// from the git commit count, so it auto-increments on every commit; the
    /// fastlane `build` lane overrides it with (latest TestFlight build + 1) for
    /// App Store / TestFlight uploads.
    public static var build: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build ?? "1"
    }

    /// Public source repository, encoded into the Settings "About" QR code so a
    /// phone can open it (tvOS has no browser).
    public static let repoURLString = "https://github.com/thatcube/Plozz"
}
