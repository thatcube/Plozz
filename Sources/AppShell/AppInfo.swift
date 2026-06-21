import Foundation

/// App metadata helpers.
public enum AppInfo {
    /// Marketing version from the app bundle, e.g. "1.0".
    public static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "1.0"
    }

    /// Build number from the app bundle (CFBundleVersion). Stamped from the git
    /// commit count at build time, so it auto-increments on every commit.
    public static var build: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build ?? "1"
    }

    /// Public source repository, encoded into the Settings "About" QR code so a
    /// phone can open it (tvOS has no browser).
    public static let repoURLString = "https://github.com/thatcube/Plozz"
}
