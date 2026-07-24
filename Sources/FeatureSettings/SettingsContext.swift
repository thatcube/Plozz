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
    let spoilers: SpoilerSettingsModel
    let playback: PlaybackSettingsModel
    let theme: ThemeSettingsModel
    let homeVisibility: HomeLibraryVisibilityModel
    let discoveredLibraries: LoadState<[AggregatedLibrary]>
    let refreshingLibraryAccountIDs: Set<String>
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
    /// Live cosmetics-only persistence for editing an existing profile.
    let onUpdateProfileCosmetics: (ProfileDraft) -> Void
    let onDeleteProfile: (String) -> Void
    let onAddAccount: () -> Void
    let onRemoveAccount: (Account) -> Void
    /// Remove a server from EVERY device on this iCloud account (household tombstone).
    let onRemoveAccountEverywhere: (Account) -> Void
    /// Whether a "Remove Everywhere" choice is meaningful here: cross-device sync is on
    /// AND the account has at least one other device to remove it from. When false the
    /// remove UI shows a single plain "Remove".
    let offersRemoveEverywhere: Bool
    /// Force a fresh scan + enrichment of a media share now (its account id).
    let onRescanShare: (String) -> Void
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
    case myLibraries
    case appearance
    case customizeHome
    case detailPage
    case nightShift
    case playback
    case spoilers
    case integrations
    case metadata
    case metadataDiagnostics
    case seerr
    case syncSetup
    case seerUserPicker(profileID: String)
    case attributions
    case help
    case recentActivity
    case plexUser(accountID: String)
    case server(key: String)
}

extension EdgeInsets {
    /// The default uniform `SettingsPanel` inset — fine for text / non-row content.
    static var settingsPanelDefault: EdgeInsets { EdgeInsets(top: 28, leading: 28, bottom: 28, trailing: 28) }

    /// `SettingsPanel` inset tuned so list-row controls inside focus
    /// **concentrically** with the panel: 28pt horizontal / 16pt vertical, i.e.
    /// the focus card's outward bleed (16pt H / 4pt V in `SettingsFocusButtonStyle`)
    /// plus a uniform 12pt gap on every side. Use for a panel whose content is a
    /// stack of toggle / checkable / selector rows (which also pass
    /// `flushLeading: false`).
    static var settingsPanelRowContent: EdgeInsets { EdgeInsets(top: 16, leading: 28, bottom: 16, trailing: 28) }
}

/// A titled section rendered as a translucent panel. Reused by every Settings
/// detail page so the visual treatment is consistent.
struct SettingsPanel<Content: View>: View {
    let title: String?
    var subtitle: String?
    var footer: String?
    var contentPadding: EdgeInsets
    var showsSurface: Bool
    @ViewBuilder let content: Content

    init(
        title: String? = nil,
        subtitle: String? = nil,
        footer: String? = nil,
        contentPadding: EdgeInsets = .settingsPanelDefault,
        showsSurface: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.contentPadding = contentPadding
        self.showsSurface = showsSurface
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let title {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(1.0)
                            .foregroundStyle(.secondary)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
        .padding(contentPadding)
        .background {
            if showsSurface {
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay {
            if showsSurface {
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }
}

/// The consistent page-level heading for the top-level "This Apple TV" detail
/// pages (Servers, Profiles, Seerr). It's a single large title — the heading
/// for the whole page — with an optional one-line subtitle used ONLY where it
/// conveys something the title alone doesn't (e.g. that a page's data is shared
/// device-wide). The small UPPERCASE `SettingsPanel` titles are reserved for
/// the sub-sections *within* a page; this is the page heading that sits above
/// them.
struct SettingsPageHeader: View {
    let title: String
    var subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.bold())
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A `SettingsPanel` that can itself take focus, for panels whose content is
/// **read-only** (or whose only control is disabled) and would otherwise be
/// unreachable on tvOS — a non-focusable view never receives focus, so the
/// parent `ScrollView` can't scroll it into view and the user gets stuck.
///
/// Rather than the About panel's stark inverted-card contrast flip, focus here
/// is shown the way round artwork (avatars, cast portraits, profile tiles) shows
/// it: a soft, **theme-tinted outline** blooming around the whole element (plus a
/// gentle lift), so contrast never inverts and the panel's resting look is
/// identical to every other `SettingsPanel`.
struct FocusableSettingsPanel<Content: View>: View {
    let title: String?
    var footer: String?
    /// Optional remote-select handler. When set, clicking the focused panel with
    /// the Siri remote invokes it — used only by the About panel to drive the
    /// hidden Developer Mode unlock gesture (seven selects on the Version row).
    var onActivate: (() -> Void)?
    @ViewBuilder let content: Content

    init(
        title: String? = nil,
        footer: String? = nil,
        onActivate: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.onActivate = onActivate
        self.content = content()
    }

    var body: some View {
        SettingsPanel(title: title, footer: footer, showsSurface: false) { content }
            .plozzFocusableCard(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius)
            .accessibilityElement(children: .combine)
            .onTapGesture { onActivate?() }
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
    var mediaShareTransport: MediaShareTransportKind? = nil

    var body: some View {
        // Delegates to the shared CoreUI mark so provider logos, brand tints,
        // the media-share drive glyph, and its transport badge have one
        // implementation across the app.
        ProviderBrandMark(provider: provider, size: size, mediaShareTransport: mediaShareTransport)
    }

    static func tint(_ provider: ProviderKind) -> Color {
        ProviderBrandMark.brandTint(provider)
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

/// Builds the Jellyfin/Emby avatar URL fallback when `avatarURL` is nil.
func resolvedAvatarURL(for account: Account) -> URL? {
    if let avatarURL = account.avatarURL { return avatarURL }
    guard account.server.provider.usesMediaBrowserAPI,
          var components = URLComponents(url: account.server.baseURL, resolvingAgainstBaseURL: false) else {
        return nil
    }
    let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
    components.path = basePath + "/Users/\(account.userID)/Images/Primary"
    return components.url
}
#endif
