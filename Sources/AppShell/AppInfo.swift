import Foundation

/// App metadata helpers.
public enum AppInfo {
    /// Marketing version from the app bundle, e.g. "1.0".
    public static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "1.0"
    }
}
