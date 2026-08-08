#if os(tvOS)
import SwiftUI
import CoreModels
import CoreUI
import FeatureProfiles

/// Fixed geometry for the custom navigation rail. Collected here so the shell's
/// content inset and the rail's own layout can never drift apart.
enum NavigationRailMetrics {
    /// How far a row's icon sits from the **physical** left edge of the screen.
    ///
    /// The rail deliberately breaks out of the tvOS title-safe area. That margin is
    /// the empty band down the side of the picture, and it is exactly where this
    /// navigation belongs — sitting inside the safe area instead put the icons on
    /// top of the page's own left-aligned content, which is what made the rail read
    /// as floating over the page rather than beside it.
    static let leadingInset: CGFloat = 20
    /// The icon column inside a row.
    static let iconColumnWidth: CGFloat = 42
    /// Total width of the collapsed rail, measured from the physical screen edge.
    static let collapsedWidth: CGFloat = leadingInset + iconColumnWidth + 18

    /// Extra inset applied to the page's content, ON TOP of the title-safe area it
    /// already respects.
    ///
    /// Small on purpose: the rail lives in the safe-area margin, so the page only
    /// has to give up the sliver where the two would otherwise touch. Applied as
    /// real padding rather than a safe-area inset because the Home hero sizes its
    /// foreground to the full screen width by design, and a safe-area inset leaves
    /// that column exactly where it was — under the icons.
    static let contentInset: CGFloat = 64

    /// Width the rail grows to once focus enters it.
    static let expandedWidth: CGFloat = 420
    static let itemSpacing: CGFloat = 6
    static let avatarSize: CGFloat = 48
    static let verticalPadding: CGFloat = 28
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
    /// Mirrors "focus is inside the rail" outward, so the shell can slide the page
    /// aside rather than let the expanded rail cover it.
    @Binding var isExpandedOutward: Bool
    let onOpenProfileSwitcher: () -> Void

    @Environment(\.themePalette) private var palette
    @FocusState private var focusedTarget: RailFocusTarget?
    /// The last row that actually held focus, so an edge bumper can hand focus
    /// straight back to it.
    @State private var lastFocusedRow: RailFocusTarget?

    /// The rail is expanded exactly while it holds focus — "move focus into it to
    /// open it", with no timers and no separate toggle to get out of sync.
    private var isExpanded: Bool { focusedTarget != nil }

    /// Whether focus is currently inside the rail.
    ///
    /// Drives which rows are focusable at all: see ``isRowFocusable(_:)``.
    private var hasFocus: Bool { focusedTarget != nil }

    /// Whether a row may hold focus right now.
    ///
    /// **From outside the rail, only the CURRENT destination is focusable.** That
    /// is what makes a Left press land on the tab you are actually on rather than
    /// on whichever row happens to sit nearest the card you came from. Steering
    /// focus by controlling what is focusable is the approach that works on tvOS;
    /// redirecting after the fact visibly flashes the wrong row first.
    ///
    /// Once focus is inside, everything opens up so Up/Down walk the whole rail.
    private func isRowFocusable(_ target: RailFocusTarget) -> Bool {
        if hasFocus { return true }
        return target == .destination(selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Invisible focus walls. Pressing Up from the top row (or Down from
            // Settings) must do NOTHING — the rail is a list you leave sideways,
            // not by falling out of either end. The focus engine will happily jump
            // to a page card that is merely near, so the reliable block is to give
            // it a nearer candidate inside the rail and hand focus straight back.
            // The bumper draws nothing, so the bounce is invisible: the row you
            // were on simply stays put.
            edgeBumper(.topBumper)

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

            edgeBumper(.bottomBumper)
        }
        .padding(.vertical, NavigationRailMetrics.verticalPadding)
        .padding(.leading, NavigationRailMetrics.leadingInset)
        .frame(
            width: isExpanded ? NavigationRailMetrics.expandedWidth : NavigationRailMetrics.collapsedWidth,
            alignment: .leading
        )
        .frame(maxHeight: .infinity, alignment: .top)
        // Legibility WITHOUT a backing while collapsed — see `backdrop`. Two
        // shadows: a tight one for the glyph's own edge, a wide soft one to lift it
        // off a pale patch of artwork. This is what overlay text on video does, and
        // it costs no visible area, so nothing reads as a bar down the screen.
        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
        .shadow(color: .black.opacity(0.38), radius: 12, y: 2)
        .background(alignment: .leading) { backdrop }
        .animation(NavigationRailMetrics.expandAnimation, value: isExpanded)
        // One focus section, so a Left press from the content lands in the rail as
        // a unit instead of picking whichever row happens to be geometrically
        // nearest, and a Right press returns to the content rather than walking
        // through every remaining rail row.
        .focusSection()
        .accessibilityLabel(Text(Self.accessibilityTitle))
        .onChange(of: isExpanded) { _, expanded in
            isExpandedOutward = expanded
        }
        .onDisappear { isExpandedOutward = false }
        .onChange(of: focusedTarget) { _, target in
            switch target {
            case .topBumper, .bottomBumper:
                returnFromBumper()
            case .some(let row):
                lastFocusedRow = row
            case nil:
                break
            }
        }
    }

    /// A zero-chrome focus target at each end of the rail. It renders nothing, so
    /// landing on it and bouncing away is invisible.
    private func edgeBumper(_ target: RailFocusTarget) -> some View {
        Button(action: {}) {
            Color.clear
                .frame(height: 44)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focusedTarget, equals: target)
        // Only a wall while focus is actually inside the rail — otherwise it would
        // be one more thing competing to catch a Left press from the page.
        .disabled(!hasFocus)
        .accessibilityHidden(true)
    }

    /// Hands focus back to the row the viewer was on, so an Up/Down press at
    /// either end of the rail is a no-op rather than an exit.
    ///
    /// Deliberately no re-entrancy guard: the destination is never a bumper, so
    /// this cannot recurse — and a guard that latched would leave focus parked on
    /// an invisible row, which is the one outcome worse than the bounce itself.
    /// The hand-back waits a run-loop turn because assigning `@FocusState` from
    /// inside its own `onChange` is dropped (the same reason the reorder list
    /// restores focus after layout).
    private func returnFromBumper() {
        let destination = lastFocusedRow ?? .destination(selection)
        Task { @MainActor in
            await Task.yield()
            focusedTarget = destination
        }
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
                if isExpanded { Spacer(minLength: 0) }
            }
            .frame(maxWidth: isExpanded ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NavigationRailItemStyle(isSelected: false, accent: palette.accent))
        .focused($focusedTarget, equals: .profile)
        .disabled(!isRowFocusable(.profile))
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
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: NavigationRailMetrics.iconColumnWidth)
                    .accessibilityHidden(true)
                if isExpanded {
                    label
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .transition(.opacity)
                }
                if isExpanded { Spacer(minLength: 0) }
            }
            // Collapsed, the row hugs its icon: stretching it to the rail's full
            // width made the selected/focused pill wider than the glyph, so the
            // icon read as sitting left of centre inside it.
            .frame(maxWidth: isExpanded ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            NavigationRailItemStyle(
                isSelected: selection == destination,
                accent: palette.accent
            )
        )
        .focused($focusedTarget, equals: .destination(destination))
        .disabled(!isRowFocusable(.destination(destination)))
        .accessibilityLabel(label)
        .accessibilityAddTraits(selection == destination ? [.isSelected] : [])
    }

    private func sectionLabel(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .plozzForeground(.secondary)
            .lineLimit(1)
            .padding(.leading, PlozzTheme.Spacing.small)
            .padding(.top, PlozzTheme.Spacing.large)
            .padding(.bottom, PlozzTheme.Spacing.xSmall)
            // Collapsed, there is no room for a word — the icons speak for
            // themselves — but the space is kept so rows don't jump on expand.
            .opacity(isExpanded ? 1 : 0)
            .accessibilityHidden(!isExpanded)
    }

    /// The rail's backing.
    ///
    /// Never a panel with an edge, and nothing at all while collapsed.
    ///
    /// A wash wide enough to sit under the LABELS is far wider than the icon
    /// column, so while collapsed it painted a dark band roughly 180pt into a
    /// bright hero — indistinguishable from a black bar down the side of the
    /// picture. Collapsed, the rail is icons only, and a shadow on the glyphs
    /// (applied above) keeps those legible over anything without covering
    /// artwork. So the wash appears only when the labels do.
    ///
    /// Expanded it is a wide, slow gradient that has fully dissolved before it
    /// reaches the page: a short one over a bright backdrop reads as a hard
    /// vertical seam. The page also slides aside on expand, so this never has to
    /// make text readable over content it overlaps.
    @ViewBuilder
    private var backdrop: some View {
        if isExpanded { expandedBackdrop }
    }

    private var expandedBackdrop: some View {
        let strength = 0.82
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(strength), location: 0),
                .init(color: .black.opacity(strength * 0.92), location: 0.35),
                .init(color: .black.opacity(strength * 0.55), location: 0.68),
                .init(color: .black.opacity(strength * 0.18), location: 0.87),
                .init(color: .black.opacity(0), location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: NavigationRailMetrics.expandedWidth + 180)
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
    /// The invisible walls at each end that stop focus falling out of the rail.
    case topBumper
    case bottomBumper
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
            : AnyShapeStyle(isSelected ? accent.opacity(0.20) : Color.clear)

        return configuration.label
            .padding(.horizontal, PlozzTheme.Spacing.xSmall)
            .padding(.vertical, PlozzTheme.Spacing.xSmall)
            .foregroundStyle(foreground)
            // The rail sits over artwork, so an unfocused glyph carries its own
            // contrast rather than relying on the scrim alone.
            .shadow(color: .black.opacity(isFocused ? 0 : 0.85), radius: 5, y: 1)
            .background(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.content, style: .continuous)
                    .fill(fill)
            )
            .scaleEffect(isFocused ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
#endif
