#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Shared brand mark for a media provider: the real bundled Jellyfin, Plex, and
/// Emby logo assets — the SAME logos Settings uses — instead
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
    private let mediaShareTransport: MediaShareTransportKind?
    @Environment(\.settingsRowIsFocused) private var rowFocused
    @Environment(\.colorScheme) private var colorScheme

    public init(
        provider: ProviderKind,
        size: CGFloat = 14,
        showsBackground: Bool = true,
        mediaShareTransport: MediaShareTransportKind? = nil
    ) {
        self.provider = provider
        self.size = size
        self.showsBackground = showsBackground
        self.mediaShareTransport = mediaShareTransport
    }

    private var tint: Color {
        guard rowFocused else { return Self.brandTint(provider) }
        return Self.focusedBrandTint(provider, colorScheme: colorScheme)
    }

    private var assetName: String {
        switch provider {
        case .jellyfin: "JellyfinLogo"
        case .plex: "PlexLogo"
        case .emby: "EmbyLogo"
        case .mediaShare: ""
        }
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
        switch provider {
        case .mediaShare: "externaldrive.connected.to.line.below.fill"
        case .jellyfin, .plex, .emby: nil
        }
    }

    /// The transport badge string (SMB / WebDAV / …), only for a media share that
    /// was given a transport. All file shares share ONE drive glyph and are told
    /// apart by this knockout label; dedicated media servers never show one.
    private var badgeLabel: String? {
        guard provider == .mediaShare else { return nil }
        return mediaShareTransport?.badgeLabel
    }

    public var body: some View {
        ZStack {
            if showsBackground {
                Circle().fill(tint.opacity(0.18))
            }
            if let systemSymbolName {
                glyph(systemSymbolName)
                    // The band chop pulls the drive's visual weight downward;
                    // lift the badged mark a touch so it sits optically centered
                    // in its container. Visual only — layout footprint unchanged.
                    .offset(y: badgeLabel != nil ? -size * 0.11 : 0)
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

    /// The drive glyph with the bottom band sliced off along a clean horizontal
    /// line, and the transport label drawn (in the glyph's own color) into the
    /// cleared band. The cut is a fixed fraction of the icon, so EVERY label gets
    /// the identical clean cutoff regardless of what it says. Falls back to the
    /// plain glyph when there's no badge.
    @ViewBuilder
    private func glyph(_ symbol: String) -> some View {
        let base = Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .padding(size * (showsBackground ? 0.33 : 0.23))
            .foregroundStyle(tint)

        if let badgeLabel {
            // Fraction of the icon height chopped off the bottom. Constant, so the
            // cutoff line sits in the same place for SMB, WebDAV, NFS, … — the
            // label never shifts it.
            let chop = size * 0.43
            ZStack(alignment: .bottom) {
                base
                    // Slice the lower band cleanly off the glyph (a straight
                    // horizontal cut) so the top of the drive stays intact and the
                    // bottom becomes a consistent, empty band for the label.
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .frame(height: chop)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                // The label sits in the cleared band, same color as the glyph,
                // nudged up so it reads more centered under the smaller drive.
                badgeText(badgeLabel)
                    .foregroundStyle(tint)
                    .frame(height: chop, alignment: .center)
                    .offset(y: -size * 0.05)
            }
        } else {
            base
        }
    }

    /// The transport label, width-constrained to the icon so any label length
    /// fits, and lifted slightly off the very bottom edge. Rendered into the
    /// cleared band by `glyph`.
    @ViewBuilder
    private func badgeText(_ label: String) -> some View {
        Text(label)
            .font(.system(size: size * 0.22, weight: .black, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.3)
            .multilineTextAlignment(.center)
            .frame(width: size * 0.82)
    }

    /// Brand accent color used to tint each provider's logo + chip.
    public static func brandTint(_ provider: ProviderKind) -> Color {
        switch provider {
        case .jellyfin:
            return Color(red: 0.53, green: 0.38, blue: 0.95)
        case .emby:
            return Color(red: 0x52 / 255, green: 0xB5 / 255, blue: 0x4B / 255)
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
            case .emby:
                return Color(red: 0x2D / 255, green: 0x7D / 255, blue: 0x32 / 255)
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
        case .emby:
            return Color(red: 0x64 / 255, green: 0xD2 / 255, blue: 0x5C / 255)
        case .plex:
            return Color(red: 0.96, green: 0.73, blue: 0.18)
        case .mediaShare:
            return Color(red: 0.36, green: 0.82, blue: 0.77)
        }
    }
}
#endif
