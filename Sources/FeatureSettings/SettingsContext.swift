#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureProfiles

/// Shared providers for Settings sub-views.
///
/// Bundled into a single value so each detail page can pull what it needs
/// without `SettingsView`'s init exploding to 30+ parameters.
struct SettingsContext {
    let captions: CaptionSettingsModel
    let spoilers: SpoilerSettingsModel
    let theme: ThemeSettingsModel
    let homeVisibility: HomeLibraryVisibilityModel
    let discoveredLibraries: LoadState<[AggregatedLibrary]>
    let reloadLibraries: () async -> Void
    let accounts: [Account]
    let activeAccountID: String?
    let profiles: [Profile]
    let activeProfile: Profile
    let askProfileOnStartup: Bool
    let profilesEnabled: Bool
    let isAccountIncludedInActiveProfile: (String) -> Bool
    let onSetAccountIncluded: (String, Bool) -> Void
    let onSetAskProfileOnStartup: (Bool) -> Void
    let onEnableProfiles: () -> Void
    let onDisableProfiles: () -> Void
    let onSwitchProfile: () -> Void
    let onSaveProfile: (ProfileDraft) -> Void
    let onDeleteProfile: (String) -> Void
    let onAddAccount: () -> Void
    let onRemoveAccount: (Account) -> Void
    let onSignOutAll: () -> Void
    let plexHomeUsersFetcher: (String) async -> [PlexHomeUser]
    let onSelectPlexHomeUser: (String, PlexHomeUser?) -> Void
}

/// Typed routes for the Settings drill-down NavigationStack. Defined at file
/// scope (not nested in `SettingsView`) so detail pages can push their own
/// destinations onto the same stack — `ServersAndLibrariesDetailView` uses
/// this to drill from a server summary row into `ServerDetailView`, and a
/// future per-account flow can do the same without re-plumbing closures.
enum SettingsRoute: Hashable {
    case profile
    case servers
    case appearance
    case captions
    case spoilers
    case integrations
    case about
    case plexUser(accountID: String)
    case server(key: String)
}

/// A titled section rendered as a translucent panel. Reused by every Settings
/// detail page so the visual treatment is consistent.
struct SettingsPanel<Content: View>: View {
    let title: String?
    var footer: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                Text(title)
                    .font(.headline.weight(.semibold))
            }
            content
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// Shared provider chip + icon used across Settings detail pages.
struct ProviderBadge: View {
    let provider: ProviderKind
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: 4) {
            ProviderIcon(provider: provider, size: size)
            Text(provider.displayName)
        }
        .fixedSize()
    }
}

struct ProviderIcon: View {
    let provider: ProviderKind
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            Circle().fill(Self.tint(provider).opacity(0.18))
            Image(systemName: provider == .jellyfin ? "drop.fill" : "chevron.forward")
                .font(.system(size: provider == .jellyfin ? size * 0.58 : size * 0.52, weight: .bold))
                .foregroundStyle(Self.tint(provider))
        }
        .frame(width: size, height: size)
    }

    static func tint(_ provider: ProviderKind) -> Color {
        switch provider {
        case .jellyfin:
            return Color(red: 0.53, green: 0.38, blue: 0.95)
        case .plex:
            return Color(red: 0xE5 / 255, green: 0xA0 / 255, blue: 0x0D / 255)
        }
    }
}

/// Small avatar circle for an account — image-first, falls back to an
/// initial-letter placeholder. Used by Profile and Servers detail pages.
struct AccountAvatar: View {
    let name: String
    let imageURL: URL?
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty, .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.10))
            Text(String(name.prefix(1)).uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// Builds the Jellyfin avatar URL fallback when the account's `avatarURL` is
/// nil. Plex always supplies one; Jellyfin needs the `/Users/<id>/Images/Primary`
/// path on the server's base URL.
func resolvedAvatarURL(for account: Account) -> URL? {
    if let avatarURL = account.avatarURL { return avatarURL }
    guard account.server.provider == .jellyfin,
          var components = URLComponents(url: account.server.baseURL, resolvingAgainstBaseURL: false) else {
        return nil
    }
    let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
    components.path = basePath + "/Users/\(account.userID)/Images/Primary"
    return components.url
}
#endif
