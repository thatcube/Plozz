#if os(tvOS)
import SwiftUI
import CoreModels
import CoreUI
import FeatureProfiles

/// Fixed geometry for the custom navigation rail. Collected here so the shell's
/// content inset and the rail's own layout can never drift apart.
enum NavigationRailMetrics {
    /// Width of the collapsed rail — the inset the shell reserves for it, and the
    /// width the icons are centred in. Sized so a 40 pt glyph plus its focus card
    /// sits comfortably without crowding the screen edge.
    static let collapsedWidth: CGFloat = 124
    /// Width the rail grows to once focus enters it. It **overlays** the content
    /// rather than pushing it, so expanding never relayouts a poster grid.
    static let expandedWidth: CGFloat = 460
    static let itemSpacing: CGFloat = 6
    static let iconColumnWidth: CGFloat = 52
    static let avatarSize: CGFloat = 62
    static let verticalPadding: CGFloat = 36
    static let expandAnimation = Animation.easeOut(duration: 0.22)
}

/// Plozz's own top-level navigation: a slim rail down the leading edge that shows
/// **icons only** until focus enters it, then expands over the content to reveal
/// every label.
///
/// Layout, top to bottom:
/// 1. the active profile's avatar — opens the existing profile switcher;
/// 2. Search, then Home;
/// 3. the viewer's libraries, in their own arrangement, each with a glyph for what
///    it holds (film / TV / anime / photos / mixed), scrolling if there are many;
/// 4. Settings, **pinned to the bottom** so it is reachable at a glance no matter
///    how many libraries sit above it.
///
/// Everything about the list is data: which libraries appear and in what order
/// comes from the profile's ``NavigationLibraryLayout``, so re-arranging is a value
/// change rather than a code change.
struct NavigationRailView: View {
    let profile: Profile
    let entries: [NavigationRailLibraryEntry]
    let showsMusic: Bool
    @Binding var selection: NavigationRailDestination
    let onOpenProfileSwitcher: () -> Void

    @Environment(\.themePalette) private var palette
    @FocusState private var focusedTarget: RailFocusTarget?

    /// The rail is expanded exactly while it holds focus — "move focus into it to
    /// open it", with no timers and no separate toggle to get out of sync.
    private var isExpanded: Bool { focusedTarget != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            profileButton
                .padding(.bottom, PlozzTheme.Spacing.large)

            item(.search, symbol: "magnifyingglass", label: Text(Self.searchTitle))
            item(.home, symbol: "house.fill", label: Text(Self.homeTitle))
            if showsMusic {
                item(.music, symbol: "music.note", label: Text(Self.musicTitle))
            }

            if !entries.isEmpty {
                sectionLabel(Self.librariesTitle)
                libraryList
            } else {
                Spacer(minLength: 0)
            }

            item(.settings, symbol: "gearshape.fill", label: Text(Self.settingsTitle))
                .padding(.top, PlozzTheme.Spacing.large)
        }
        .padding(.vertical, NavigationRailMetrics.verticalPadding)
        .frame(
            width: isExpanded ? NavigationRailMetrics.expandedWidth : NavigationRailMetrics.collapsedWidth,
            alignment: .leading
        )
        .frame(maxHeight: .infinity, alignment: .top)
        .background(alignment: .leading) { backdrop }
        .animation(NavigationRailMetrics.expandAnimation, value: isExpanded)
        // One focus section, so a Left press from the content lands in the rail as
        // a unit instead of picking whichever row happens to be geometrically
        // nearest, and a Right press returns to the content rather than walking
        // through every remaining rail row.
        .focusSection()
        .accessibilityLabel(Text(Self.accessibilityTitle))
    }

    // MARK: - Pieces

    /// The libraries block. Scrollable so a household with forty libraries can
    /// still reach them all, while Settings below stays pinned and visible.
    private var libraryList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: NavigationRailMetrics.itemSpacing) {
                ForEach(entries) { entry in
                    libraryItem(entry)
                }
            }
        }
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        // Takes whatever height is left between Home and the pinned Settings row.
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func libraryItem(_ entry: NavigationRailLibraryEntry) -> some View {
        let symbol = entry.library?.library.navigationSymbolName ?? "square.stack.3d.up.fill"
        let label = entry.library?.library.displayName ?? Text(Self.allLibrariesTitle)
        return item(entry.destination, symbol: symbol, label: label)
    }

    private var profileButton: some View {
        Button(action: onOpenProfileSwitcher) {
            HStack(spacing: PlozzTheme.Spacing.medium) {
                ProfileAvatarView(profile: profile, size: NavigationRailMetrics.avatarSize)
                    .frame(width: NavigationRailMetrics.iconColumnWidth)
                if isExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: profile.name)
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                        Text(Self.switchProfileSubtitle)
                            .font(.caption)
                            .opacity(0.65)
                            .lineLimit(1)
                    }
                    .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NavigationRailItemStyle(isSelected: false, accent: palette.accent))
        .focused($focusedTarget, equals: .profile)
        .accessibilityLabel(Text(Self.switchProfileSubtitle))
        .accessibilityValue(Text(verbatim: profile.name))
    }

    private func item(
        _ destination: NavigationRailDestination,
        symbol: String,
        label: Text
    ) -> some View {
        Button {
            selection = destination
        } label: {
            HStack(spacing: PlozzTheme.Spacing.medium) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: NavigationRailMetrics.iconColumnWidth)
                    .accessibilityHidden(true)
                if isExpanded {
                    label
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            NavigationRailItemStyle(
                isSelected: selection == destination,
                accent: palette.accent
            )
        )
        .focused($focusedTarget, equals: .destination(destination))
        .accessibilityLabel(label)
        .accessibilityAddTraits(selection == destination ? [.isSelected] : [])
    }

    private func sectionLabel(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .plozzForeground(.secondary)
            .lineLimit(1)
            .padding(.horizontal, PlozzTheme.Spacing.medium)
            .padding(.top, PlozzTheme.Spacing.large)
            .padding(.bottom, PlozzTheme.Spacing.xSmall)
            // Collapsed, there is no room for a word — the icons speak for
            // themselves — but the space is kept so rows don't jump on expand.
            .opacity(isExpanded ? 1 : 0)
            .accessibilityHidden(!isExpanded)
    }

    /// A vertical scrim behind the rail so labels stay legible over artwork when
    /// expanded, fading out to nothing past the rail's trailing edge. Collapsed, it
    /// is a narrow, near-transparent wash that keeps the icons readable without
    /// putting a hard chrome slab over the page.
    private var backdrop: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(isExpanded ? 0.92 : 0.55), location: 0),
                .init(color: .black.opacity(isExpanded ? 0.86 : 0.34), location: 0.62),
                .init(color: .black.opacity(0), location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(
            width: (isExpanded ? NavigationRailMetrics.expandedWidth : NavigationRailMetrics.collapsedWidth)
                + NavigationRailMetrics.iconColumnWidth
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Copy

    private static let homeTitle = LocalizedStringResource(
        "navigationRail.home",
        defaultValue: "Home",
        comment: "Navigation rail destination."
    )
    private static let searchTitle = LocalizedStringResource(
        "navigationRail.search",
        defaultValue: "Search",
        comment: "Navigation rail destination."
    )
    private static let musicTitle = LocalizedStringResource(
        "navigationRail.music",
        defaultValue: "Music",
        comment: "Navigation rail destination."
    )
    private static let settingsTitle = LocalizedStringResource(
        "navigationRail.settings",
        defaultValue: "Settings",
        comment: "Navigation rail destination."
    )
    static let allLibrariesTitle = LocalizedStringResource(
        "navigationRail.allLibraries",
        defaultValue: "All Libraries",
        comment: "Navigation destination that browses every library at once."
    )
    private static let librariesTitle = LocalizedStringResource(
        "navigationRail.librariesHeader",
        defaultValue: "Libraries",
        comment: "Heading above the list of libraries in the navigation rail."
    )
    private static let switchProfileSubtitle = LocalizedStringResource(
        "navigationRail.switchProfile",
        defaultValue: "Switch profile",
        comment: "Subtitle under the profile name in the navigation rail."
    )
    private static let accessibilityTitle = LocalizedStringResource(
        "navigationRail.accessibilityLabel",
        defaultValue: "Navigation",
        comment: "VoiceOver label for the app's left navigation rail."
    )
}

/// What can hold focus inside the rail. The profile row isn't a destination, so it
/// needs its own case rather than being folded into ``NavigationRailDestination``.
private enum RailFocusTarget: Hashable {
    case profile
    case destination(NavigationRailDestination)
}

/// Rail row chrome. Focus is the standard tvOS inverted card; the *selected*
/// destination keeps a quieter accent wash so you can still see where you are
/// while focus is out in the content.
private struct NavigationRailItemStyle: ButtonStyle {
    let isSelected: Bool
    let accent: Color
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let invertedFill: Color = colorScheme == .dark ? .white : .black
        let invertedText: Color = colorScheme == .dark ? .black : .white
        let foreground: AnyShapeStyle = isFocused
            ? AnyShapeStyle(invertedText)
            : AnyShapeStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.primary))
        let fill: AnyShapeStyle = isFocused
            ? AnyShapeStyle(invertedFill)
            : AnyShapeStyle(isSelected ? accent.opacity(0.18) : Color.clear)

        return configuration.label
            .padding(.horizontal, PlozzTheme.Spacing.medium)
            .padding(.vertical, PlozzTheme.Spacing.small)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.content, style: .continuous)
                    .fill(fill)
            )
            .scaleEffect(isFocused ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
#endif
