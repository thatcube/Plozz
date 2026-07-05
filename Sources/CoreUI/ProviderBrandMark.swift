#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Shared brand mark for a media provider (Jellyfin / Plex): the real bundled
/// `JellyfinLogo` / `PlexLogo` assets — the SAME logos Settings uses — instead
/// of an SF Symbol stand-in. Template-rendered and tinted with the provider's
/// brand color so it reads on any background, and it flips to the focus
/// foreground when it sits on a focused Settings-style row.
///
/// Lives in CoreUI so every surface (Settings, onboarding chooser, the server
/// picker) draws provider logos one identical way instead of each re-deriving
/// the asset name, brand tint, and focus behavior.
public struct ProviderBrandMark: View {
    private let provider: ProviderKind
    private let size: CGFloat
    private let showsBackground: Bool

    // Reads the unified Settings-row focus state so the mark flips to the focus
    // foreground on the inverted card (avoids a tinted glyph on a same-color
    // background). No-ops outside a Settings-style focus row (defaults unfocused).
    @Environment(\.settingsRowIsFocused) private var rowFocused
    @Environment(\.settingsRowFocusForeground) private var rowFocusForeground

    public init(provider: ProviderKind, size: CGFloat = 14, showsBackground: Bool = true) {
        self.provider = provider
        self.size = size
        self.showsBackground = showsBackground
    }

    private var tint: Color {
        rowFocused ? rowFocusForeground : Self.brandTint(provider)
    }

    private var assetName: String {
        provider == .plex ? "PlexLogo" : "JellyfinLogo"
    }

    /// Interior padding for the bundled logo asset. The Plex mark reads visibly
    /// smaller than the Jellyfin mark at the same frame, so Plex gets less padding
    /// — rendering ~8pt larger at the settings icon sizes — while the `size` frame
    /// is unchanged, so surrounding layout never shifts. Proportional, so small
    /// marks stay comfortably in-bounds.
    private var assetPadding: CGFloat {
        let base = size * (showsBackground ? 0.24 : 0.12)
        let plexBoost: CGFloat = provider == .plex ? size * 0.07 : 0
        return max(0, base - plexBoost)
    }

    /// A media share has no bundled brand logo (it isn't a product), so it draws
    /// an SF Symbol instead of a `*Logo` asset. `nil` for the real providers.
    private var systemSymbolName: String? {
        provider == .mediaShare ? "externaldrive.connected.to.line.below.fill" : nil
    }

    public var body: some View {
        ZStack {
            if showsBackground {
                Circle().fill(Self.brandTint(provider).opacity(rowFocused ? 0 : 0.18))
            }
            if let systemSymbolName {
                Image(systemName: systemSymbolName)
                    .resizable()
                    .scaledToFit()
                    .padding(size * (showsBackground ? 0.28 : 0.18))
                    .foregroundStyle(tint)
            } else {
                Image(assetName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .padding(assetPadding)
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
    }

    /// Brand accent color used to tint each provider's logo + chip.
    public static func brandTint(_ provider: ProviderKind) -> Color {
        switch provider {
        case .jellyfin:
            return Color(red: 0.53, green: 0.38, blue: 0.95)
        case .plex:
            return Color(red: 0xE5 / 255, green: 0xA0 / 255, blue: 0x0D / 255)
        case .mediaShare:
            // Neutral teal — reads as "storage/network", clearly not a Plex/
            // Jellyfin brand color, matching its second-class standing.
            return Color(red: 0x2A / 255, green: 0xA8 / 255, blue: 0x9E / 255)
        }
    }
}
#endif
