import Foundation

/// User preference controlling the on-screen playback diagnostics overlay.
///
/// A deliberately tiny value type (mirrors `SpoilerSettings`) so it persists and
/// binds through the same Store + Model pattern the rest of Settings uses.
public struct DiagnosticsSettings: Codable, Equatable, Sendable {
    /// Whether the playback diagnostics overlay is shown during playback.
    /// Off by default — it's a power-user/debug affordance.
    public var isEnabled: Bool

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    public static let `default` = DiagnosticsSettings()
}
