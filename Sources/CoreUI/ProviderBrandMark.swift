#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Shared brand mark for a media provider (Jellyfin / Plex): the real bundled
/// `JellyfinLogo` / `PlexLogo` assets — the SAME logos Settings uses — instead
/// of an SF Symbol stand-in. Template-rendered with a focus-aware provider color:
/// darker on a white focus card and lighter on a black one, preserving brand
/// identity while maintaining contrast.
///
/// Lives in CoreUI so every surface (Settings, onboarding chooser, the server
/// picker) draws provider logos one identical way instead of each re-deriving
/// the asset name, brand tint, and focus behavior.
public struct ProviderBrandMark: View {
    private let provider: ProviderKind
    private let size: CGFloat
    private let showsBackground: Bool
    @Environment(\.settingsRowIsFocused) private var rowFocused
    @Environment(\.colorScheme) private var colorScheme

    public init(provider: ProviderKind, size: CGFloat = 14, showsBackground: Bool = true) {
        self.provider = provider
        self.size = size
        self.showsBackground = showsBackground
    }

    private var tint: Color {
        guard rowFocused else { return Self.brandTint(provider) }
        return Self.focusedBrandTint(provider, colorScheme: colorScheme)
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
                Circle().fill(tint.opacity(0.18))
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

    private static func focusedBrandTint(_ provider: ProviderKind, colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            // Dark appearance uses a white focus card, so each brand needs a
            // deeper shade rather than collapsing to generic black.
            switch provider {
            case .jellyfin:
                return Color(red: 0.38, green: 0.25, blue: 0.78)
            case .plex:
                return Color(red: 0.60, green: 0.39, blue: 0.00)
            case .mediaShare:
                return Color(red: 0.08, green: 0.46, blue: 0.43)
            }
        }

        // Light appearance uses a black focus card; brighter variants preserve
        // the same identities against the darker surface.
        switch provider {
        case .jellyfin:
            return Color(red: 0.65, green: 0.52, blue: 0.98)
        case .plex:
            return Color(red: 0.96, green: 0.73, blue: 0.18)
        case .mediaShare:
            return Color(red: 0.36, green: 0.82, blue: 0.77)
        }
    }
}
#endif
