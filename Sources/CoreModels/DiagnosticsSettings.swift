import Foundation

/// User preference controlling the on-screen diagnostics overlays.
///
/// A deliberately tiny value type (mirrors `SpoilerSettings`) so it persists and
/// binds through the same Store + Model pattern the rest of Settings uses.
public struct DiagnosticsSettings: Codable, Equatable, Sendable {
    /// Whether the playback diagnostics overlay is shown during playback.
    /// Off by default — it's a power-user/debug affordance.
    public var isEnabled: Bool

    /// Whether the Home performance overlay (live FPS / hitches / thermal) is shown
    /// while browsing Home. Off by default — a power-user/debug affordance for
    /// validating smoothness on older hardware.
    public var homePerformanceOverlayEnabled: Bool

    public init(
        isEnabled: Bool = false,
        homePerformanceOverlayEnabled: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.homePerformanceOverlayEnabled = homePerformanceOverlayEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, homePerformanceOverlayEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // decodeIfPresent so a blob written before a field existed decodes to its
        // default instead of failing the whole decode.
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        homePerformanceOverlayEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .homePerformanceOverlayEnabled
        ) ?? false
    }

    public static let `default` = DiagnosticsSettings()
}
