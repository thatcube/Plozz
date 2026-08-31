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
    static let leadingInset: CGFloat = 28
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
    static let expandedWidth: CGFloat = 400
    /// Floating-menu geometry. Row pills sit exactly 14 points inside every panel
    /// edge. The outer radius adds that same inset to the pill radius, keeping their
    /// corner centres concentric.
    static let expandedRowBackgroundOutset: CGFloat = 4
    static let expandedPanelContentInset: CGFloat = 14
    static let expandedPanelHorizontalInset: CGFloat =
        leadingInset - expandedRowBackgroundOutset - expandedPanelContentInset
    static let expandedPanelVerticalInset: CGFloat =
        verticalPadding + bumperHeight + itemVerticalPadding - expandedPanelContentInset
    static let rowInnerPadding: CGFloat = 10
    static let expandedRowHeight: CGFloat =
        rowContentHeight + (rowInnerPadding * 2)
    static let expandedRowCornerRadius: CGFloat =
        expandedRowHeight / 2
    /// Aligns the icon centre with the centre of the capsule's leading arc.
    static let rowHorizontalPadding: CGFloat =
        expandedRowCornerRadius - (iconColumnWidth / 2)
    static let expandedPanelCornerRadius: CGFloat =
        expandedRowCornerRadius + expandedPanelContentInset
    static let itemIconSize: CGFloat = 26
    static let labelFont: Font = .system(size: 25, weight: .semibold)
    static let itemSpacing: CGFloat = 10
    /// Two points on each row edge creates four points between adjacent items.
    static let itemVerticalPadding: CGFloat = 2
    /// Matches ``iconColumnWidth`` exactly. Any larger and the avatar overflows the
    /// glyph column it shares with every other row, so it sits off the axis the
    /// icons below it line up on — and steals from the gap before the label.
    static let avatarSize: CGFloat = iconColumnWidth
    /// Fixed height of a destination row's content, collapsed AND expanded.
    ///
    /// Without this a row was only as tall as what it contained, and a label is
    /// taller than a glyph — so every row grew on expand and the gaps between them
    /// visibly opened up (~11pt a row, which over a dozen libraries is a lot of
    /// drift). Pinning the height to the taller of the two states means rows are
    /// already the right size before focus arrives, and expanding changes width
    /// only.
    static let rowContentHeight: CGFloat = 42
    /// The profile is a navigation row too: avatar + one label, matching every
    /// destination's vertical rhythm.
    static let profileRowHeight: CGFloat = rowContentHeight
    static let verticalPadding: CGFloat = 14
    /// Height of the invisible focus walls at each end of the rail.
    ///
    /// They sit IN the stack, so whatever height they take pushes the profile down
    /// and Settings up by the same amount. Only enough is needed for the focus
    /// engine to find one directly beyond the end row — it picks the nearest
    /// candidate in the direction of travel, and nothing else is closer.
    static let bumperHeight: CGFloat = 10
    /// How far the library list dissolves at its top and bottom edges.
    ///
    /// The list scrolls between fixed chrome — the LIBRARIES label above, the
    /// pinned Settings row below — so a row leaving it must fade out rather than
    /// be cut mid-glyph or, worse, carry on drawing over that chrome. Roughly one
    /// row tall, so a row is fully gone by the time it reaches either edge.
    static let listEdgeFade: CGFloat = 44
    /// How far the fade mask overhangs the list horizontally, so a focused row's
    /// pill and its shadow are not clipped by the mask that feathers the ends.
    static let listFadeHorizontalOverhang: CGFloat = 40
    static let dividerHorizontalInset: CGFloat = 20
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
    /// Mirrors "focus is inside the rail" outward, so the shell can coordinate
    /// preferred focus and directional fallback while the overlay is open.
    @Binding var isExpandedOutward: Bool
    let onOpenProfileSwitcher: () -> Void
    /// Bumped by the shell when its leading-edge catcher takes a Left press, so the
    /// rail pulls focus onto the current destination.
    var focusRequestToken: Int = 0
    /// Bumped when a Right press inside the rail resolved to nothing, so the rail
    /// gives focus back to the page.
    var focusReleaseToken: Int = 0

    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedTarget: RailFocusTarget?
    /// The last row that actually held focus, so an edge bumper can hand focus
    /// straight back to it.
    @State private var lastFocusedRow: RailFocusTarget?
    /// Makes every row unfocusable while focus is moving to the page. The rows stay
    /// unavailable until the next explicit request to open the rail, so a slow
    /// destination cannot let tvOS fall back into the menu.
    @State private var isReleasingFocus = false
    /// Continuously tracks how much content has moved past each edge, so the mask
    /// follows the scroll instead of flashing on at a threshold.
    @State private var libraryListFade = ListEdgeFade()

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
        // Handing focus back to the page: nothing in the rail may hold it.
        if isReleasingFocus { return false }
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
                sectionDivider
                libraryList
                sectionDivider
            } else {
                Spacer(minLength: 0)
            }

            item(.settings, symbol: "gearshape.fill", label: Text(Self.settingsTitle))

            edgeBumper(.bottomBumper)
        }
        .padding(.vertical, NavigationRailMetrics.verticalPadding)
        .padding(.leading, NavigationRailMetrics.leadingInset)
        .padding(.trailing, isExpanded ? NavigationRailMetrics.leadingInset : 0)
        .frame(
            width: isExpanded ? NavigationRailMetrics.expandedWidth : NavigationRailMetrics.collapsedWidth,
            alignment: .leading
        )
        .frame(maxHeight: .infinity, alignment: .top)
        // The panel itself never carries a shadow: blurring a full-height surface
        // forces the whole rail subtree through an offscreen render on every frame.
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
        // The shell's edge catcher took a Left press from the page. Claim focus for
        // the tab you are actually on — the catcher draws nothing, so nothing
        // flashes in between.
        .onChange(of: focusRequestToken) { _, _ in
            adoptFocus(.destination(selection))
        }
        // Right had nothing level with it to move to.
        .onChange(of: focusReleaseToken) { _, _ in
            releaseFocusToPage()
        }
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
        // A bare focusable, not a Button: on tvOS a Button paints the system focus
        // platter behind its label and `.focusEffectDisabled()` does not fully
        // remove it, which flashed a white slab over the rail as focus passed
        // through. Same reason `CircularFocusTile` and the media cards avoid one.
        Color.clear
            .frame(height: NavigationRailMetrics.bumperHeight)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            // Only a wall while focus is actually inside the rail — otherwise it
            // would be one more thing competing to catch a Left press from the page.
            // It also stands down while focus is being handed BACK to the page: the
            // wall exists to stop focus falling out of the ENDS of the rail, not to
            // stop it leaving sideways, and catching it here trapped the hand-off.
            .focusable(hasFocus && !isReleasingFocus)
            .focusEffectDisabled()
            .focused($focusedTarget, equals: target)
            .accessibilityHidden(true)
    }

    /// Hands focus back to the page.
    ///
    /// Clearing `@FocusState` alone does NOT move focus. Nothing has become
    /// unfocusable, so the focus engine has no reason to run an update and simply
    /// leaves focus where it is — the row stays lit and the press appears to do
    /// nothing. (Pressing Right repeatedly eventually shook it loose, which is
    /// exactly what that looks like from the sofa.)
    ///
    /// Making every row unfocusable is what forces the issue: the engine cannot
    /// leave focus on an item that can no longer hold it, so it runs an update and
    /// re-homes focus. By then the rail has collapsed and the shell has marked the
    /// page as its focus scope's preferred target, so focus lands on the page's own
    /// default rather than somewhere arbitrary. The rows remain unavailable until
    /// the next explicit rail-open request. That matters when a library is still
    /// loading and has no focusable content yet: restoring them on a timer lets
    /// tvOS re-home focus back into the rail and reopen it.
    private func releaseFocusToPage() {
        isReleasingFocus = true
        focusedTarget = nil
    }

    /// Whether `target` is the row an edge bumper is currently bouncing focus back
    /// to, so it can keep its highlight for that one run-loop turn.
    private func isBouncingOffBumper(_ target: RailFocusTarget) -> Bool {
        guard focusedTarget == .topBumper || focusedTarget == .bottomBumper else {
            return false
        }
        return (lastFocusedRow ?? .destination(selection)) == target
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
        // Never bounce while handing focus to the page. Focus passing through a
        // bumper on its way OUT is the hand-off working; bouncing it back here is
        // what made Right from Home appear to do nothing — focus left the row,
        // landed on the wall, and was immediately returned to the rail.
        guard !isReleasingFocus else { return }
        adoptFocus(lastFocusedRow ?? .destination(selection))
    }

    /// Moves focus to `target` a run-loop turn later.
    ///
    /// Assigning `@FocusState` from inside its own `onChange` is dropped, so the
    /// hand-off has to wait for the current focus transaction to finish.
    private func adoptFocus(_ target: RailFocusTarget) {
        Task { @MainActor in
            isReleasingFocus = false
            await Task.yield()
            focusedTarget = target
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
        .scrollIndicators(.hidden)
        // Takes whatever height is left between Home and the pinned Settings row.
        .frame(maxHeight: .infinity, alignment: .top)
        // The scroll view must NOT clip: a focused row's pill is wider than the
        // list (and carries a shadow), so the scroll view's own clip sheared its
        // right edge flat. Clipping is the mask's job instead — it cuts the ends
        // vertically, where rows would otherwise cover the chrome, while
        // overhanging horizontally so the pill stays whole.
        .scrollClipDisabled()
        // Rows must never be readable outside this list: with the clip disabled a
        // scrolled row kept drawing over the pinned Settings row below and the
        // section label above. The mask both clips and feathers, so a row dissolves
        // as it reaches either end instead of being cut mid-glyph. It overhangs
        // horizontally so a focused row's pill and shadow stay intact.
        //
        // Each end fades in continuously as content travels beneath it. The mask
        // always keeps the same view structure and geometry, avoiding the flicker
        // caused by inserting/removing a gradient at a one-point threshold.
        .verticalEdgeFadeMask(
            fadeHeight: NavigationRailMetrics.listEdgeFade,
            topStrength: libraryListFade.top,
            bottomStrength: libraryListFade.bottom,
            horizontalOverhang: NavigationRailMetrics.listFadeHorizontalOverhang
        )
        .onScrollGeometryChange(for: ListEdgeFade.self) { geometry in
            let top = geometry.contentOffset.y + geometry.contentInsets.top
            let bottom = geometry.contentSize.height
                - (geometry.contentOffset.y + geometry.containerSize.height)
            return ListEdgeFade(
                top: ListEdgeFade.strength(for: top),
                bottom: ListEdgeFade.strength(for: bottom)
            )
        } action: { _, fade in
            libraryListFade = fade
        }
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
                    PlozzMarqueeText(
                        text: Text(verbatim: profile.name),
                        font: NavigationRailMetrics.labelFont,
                        color: foregroundColor(for: .profile, isSelected: false),
                        inset: 0,
                        fadeWidth: 16,
                        isFocused: focusedTarget == .profile
                    )
                }
                if isExpanded { Spacer(minLength: 0) }
            }
            // Text appears at once rather than fading in. The rail is a small,
            // frequently-used control; crossfading its labels reads as sluggish
            // where an instant swap reads as responsive. Only the WIDTH animates.
            .animation(nil, value: isExpanded)
            .frame(height: NavigationRailMetrics.profileRowHeight)
            .frame(maxWidth: isExpanded ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            NavigationRailItemStyle(
                isExpanded: isExpanded,
                isSelected: false,
                accent: palette.accent
            )
        )
        .padding(.vertical, NavigationRailMetrics.itemVerticalPadding)
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
            // Activating a destination is the same commitment as selecting it and
            // pressing Right: close the menu and enter the page immediately.
            releaseFocusToPage()
        } label: {
            HStack(spacing: PlozzTheme.Spacing.medium) {
                Image(systemName: symbol)
                    .font(.system(size: NavigationRailMetrics.itemIconSize, weight: .semibold))
                    .frame(width: NavigationRailMetrics.iconColumnWidth)
                    .accessibilityHidden(true)
                if isExpanded {
                    PlozzMarqueeText(
                        text: label,
                        font: NavigationRailMetrics.labelFont,
                        color: foregroundColor(
                            for: .destination(destination),
                            isSelected: selection == destination
                        ),
                        inset: 0,
                        fadeWidth: 16,
                        isFocused: focusedTarget == .destination(destination)
                    )
                }
                if isExpanded { Spacer(minLength: 0) }
            }
            // Labels appear at once instead of fading — see `profileButton`.
            .animation(nil, value: isExpanded)
            // The row is the SAME height in both states, so expanding does not
            // reflow the rail vertically. See `rowContentHeight`.
            .frame(height: NavigationRailMetrics.rowContentHeight)
            // Collapsed, the row hugs its icon: stretching it to the rail's full
            // width made the selected/focused pill wider than the glyph, so the
            // icon read as sitting left of centre inside it.
            .frame(maxWidth: isExpanded ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            NavigationRailItemStyle(
                isExpanded: isExpanded,
                isSelected: selection == destination,
                accent: palette.accent,
                holdsFocusStyling: isBouncingOffBumper(.destination(destination))
            )
        )
        .padding(.vertical, NavigationRailMetrics.itemVerticalPadding)
        .focused($focusedTarget, equals: .destination(destination))
        .disabled(!isRowFocusable(.destination(destination)))
        .accessibilityLabel(label)
        .accessibilityAddTraits(selection == destination ? [.isSelected] : [])
    }

    private func foregroundColor(
        for target: RailFocusTarget,
        isSelected: Bool
    ) -> Color {
        let focused = focusedTarget == target || isBouncingOffBumper(target)
        if focused {
            return colorScheme == .dark ? .black : .white
        }
        return isSelected ? palette.accent : .primary
    }

    /// A quiet separator between fixed destinations and the viewer's libraries.
    /// It stays identical in both rail states so expansion changes no content.
    private var sectionDivider: some View {
        Capsule(style: .continuous)
            .fill(.white.opacity(0.22))
            .frame(
                width: isExpanded
                    ? NavigationRailMetrics.expandedWidth
                        - (NavigationRailMetrics.leadingInset * 2)
                        + (NavigationRailMetrics.expandedRowBackgroundOutset * 2)
                        - (NavigationRailMetrics.dividerHorizontalInset * 2)
                    : NavigationRailMetrics.iconColumnWidth * 0.6,
                height: 2
            )
            .frame(
                width: isExpanded ? nil : NavigationRailMetrics.iconColumnWidth,
                alignment: .center
            )
            .frame(
                maxWidth: isExpanded ? .infinity : nil,
                alignment: .center
            )
            // Collapsed, match the icon's own offset inside its focus pill.
            .padding(.leading, isExpanded ? 0 : NavigationRailMetrics.rowHorizontalPadding)
            .padding(.vertical, PlozzTheme.Spacing.medium)
            .accessibilityHidden(true)
    }

    /// The rail's backing.
    ///
    /// The open rail uses the same floating glass surface as playback and source
    /// menus. Collapsed, there is no panel at all: the compact icon column remains
    /// directly over the page artwork.
    @ViewBuilder
    private var backdrop: some View {
        if isExpanded {
            // Instant, like the labels: fading a full-height panel in behind text
            // that has already appeared reads as the rail lagging its own contents.
            expandedBackdrop.animation(nil, value: isExpanded)
        }
    }

    private var expandedBackdrop: some View {
        Color.clear
            .plozzGlassPanel(
                cornerRadius: NavigationRailMetrics.expandedPanelCornerRadius,
                scrimOpacity: 0.08
            )
            .padding(.horizontal, NavigationRailMetrics.expandedPanelHorizontalInset)
            .padding(.vertical, NavigationRailMetrics.expandedPanelVerticalInset)
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
/// Normalized fade strength at each edge of the scrolling library list.
private struct ListEdgeFade: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0

    static func strength(for overflow: CGFloat) -> CGFloat {
        let progress = min(max(overflow / NavigationRailMetrics.listEdgeFade, 0), 1)
        return progress * progress * (3 - 2 * progress)
    }
}

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
    let isExpanded: Bool
    let isSelected: Bool
    let accent: Color
    /// Keeps the row drawn as focused while an edge bumper briefly holds focus.
    ///
    /// Pressing Down on the last row must do NOTHING. The block works by giving
    /// the focus engine an invisible row to land on and handing focus straight
    /// back — but that round trip takes a run-loop turn, during which this row is
    /// genuinely unfocused and its highlight dropped. That flicker read as the row
    /// being re-focused on every press. Holding the highlight makes the bounce
    /// invisible, which is what "nothing happens" should look like.
    var holdsFocusStyling: Bool = false
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let isFocused = isFocused || holdsFocusStyling
        let invertedFill: Color = colorScheme == .dark ? .white : .black
        let invertedText: Color = colorScheme == .dark ? .black : .white
        let foreground: AnyShapeStyle = isFocused
            ? AnyShapeStyle(invertedText)
            : AnyShapeStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.primary))
        let fill: AnyShapeStyle = isFocused
            ? AnyShapeStyle(invertedFill)
            : AnyShapeStyle(
                isSelected
                    ? accent.opacity(0.20)
                    : Color.clear
            )
        return configuration.label
            // Fixed content geometry keeps the icon perfectly still while the rail
            // expands. Matching insets around the square icon slot makes a circle.
            .padding(.leading, NavigationRailMetrics.rowHorizontalPadding)
            .padding(.trailing, NavigationRailMetrics.rowHorizontalPadding)
            .padding(.vertical, NavigationRailMetrics.rowInnerPadding)
            .foregroundStyle(foreground)
            // The rail sits over artwork, so an unfocused glyph carries its own
            // contrast while collapsed. The open menu panel supplies that contrast.
            .shadow(
                color: .black.opacity(isExpanded || isFocused ? 0 : 0.85),
                radius: 5,
                y: 1
            )
            .background(
                Capsule(style: .continuous)
                    .fill(fill)
                    .padding(
                        .horizontal,
                        isExpanded ? -NavigationRailMetrics.expandedRowBackgroundOutset : 0
                    )
            )
    }
}
#endif
