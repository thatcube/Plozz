#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureHomeCore
import MetadataKit
#if canImport(UIKit)
import UIKit
#endif

/// The top "hero" section of a detail page: a full-bleed backdrop with the
/// item's title, subtitle, ratings, overview, and an optional Play button.
///
/// It is intentionally stateless and driven entirely by `item`, so a parent can
/// swap which item it shows (series → focused season → focused episode) and the
/// whole hero animates to reflect the newly focused context.
struct DetailHeroView: View {
    let item: MediaItem
    @Environment(HeroTrailerController.self) private var heroTrailerController
    @Environment(HeroBackgroundSettingsModel.self) private var heroBackground
    /// The item whose artwork fills the backdrop *and* supplies the branded title
    /// logo. Defaults to `item`. A series page pins this to the series itself so
    /// the background and logo stay a single, stable, show-level identity even as
    /// `item` (the focused season/episode) drives the title text, overview and
    /// Play button. The logo is the show's wordmark — identical for every episode
    /// — so sourcing it here keeps it present no matter which episode is fronted
    /// (e.g. arriving via "Go to Season"/Continue Watching fronts the next-up
    /// episode, which has no logo of its own). Swapping the backdrop per focused
    /// episode reads as distracting flicker, so we don't.
    var backdropItem: MediaItem?
    /// Fraction of the screen height the hero backdrop occupies. Defaults to a
    /// full-screen cinematic hero (`1.0`); a TV show shrinks this (e.g. `0.8`) so
    /// the season tabs and episode row peek above the fold, signalling there's
    /// more to scroll to.
    var heroHeightFraction: CGFloat = 1.0
    /// Stable title used when no logo resolves. A series page supplies the series
    /// title so the fallback remains the same identity while episodes are browsed.
    var titleFallbackOverride: String? = nil
    /// Whether this hero fronts an item that has a parent page worth returning to
    /// — an episode shown on its own page, which offers "Go to Season" so you can
    /// reach the show even when you arrived from Continue Watching rather than
    /// from the show itself. Off for a series page, whose hero fronts a play
    /// target that already belongs to the page you're on.
    var offersParentNavigation: Bool = false
    /// Renders the episode-page hero: the episode's own 16:9 still, inset over
    /// the themed background, with the show's name as a breadcrumb above the
    /// episode title — instead of the full-bleed backdrop + show wordmark.
    ///
    /// A hero's job is to answer "what am I looking at". On a series page that's
    /// the show, so its backdrop and logo are right. On an episode page it's the
    /// episode — and dressing it in the show's artwork makes every episode look
    /// identical to every other episode *and* to the series page.
    var presentsEpisodeStill: Bool = false
    /// The item hero *actions* apply to, when that differs from `item`.
    ///
    /// On a series page whose hero rests on the show — nothing watched, or all of
    /// it watched — Play still starts a specific episode. Without this, the
    /// Watched button beside it acted on `item` and marked the **entire series**
    /// watched, which contradicts the Play button it sits next to and is
    /// destructive when hit by accident.
    ///
    /// Watchlist is deliberately excluded: you save a *show*, not an episode, so
    /// it keeps targeting `item`.
    var actionItem: MediaItem?
    /// Optional series-only cosmetic recede state. The model is consumed by leaf
    /// modifiers so changing it never invalidates the parent page or episode rail.
    var seriesRecedeModel: SeriesHeroRecedeModel? = nil
    /// A short air-schedule line for a still-airing series, e.g. "New episodes
    /// Fridays" or "New season Aug 5". `nil` when nothing is known.
    var scheduleLine: LocalizedStringResource? = nil
    let spoilerSettings: SpoilerSettings
    /// Title for the Play/Resume button, or `nil` to omit the button entirely
    /// (e.g. a season with no resolved episodes yet).
    let playTitle: LocalizedStringResource?
    let onPlay: (() -> Void)?
    /// When provided (`0..<1`), a thin watched-progress bar is shown inside the
    /// Play button, between the play icon and the remaining-time line.
    var playProgress: Double? = nil
    /// When provided, a "… left" remaining-time line is shown inside the Play
    /// button, after the progress bar.
    var playRemainingText: String? = nil
    /// The episode the Play button will play, as `S{n}, E{m}` — appended to the plain
    /// label ("Play S21, E8") and prefixed to the resume trailing ("S5, E12 • 43m").
    /// For a series hero this is the next-up/resume episode's S/E, not the series.
    var playSeasonEpisodeText: String? = nil
    /// When provided, a secondary "Trailer" button is shown next to Play.
    var onPlayTrailer: (() -> Void)? = nil
    /// The selectable versions for this title. When more than one exists and
    /// `onSelectVersion` is set, a "Version" picker button is shown next to Play
    /// so the user can choose which source `Play` targets.
    var versions: [MediaVersion] = []
    /// The currently-effective selected version id (drives the picker's label and
    /// the menu checkmark). `nil` falls back to the first/recommended version.
    var selectedVersionID: String? = nil
    /// Invoked with the chosen `MediaVersion.id` when the user picks a version.
    var onSelectVersion: ((String) -> Void)? = nil
    /// The cross-server sources for this (possibly merged) title. When more than
    /// one *distinct server* holds the title and `onSelectSource` is set, a
    /// "Server" picker button is shown next to Play (in the same style as the
    /// version picker) so the user can choose which server `Play` targets. Empty
    /// or single-server titles show no server picker.
    var sources: [MediaSourceRef] = []
    /// Accounts currently offline / unreachable — greyed and unselectable in the
    /// server picker.
    var offlineSourceAccountIDs: Set<String> = []
    /// The currently-effective selected source's account id (drives the server
    /// picker's label and the menu checkmark). `nil` falls back to the primary.
    var selectedSourceAccountID: String? = nil
    /// Invoked with the chosen source's `accountID` when the user picks a server.
    var onSelectSource: ((String) -> Void)? = nil
    /// Technical badges to show when the focused item carries none of its own —
    /// a series or season hero has no media file, so the parent derives a
    /// representative set from the loaded episodes (best resolution/HDR/audio)
    /// and passes it here so a show still advertises 4K/Dolby Vision/Atmos.
    var fallbackTechnicalBadges: [MediaBadge] = []
    /// When provided, the hero's Play button binds to this focus state (as
    /// `true`), letting a parent give Play initial focus — used when a page is
    /// opened targeting a specific episode so focus lands on Play at the top
    /// rather than down in the episode row.
    var playButtonFocus: FocusState<Bool>.Binding? = nil
    /// Invoked whenever focus lands on (or moves between) *any* button in the hero
    /// action row — Play, Trailer, watchlist, watched, Refresh, the "…" menu, or
    /// the discovery request pill. The parent uses this to re-pin the page to the
    /// hero top, so horizontal navigation across the bottom-anchored row can't let
    /// tvOS's focus-reveal auto-scroll drift the whole page down. Fires on every
    /// intra-row focus change (not just on entering the row), because tvOS re-nudges
    /// the scroll for each newly-focused button. `nil` leaves scroll behaviour
    /// untouched.
    var onHeroActionFocused: (() -> Void)? = nil
    /// Focus has left the hero's action row entirely — so it is somewhere below,
    /// in the browser or the extras. Unlike a row's "focus entered" callback this
    /// is an unmissable signal: it comes from SwiftUI's own focus state rather
    /// than an edge a fast key-press can outrun.
    var onHeroActionBlurred: (() -> Void)? = nil
    /// Marks this hero as presenting a **discovery** (Seerr) title that isn't in
    /// the library. When `true` the library-only action buttons (Play, Trailer,
    /// watchlist/watched/refresh, server/version "…" menu) are suppressed and the
    /// row shows a single request/status pill driven by ``requestCTA`` instead.
    var isDiscoveryItem: Bool = false
    /// The request/download CTA for a discovery title, derived from its Seerr
    /// availability via ``MediaItem/heroCTA(availability:downloadProgress:seerConnected:)``
    /// (with any just-tapped optimistic override already applied by the parent).
    /// Ignored unless ``isDiscoveryItem`` is `true`.
    var requestCTA: HeroCTA = .play
    /// Display name of the Seerr user the request will be made as, when the active
    /// profile is mapped. When set and the CTA is `.request`, the pill reads
    /// "Request as <name>" so the acting identity is visible before the press.
    /// `nil` = plain "Request" (admin).
    var requestActingName: String? = nil
    /// One-tap request action, invoked when the user activates the "Request" pill.
    /// `nil` disables requesting (e.g. Seerr disconnected), leaving the pill inert.
    var onRequest: (() -> Void)? = nil
    /// Season-level request state for a discovery series. When present, the hero
    /// replaces its one-tap title request with the shared season request menu.
    var seasonRequestAvailability: MediaRequestAvailability? = nil
    var seasonRequestAvailabilityResolved: Bool = false
    var seasonRequestAvailabilityFailed: Bool = false
    var isRequestingSeasons: Bool = false
    var onRequestSeasons: (([Int]) -> Void)? = nil
    var onRetrySeasonRequestAvailability: (() -> Void)? = nil

    /// Local focus state of the Play button, so the inline resume progress bar
    /// can flip its colours to stay visible against the button's focused (white)
    /// vs unfocused (dark) background.
    @FocusState private var playButtonHasFocus: Bool
    /// Focus state of the discovery request/status pill, so its inline download
    /// progress capsule flips colour against the focused (white) pill background,
    /// mirroring the Play button.
    @FocusState private var requestPillHasFocus: Bool
    /// The last non-nil resume "… left" text seen for the current play target. The
    /// Play button reserves the width of the resume form (▶ bar … left) using this
    /// even after the item is marked Watched (which clears the live resume text),
    /// so the button — and every button beside it — never shrinks/shifts on that
    /// transition. Resets naturally when a new target supplies fresh resume text.
    @State private var reservedResumeText: String?
    /// Whether the Refresh Metadata button currently holds focus. On tvOS 26 the
    /// focused glass button turns near-white, so the standard green success check
    /// washes out — when focused we switch it to a darker green that stays legible.
    @FocusState private var refreshButtonHasFocus: Bool

    /// Identifies each focusable control in the hero action row. A single
    /// `@FocusState` bound to this enum funnels every action button through one
    /// signal, so the parent can be told the instant focus lands on — or moves
    /// between — any of them. This exists purely to drive the "keep the row pinned
    /// to the hero top" correction (see ``onHeroActionFocused``); the per-button
    /// bool focus states above still own their local colour/behaviour tweaks.
    private enum HeroRowAction: Hashable {
        case play, trailer, watchlist, watched, refresh, more, request, parent
    }

    /// The action-row control that currently holds focus, or `nil` when focus is
    /// outside the row. Every button in the row binds to this via
    /// `.focused($heroActionRowFocus, equals:)`; a non-nil change fires
    /// ``onHeroActionFocused``.
    @FocusState private var heroActionRowFocus: HeroRowAction?

    /// Scopes the hero action row (Play, Trailer, …) so the Play button can be its
    /// preferred default focus. When focus moves UP into this section from a season
    /// chip parked far to the right, tvOS would otherwise land on the geometrically
    /// nearest (right-most) control — the "…" menu — instead of Play. Marking Play
    /// as the scope's preferred default makes "up" from any season reliably land on
    /// Play, matching the page's contract that Play is the action row's home.
    @Namespace private var heroActionsScope


    /// Set the instant the user taps a server row in the "…" menu, and consumed by
    /// the `selectedSourceAccountID` `onChange` below. It gates the focus re-assert
    /// so we only park focus back on "…" after a *user-initiated* server switch —
    /// never when late cross-server discovery first populates the menu (which would
    /// otherwise yank focus off Play the moment the page finishes loading, on both
    /// movies and series).
    @State private var userInitiatedSourceSwitch = false

    /// Drives the hero's first-appearance fade-in. Starts hidden and eases to
    /// visible `.onAppear`, so the backdrop + title/metadata dissolve in rather
    /// than hard-cutting when the page opens. Subsequent context swaps fade via
    /// the value-keyed `.animation` on `item.id`/`backdrop.id`.
    @State private var heroVisible = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The app-installed action handler (the SAME one the press-and-hold context
    /// menu reads). Drives the visible Watchlist / Watched / Refresh hero buttons
    /// so they are byte-for-byte consistent with the long-press menu — optimistic
    /// update, cross-provider fan-out and mutation broadcast all go through it.
    /// `nil` in previews/tests, which simply hides the buttons.
    @Environment(\.mediaItemActionHandler) private var actionHandler
    /// Surrounding-list context, so a hero acting on a focused episode behaves
    /// exactly like that episode's context-menu would.
    @Environment(\.mediaItemActionContext) private var actionContext
    /// Routes "Go to Season" out of this page — see `offersParentNavigation`.
    @Environment(\.mediaItemNavigator) private var navigator
    /// Drives the Refresh button's animated state machine: the refresh itself is
    /// a fire-and-forget server task, so this gives the user visible feedback —
    /// idle ➝ a spinning "refreshing" indicator ➝ a green success check ➝ back to
    /// idle, with each icon animating in and out.
    @State private var refreshPhase: RefreshPhase = .idle
    /// Gates the breadcrumb out of the focus system until entry focus has landed
    /// on Play — see `seriesBreadcrumb`.
    @State private var breadcrumbAcceptsFocus = false

    /// The visible lifecycle of the Refresh Metadata button.
    private enum RefreshPhase {
        case idle, refreshing, success
    }

    /// Uniform square footprint for the secondary hero icon buttons (watchlist,
    /// watched, refresh) so their differing SF Symbol widths — the `eye` glyph in
    /// particular — don't make one button wider than the rest. This also sets the
    /// watched-state circle's diameter.
    private let heroIconSize: CGFloat = 38

    /// Explicit point size for the secondary hero glyphs (eye/bookmark/refresh) so
    /// they render at a consistent size that visually matches the filled circle,
    /// rather than tvOS's oversized default button font.
    private let heroGlyphSize: CGFloat = 30

    /// The active light/dark appearance. The unfocused prominent button is dark
    /// in dark mode but light in light mode, so the inline progress bar must take
    /// the colour scheme into account — otherwise its white fill vanishes against
    /// the light unfocused button in light mode.
    @Environment(\.colorScheme) private var colorScheme

    @State private var presentationCache = HeroPresentationCache()

    /// The item supplying the backdrop artwork (the pinned series, when set).
    private var backdrop: MediaItem { backdropItem ?? item }

    // Both presentations are MEMOIZED, and that is a measured performance fix
    // rather than a style preference.
    //
    // `HeroPresentation.init` is not cheap — artwork routing, title
    // normalisation, badge composition, several array maps/filters/joins and
    // provider-id lookups — and these were plain computed properties, so every
    // one of the ~22 references across this view rebuilt one from scratch on
    // every body evaluation. Browsing the episode rail re-evaluates this hero on
    // each card, which is exactly where Instruments put the cost: the app-update
    // phase averaged 17.3 ms/frame against a 16.7 ms total budget, with 355 ms
    // spikes, on an A12 Apple TV.
    //
    // A struct can't memoise into itself, so the cache is a reference type held
    // in `@State` — created once per view lifetime and keyed by the item's
    // identity, so a new item recomputes and a re-render of the same item does
    // not. `HeroPresentation` is a value type built purely from the item, so
    // this cannot go stale as long as the key covers what it reads.
    private var focusedPresentation: HeroPresentation {
        presentationCache.presentation(for: item)
    }

    private var rootPresentation: HeroPresentation {
        presentationCache.presentation(for: backdrop)
    }

    /// Tone of the hero legibility scrim: a dark wash in dark mode (so light
    /// content reads against the artwork) and a light wash in light mode (so dark
    /// content does). The scrim geometry is identical across modes — only this
    /// tone flips — so legibility stays consistent between appearances.
    private var scrimTone: Color { colorScheme == .dark ? .black : .white }

    private var heroLogoHeight: CGFloat { 200 }
    /// Width cap for the hero logo, sized to the hero's text column so the wordmark
    /// never runs wider than the overview beneath it.
    private var heroLogoWidth: CGFloat { 620 }

    // MARK: - Visible item actions (discoverability)

    /// The subject of watched-state actions: the play target when it differs from
    /// the editorial hero, else the hero itself.
    private var watchedActionItem: MediaItem { actionItem ?? item }

    /// The capability-gated actions the installed handler offers for the focused
    /// `item`. Identical to what the context menu shows, so the visible buttons
    /// and the long-press menu can never drift apart.
    private var heroActions: [MediaItemAction] {
        actionHandler?.actions(for: item, context: actionContext) ?? []
    }

    /// Actions offered for the *play target*, which is what watched-state buttons
    /// act on. Same list when the two items are the same.
    private var watchedActionCandidates: [MediaItemAction] {
        guard actionItem != nil else { return heroActions }
        return actionHandler?.actions(for: watchedActionItem, context: actionContext) ?? []
    }

    /// The watchlist toggle for `item`, if its resolving provider conforms to
    /// `WatchlistProviding` (offered only for whole titles — movies/series).
    private var heroWatchlistAction: MediaItemAction? {
        heroActions.first { $0 == .addToWatchlist || $0 == .removeFromWatchlist }
    }

    /// The watched-state toggle, resolved against the play target so it can never
    /// mark a whole series watched while the Play button beside it starts one
    /// episode. On a series page this lights up for the episode Play would run.
    private var heroWatchedAction: MediaItemAction? {
        watchedActionCandidates.first { $0 == .markWatched || $0 == .markUnwatched }
    }

    /// Whether to show the Refresh Metadata button (provider conforms to
    /// `MetadataRefreshing`).
    private var heroOffersRefresh: Bool { heroActions.contains(.refreshMetadata) }

    private var heroMenuActions: [MediaItemAction] {
        var seen = Set<MediaItemAction>()
        return (heroActions
            + (actionHandler?.actions(
                for: backdrop,
                context: actionContext
            ) ?? []))
            .filter { offersHeroAction($0) && seen.insert($0).inserted }
    }

    /// Navigation is dropped from a hero menu except when it leaves for a parent
    /// this page can't otherwise reach, and only when something can route it.
    private func offersHeroAction(_ action: MediaItemAction) -> Bool {
        guard action.isNavigation else { return true }
        return offersParentNavigation && !action.navigatesToSelf && navigator != nil
    }

    private var heroContextMenuActions: [MediaItemAction] {
        heroMenuActions.filter { !$0.isPrimaryDetailAction && $0 != heroParentNavigationAction }
    }

    /// The navigation action shown as its own button in the action row, so an
    /// episode page has a *visible* way back to its show rather than one buried
    /// in a long-press menu. Nil unless this hero fronts an item with a parent
    /// page and something can route there.
    private var heroParentNavigationAction: MediaItemAction? {
        guard offersParentNavigation, navigator != nil else { return nil }
        return (actionHandler?.actions(for: backdrop, context: actionContext) ?? [])
            .first { $0.isNavigation && !$0.navigatesToSelf }
    }

    /// The air-schedule badge above the title, e.g. "New episodes Fridays".
    ///
    /// Styled to match the hero's glass action buttons so it reads as a property of
    /// the series rather than a line of metadata — but it is deliberately not a
    /// button: there is nothing to press.
    @ViewBuilder
    private func scheduleBadge(_ text: LocalizedStringResource) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Text(text)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background {
                if #available(tvOS 26.0, *) {
                    shape.fill(.regularMaterial)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .overlay {
                shape.stroke(Color.primary.opacity(0.16), lineWidth: 1)
            }
            .padding(.bottom, 6)
            .contentTransition(.opacity)
            .accessibilityLabel(text)
    }

    @ViewBuilder
    private func parentNavigationButton(action: MediaItemAction) -> some View {
        Button {
            performHeroAction(action)
        } label: {
            Image(systemName: action.systemImage)
                .font(.system(size: heroGlyphSize))
                .foregroundStyle(Color.primary)
                .frame(width: heroIconSize, height: heroIconSize)
        }
        .modifier(HeroActionButtonStyle(prominent: false, circular: true))
        .focused($heroActionRowFocus, equals: .parent)
        .accessibilityLabel(action.title)
    }

    /// The show's name rendered as a breadcrumb link above the episode title.
    /// Self-labelling in a way an icon button is not: it says both where you are
    /// and that you can leave, and it sits where the eye naturally starts rather
    /// than in a row of watch-state actions where navigation doesn't belong.
    @ViewBuilder
    private func seriesBreadcrumb(_ show: String, action: MediaItemAction) -> some View {
        HStack(spacing: 0) {
            Button {
                performHeroAction(action)
            } label: {
                HStack(spacing: 8) {
                    Text(show)
                        .lineLimit(1)
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 24, weight: .semibold))
                }
                .font(.system(size: 30, weight: .semibold))
            }
            .buttonStyle(.plain)
            .focused($heroActionRowFocus, equals: .parent)
            // tvOS gives entry focus to the topmost focusable element, and no
            // amount of `defaultFocus` (tried at `.automatic` and
            // `.userInitiated`, on both this view and the scroll column) beat it
            // — the page kept opening focused on "leave" instead of "play".
            // Removing the breadcrumb from the focus system until focus has
            // landed is what actually decides it. `.focusable(false)` rather
            // than `.disabled` so it never *looks* inert; and the gate opens on
            // the action row actually taking focus rather than on a timer, which
            // raced and let the breadcrumb win whenever the page was slow.
            .focusable(breadcrumbAcceptsFocus)
            .accessibilityLabel("Go to \(show)")
            .accessibilityHint(action.title)
            Spacer(minLength: 0)
        }
        // tvOS only enters a section that has geometry in the swipe's path, so a
        // short show name has nothing above the right-hand end of the action row
        // and "up" from those buttons finds nothing. Stretching the *section* the
        // full content width (the button itself stays leading, inside the HStack)
        // puts a focus target above every button — the same fix the action row
        // uses to catch "up" from a far-right season chip.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .onChange(of: heroActionRowFocus) { _, focus in
            // Any hero control taking focus means entry focus has resolved, so
            // the breadcrumb can safely join the focus system.
            if focus != nil { breadcrumbAcceptsFocus = true }
        }
    }

    /// Whether any visible item-action button should render — used to decide
    /// whether the action row appears even when there's no Play/Trailer/Version.
    private var hasHeroActionButtons: Bool {
        heroWatchlistAction != nil || heroWatchedAction != nil
            || heroParentNavigationAction != nil
            || showsMoreMenu
    }

    /// Whether the discovery request/status pill should render: a discovery title
    /// that is requestable, already requested, or downloading. An `.unavailable`
    /// discovery title (Seerr disconnected) or a `.play` one (already owned) shows
    /// no pill.
    private var showsRequestPill: Bool {
        guard isDiscoveryItem else { return false }
        switch requestCTA {
        case .request, .requested, .downloading: return true
        case .play, .unavailable: return false
        }
    }
    /// Routes a hero button through the shared action handler — the exact same
    /// path the context menu uses.
    ///
    /// Watched-state actions go to the play target, everything else to the
    /// editorial hero. On a series page resting on the show those are different
    /// items, and marking watched must follow what Play would run rather than the
    /// whole series.
    private func performHeroAction(_ action: MediaItemAction) {
        if action.isNavigation {
            if let navigator, let target = item.navigationTarget(for: action) {
                navigator(target)
            }
            return
        }
        let subject = (action == .markWatched || action == .markUnwatched)
            ? watchedActionItem
            : item
        actionHandler?.perform(action, on: subject, context: actionContext)
    }

    /// Resolution/HDR/audio badges shown after the external ratings in the
    /// wrapping facts row. The content-rating certificate is rendered separately
    /// beside the genres.
    private var featureBadges: [MediaBadge] {
        // When the user has picked a non-default version from the picker,
        // prefer that version's own resolution/HDR/audio badges so the hero
        // row reflects what Play will actually target (e.g. switching from a
        // 4K HDR Atmos remux to a 720p SDR WEB-DL flips Dolby Vision / HDR10
        // / 7.1 off and shows the 720p file's facts). Falls through to the
        // focused item's own tech badges, then to the series-derived fallback
        // for a series/season hero whose episode mediaInfo hasn't loaded.
        //
        // We ALSO use the selected version when there's only one but it carries
        // authoritative `sourceMetadata` (a synthesised cross-server version):
        // for a title merged across servers the loaded `item.mediaInfo` can be a
        // sparse/low-quality copy (e.g. a 720p SDR stereo file from whichever
        // server the page opened against) while the effective source's version
        // holds the real 4K HDR10/Atmos facts. Without this the hero rendered
        // the sparse item facts even though Play targeted the rich source.
        // Intrinsic single versions (no `sourceMetadata`) still defer to
        // `item.technicalBadges`, which is authoritative for a direct full fetch
        // and can be richer than the version's flattened fields.
        if let selected = versions.first(where: { $0.id == selectedVersionID }) ?? versions.first,
           versions.count > 1 || selected.sourceMetadata != nil {
            // Reflect ONLY the selected version's own facts. If it carries none of
            // its own (e.g. an SMB file whose header hasn't been probed yet), show
            // nothing rather than falling back to `item.technicalBadges` — that's
            // the merged/representative set borrowed from a DIFFERENT source or
            // version of this title (a Plex/Jellyfin copy), which mislabels the
            // selected file (e.g. a Dolby Vision file showing the 1080p SDR copy's
            // "SDR"). Better to show nothing than the wrong thing.
            return selected.technicalBadges
        }
        let ownTech = item.technicalBadges
        return ownTech.isEmpty ? fallbackTechnicalBadges : ownTech
    }

    /// The content-rating certificate badge (e.g. `TV-14`). When the focused
    /// item is an episode without its own certificate, it falls back to the
    /// backdrop item (the series), so a show's TV rating still shows while
    /// scrubbing episodes — matching Apple TV.
    private var heroRatingBadge: MediaBadge? {
        HeroContentPolicy.ratingBadge(
            focused: focusedPresentation,
            root: rootPresentation
        )
    }

    /// External ratings to show. Falls back to the backdrop item (the series)
    /// when the focused item (an episode) carries none of its own, so a show's
    /// rating stays visible while scrubbing episodes.
    private var heroRatings: [ExternalRating] {
        HeroContentPolicy.ratings(
            focused: focusedPresentation,
            root: rootPresentation
        )
    }

    /// True when `subtitle` is just the production year — the richer metadata
    /// line below already opens with the year, so we drop the duplicate.
    private func isYearOnlySubtitle(_ subtitle: String) -> Bool {   // l10n:content — media subtitle from the server
        guard let year = item.productionYear else { return false }
        return subtitle == String(year)
    }

    /// Top-billed cast names for the right-aligned "Starring …" line, joined in
    /// billing order (our proxy for "stars" — the provider returns cast top-billed
    /// first). Falls back to the backdrop item (the series) when the focused item
    /// (an episode) carries no cast of its own, so a show's stars stay shown while
    /// scrubbing episodes. `nil` when no cast is available.
    private var starringCastValues: [String] {
        guard !rootPresentation.isAnime,
              rootPresentation.kind == .movie
                || rootPresentation.kind == .series else {
            return []
        }
        return rootPresentation.starringNames
    }

    private var animeStudioValues: [String] {
        guard rootPresentation.isAnime,
              !rootPresentation.studios.isEmpty else {
            return []
        }
        return rootPresentation.studios
    }

    /// The film's director(s) for the right-aligned "Director …" line shown just
    /// below "Starring" on movie heroes. Reads crew from `people` (role kind
    /// `Director`) in provider order, capped so a rare multi-director credit stays
    /// on one line. Movies only — episodes/series direction varies per episode, so
    /// it isn't shown there. `nil` when no director is reported.
    private var directorValues: [String] {
        guard !rootPresentation.isAnime,
              rootPresentation.kind == .movie else {
            return []
        }
        return rootPresentation.directorNames
    }

    var body: some View {
        let _ = plozzTraceBodyChanges { Self._printChanges() }
        let hideText = spoilerSettings.shouldHideText(for: item)
        let heroHeight = Self.screenHeight * heroHeightFraction
        // When the hero fills the screen (a movie, with no children rail below to
        // provide separation) its content is pinned to the very bottom edge, which
        // on tvOS sits inside the unprotected overscan region — so the action row
        // ends up far closer to the bottom than the content is to the leading edge
        // (the leading edge is protected by the horizontal overscan safe area on
        // top of `heroLeadingPadding`). Mirror that leading distance on the bottom
        // so the buttons sit the same visible distance from the bottom as from the
        // left. A non-full-height hero (a show) has rows beneath it and keeps the
        // plain inter-section vertical spacing.
        let isFullScreenHero = heroHeightFraction >= 1.0
        let baseBottomInset = isFullScreenHero
            ? Self.horizontalSafeAreaInset + PlozzTheme.Metrics.heroLeadingPadding
            : PlozzTheme.Metrics.screenVerticalPadding
        let unshiftedBottomInset = baseBottomInset
            + (seriesRecedeModel == nil ? 0 : SeriesEpisodeBrowserLayout.heroContentBottomLift)
        // Nudge the whole hero content block (logo → subtitle/metadata → Starring
        // → overview → action row) DOWN by roughly one action-button height (~70pt)
        // plus ~20pt of breathing room, per design — done by trimming the bottom
        // inset. Floor at the overscan-safe inset so a full-screen (movie) hero,
        // whose content already sits near the bottom, never drops into the unsafe
        // overscan region; `min(unshifted, …)` keeps the floor from ever *raising*
        // the content on a shallow hero whose inset is already below the safe line.
        let heroContentDownShift: CGFloat = 90
        let bottomInset = max(
            unshiftedBottomInset - heroContentDownShift,
            min(unshiftedBottomInset, Self.horizontalSafeAreaInset)
        )
        // The leading-aligned content column. It is the ONLY thing that sizes the
        // hero, so the hero always reports the safe viewport width — never the
        // full panel — keeping its title/logo/Play on-screen and focusable.
        VStack(alignment: .leading, spacing: 12) {
            // The episode's still sits centred above its own details, the way
            // Apple's episode page does — the page's subject, shown once, rather
            // than a show backdrop that makes every episode look the same.
            //
            // The flexible height is what centres it: the text block below keeps
            // its natural size and its usual bottom-anchored position, so this
            // slot absorbs every remaining point between the top of the hero and
            // the top of the text, and centres the still within it.
            if presentsEpisodeStill {
                episodeStill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The hero logo is the *show's* branded title art — identical for
            // every episode — so it is never a spoiler and stays visible even
            // when an unwatched episode is focused (spoiler-hiding only masks the
            // episode's name and overview, handled below). Only the *text*
            // fallback respects masking, so a show with no logo still hides an
            // unwatched episode's title rather than leaking it.
            //
            // An episode page skips the wordmark entirely: it names the show in a
            // breadcrumb above the episode's own title instead.
            if let scheduleLine {
                scheduleBadge(scheduleLine)
            }
            if presentsEpisodeStill {
                titleText(hideText: hideText)
            } else {
                HeroLogoArtwork(
                    references: backdrop.artworkReferences(for: .logo),
                    asyncFallbackURL: tmdbLogoFallback,
                    backgroundSample: heroBackgroundSample,
                    // Cap the WIDTH as well as the height, matching the Home hero.
                    // With only a height cap a wide, short wordmark fits against an
                    // unbounded width and then floats inside the full 200pt frame,
                    // so the gap above and below it varied with each logo's aspect
                    // ratio. Bounding the width makes such a logo hit that limit
                    // first and shrink its own height to match, leaving no slack.
                    maxWidth: heroLogoWidth,
                    maxHeight: heroLogoHeight
                ) {
                    titleText(hideText: hideText)
                }
                // The frame is now exactly the artwork, so breathing room has to be
                // asked for rather than inherited from leftover frame slack — which
                // is what made it vary by logo. On top of the stack's own 12pt.
                .padding(.vertical, 16)
            }
            // The season/episode ("S{n} · E{m}") is now shown only in the Play
            // button, so it's omitted here for episodes to avoid a redundant line.
            // Non-episode subtitles (e.g. a movie's collection/parent title) still
            // show.
            //
            // The condition is hoisted OUT of the container rather than sitting
            // inside it: an empty view still takes a spacing gap on each side of a
            // VStack, so a title with no subtitle was paying 12pt for a line that
            // renders nothing — and the gap under the logo therefore changed with
            // whichever lines a given title happened to have.
            if let subtitle = item.subtitle,
               !isYearOnlySubtitle(subtitle),
               item.kind != .episode {
                Text(subtitle)
                    .font(.system(size: 26, weight: .medium))
                    .plozzForeground(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            let comps = HeroContentPolicy.detailFacts(
                focused: focusedPresentation
            )
            let genreParts = HeroContentPolicy.genres(
                focused: focusedPresentation,
                root: rootPresentation
            )
            // Split the facts line: genres ride the certificate line up top; the
            // year/runtime facts drop to the bottom row beside the ratings.
            let factParts = comps
            let showRatings = !heroRatings.isEmpty && !spoilerSettings.shouldHideRatings(for: item)

            // Line 1: content-rating certificate + genres. Same hoisting as the
            // subtitle above — an always-present container costs a spacing gap even
            // with nothing in it.
            if heroRatingBadge != nil || !genreParts.isEmpty {
                HStack(alignment: .center, spacing: 16) {
                    if let badge = heroRatingBadge {
                        MediaBadgeChip(badge: badge)
                    }
                    if !genreParts.isEmpty {
                        Text(genreParts.joined(separator: "  ·  "))
                            .font(.system(size: 23, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Description directly beneath the genres line.
            SpoilerSafeOverviewText(
                overview: HeroContentPolicy.detailDescription(
                    focused: focusedPresentation,
                    root: rootPresentation
                ),
                hidesSpoilers: hideText,
                mode: spoilerSettings.mode,
                lineCount: 3,
                maxWidth: 800,
                reservesSpace: false
            )
            // Bottom facts region just above the action buttons: year · runtime,
            // ratings, then capability badges (4K / Atmos / HDR …). One wrapping
            // layout owns every item so an unusually rich title can add a real
            // second line that reserves space instead of drawing behind the buttons.
            ZStack(alignment: .leading) {
                if !factParts.isEmpty || showRatings || !featureBadges.isEmpty {
                    DetailHeroFactsRow(
                        facts: factParts,
                        ratings: showRatings ? heroRatings : [],
                        featureBadges: featureBadges
                    )
                }
            }
            if isDiscoveryItem ? showsRequestPill : ((playTitle != nil && onPlay != nil) || onPlayTrailer != nil || hasHeroActionButtons) {
                HStack(spacing: 24) {
                    if isDiscoveryItem {
                        // A not-in-library discovery title offers only a request /
                        // status pill; every library-only affordance is suppressed.
                        requestPill()
                    } else {
                    if let playTitle, let onPlay {
                        playButton(title: playTitle, action: onPlay)
                    }
                    if let onPlayTrailer {
                        Button(action: onPlayTrailer) {
                            Label("Trailer", systemImage: "film.fill")
                        }
                        .modifier(HeroActionButtonStyle(prominent: false))
                        .focused($heroActionRowFocus, equals: .trailer)
                    }
                    if let heroWatchedAction {
                        watchedButton(action: heroWatchedAction)
                    }
                    if let heroWatchlistAction {
                        watchlistButton(action: heroWatchlistAction)
                    }
                    // The breadcrumb above the title carries this on an episode
                    // page; the icon button is the fallback for any other hero
                    // that gains a parent.
                    if !presentsEpisodeStill, let heroParentNavigationAction {
                        parentNavigationButton(action: heroParentNavigationAction)
                    }
                    if showsMoreMenu {
                        moreMenu()
                    }
                    }
                }
                .padding(.top, 8)
                // Stretch the focus section the full content width (buttons stay
                // leading-aligned) so pressing "up" from a season chip parked far
                // to the RIGHT reliably lands on the action row. tvOS only enters a
                // section if some part of it sits in the swipe's path: a
                // leading-sized section has no geometry above a far-right chip, so
                // "up" from there found nothing and the user was trapped. The
                // earlier worry that a full-width row pans the page off the left
                // edge was really the over-wide full-bleed backdrop inflating the
                // layout width — now fixed by hosting the backdrop in a
                // `.background` (decoupled from layout). The buttons themselves
                // remain leading via the HStack's content, so widening only the
                // section's frame adds no over-wide *focusable* geometry.
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusScope(heroActionsScope)
                .focusSection()
                // Keep the whole action row pinned to the hero top: this row is
                // bottom-anchored in a hero that is full-screen-height for a
                // childless movie, so when focus lands on any button tvOS
                // auto-scrolls the page down to reveal it. Firing on every non-nil
                // change (not just row entry) corrects the drift for horizontal
                // moves *within* the row too, since tvOS re-nudges the scroll for
                // each newly-focused button.
                .onChange(of: heroActionRowFocus) { _, focus in
                    if focus != nil {
                        onHeroActionFocused?()
                    } else {
                        onHeroActionBlurred?()
                    }
                }
            }
        }
        .padding(.top, PlozzTheme.Metrics.screenVerticalPadding)
        .padding(.bottom, bottomInset)
        .padding(.trailing, PlozzTheme.Metrics.screenPadding)
        .padding(.leading, PlozzTheme.Metrics.heroLeadingPadding)
        // Occupy the backdrop's height and pin the content to the bottom-leading
        // corner — exactly what the old `ZStack(alignment: .bottomLeading)` did,
        // but measured at the *safe* viewport width (`.infinity` reports the
        // proposed width), never the full 1920pt panel.
        .frame(maxWidth: .infinity, minHeight: heroHeight, alignment: .bottomLeading)
        .frame(
            height: seriesRecedeModel == nil ? nil : heroHeight,
            alignment: .bottomLeading
        )
        .modifier(SeriesHeroContentLiftModifier(model: seriesRecedeModel))
        // The full-bleed backdrop lives in a `.background`, which by definition is
        // sized to the host and does NOT contribute to the host's measured size.
        // That is the fix: previously the backdrop was a ZStack *sibling* whose
        // `.ignoresSafeArea(.horizontal)` inflated the ZStack — and therefore the
        // whole scroll column — to the full panel width (~1920). A vertical
        // ScrollView then centred that over-wide content, throwing the
        // leading-aligned title/Play off the left edge while the centred image
        // still looked correct. As a background, the image bleeds edge-to-edge
        // purely visually and the content column stays at the safe width.
        .background(alignment: .bottom) {
            // An episode page has no full-bleed backdrop: the themed page
            // background shows through, and the episode's own still is inset
            // opposite the text instead.
            if !presentsEpisodeStill {
                heroBackdrop()
                    // Re-key on the backdrop identity so a server switch (the only
                    // thing that changes the backdrop — episode focus deliberately
                    // keeps the show-level backdrop) cross-fades the old artwork out
                    // and the new one in instead of hard-cutting.
                    .id(backdrop.id)
                    .transition(.opacity)
            }
        }
        // A right-aligned "Starring …" line opposite the action buttons (mirrors
        // the Apple TV detail layout). Billing order is our proxy for the stars;
        // the full cast still lives in the Cast row below. Shares the buttons'
        // `bottomInset` so the two sit on the same baseline and follows the same
        // compositor lift as the left-side hero content.
        .overlay(alignment: .bottomTrailing) {
            if !presentsEpisodeStill,
               !starringCastValues.isEmpty
                || !directorValues.isEmpty
                || !animeStudioValues.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if !animeStudioValues.isEmpty {
                        DetailHeroCreditLine(
                            label: "Studio",
                            values: animeStudioValues
                        )
                    } else if !starringCastValues.isEmpty {
                        DetailHeroCreditLine(
                            label: "Starring",
                            values: starringCastValues
                        )
                    }
                    if !directorValues.isEmpty {
                        DetailHeroCreditLine(
                            label: "Director",
                            values: directorValues
                        )
                    }
                    if let sourceMaterial = rootPresentation.sourceMaterial {
                        DetailHeroCreditLine(
                            label: "Based on",
                            values: [sourceMaterial]
                        )
                    }
                }
                .font(.system(size: 24, weight: .semibold))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 440, alignment: .trailing)
                .shadow(color: .black.opacity(colorScheme == .light ? 0.22 : 0.55), radius: 5, y: 1)
                .padding(.trailing, PlozzTheme.Metrics.screenPadding)
                .padding(.bottom, bottomInset)
                .contentTransition(.opacity)
                .allowsHitTesting(false)
                .modifier(SeriesHeroContentLiftModifier(model: seriesRecedeModel))
            }
        }
        .contextMenu {
            heroContextMenu
        }
        // Normal detail opens fade the whole hero in. A live Home-trailer handoff
        // must be fully opaque on its very first frame; fading the inherited video
        // from zero exposes the navigation/container background as a dark flash.
        .opacity(isContinuingHeroTrailer || heroVisible ? 1 : 0)
        .onAppear {
            guard !heroVisible else { return }
            if reduceMotion || isContinuingHeroTrailer {
                heroVisible = true
            } else {
                withAnimation(.easeInOut(duration: 0.35)) { heroVisible = true }
            }
        }
        // Cross-fade the hero text as the focused context changes, while the
        // backdrop swaps underneath it.
        .animation(.easeInOut(duration: 0.2), value: item.id)
        // Cross-fade the backdrop when the active server changes.
        .animation(.easeInOut(duration: 0.3), value: backdrop.id)
        // After an in-place cross-server switch the hero rebuilds but the "…"
        // menu is still present; keep focus on it instead of letting the focus
        // engine fall back to Play. Gated on `userInitiatedSourceSwitch` so it
        // fires ONLY for a real user switch — never when late cross-server
        // discovery first populates the menu (which would steal focus from Play
        // on arrival, the bug seen on movies and series-from-search).
        .onChange(of: selectedSourceAccountID) { _, _ in
            guard userInitiatedSourceSwitch else { return }
            userInitiatedSourceSwitch = false
            if showsMoreMenu { heroActionRowFocus = .more }
        }

    }

    private var isContinuingHeroTrailer: Bool {
        let heroItem = backdropItem ?? item
        return heroBackground.settings.detailMode == .trailer
            && heroTrailerController.isShowing(heroItem.id)
            && heroTrailerController.isPlaying
    }

    /// The episode's own 16:9 still, inset opposite the text on an episode page.
    /// Uses the same artwork chain and spoiler policy as the episode cards, so an
    /// unwatched episode's frame is blurred here exactly as it is in a rail.
    @ViewBuilder
    private func episodeStill() -> some View {
        let width = Self.screenWidth * 0.40
        FallbackAsyncImage(
            references: item.artworkReferences(for: .episodeThumbnail),
            variant: .landscapeCard,
            asyncFallbackURL: episodeStillFallback
        ) {
            MediaArtworkPlaceholder()
        }
        .blur(radius: spoilerSettings.shouldHideThumbnail(for: item) ? 28 : 0)
        .frame(width: width, height: width * 9 / 16)
        .clipShape(
            RoundedRectangle(
                cornerRadius: PlozzMetrics.standard.landscapeCardCornerRadius,
                style: .continuous
            )
        )
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        .id(item.id)
        .transition(.opacity)
        .accessibilityHidden(true)
    }

    /// Resolves a still from the external artwork router when the server has none.
    private var episodeStillFallback: (@Sendable () async -> URL?)? {
        let snapshot = item
        return { await ArtworkRouter.shared.artworkURL(.thumbnail, for: snapshot) }
    }

    /// The full-bleed backdrop image with its legibility scrim and bottom
    /// dissolve mask. Rendered as a `.background` of the hero content so it can
    /// ignore the horizontal/top overscan safe area and span the screen edge to
    /// edge *without* inflating the hero's (and the scroll column's) layout width.
    @ViewBuilder
    private func heroBackdrop() -> some View {
        // The shared `HeroBackdropLayer` (CoreUI) owns the exact scrim + dissolve
        // + full-bleed treatment, so the detail hero and the Home hero carousel
        // render an identical backdrop. Hero artwork is never spoiler-blurred;
        // episode spoiler masking remains limited to episode text and cards.
        SeriesDetailHeroBackdrop(
            references: backdrop.artworkReferences(for: .detailBackdrop),
            asyncFallbackURL: tmdbBackdropFallback,
            width: Self.screenWidth,
            height: Self.screenHeight * heroHeightFraction,
            scrimTone: scrimTone,
            recedeModel: seriesRecedeModel,
            trailerController: heroTrailerController,
            showsTrailer: heroBackground.settings.detailMode == .trailer
                && heroTrailerController.isShowing((backdropItem ?? item).id)
                && heroTrailerController.isPlaying
        )
    }

    /// The hero Play button. Extracted so the optional initial-focus binding can
    /// be applied to it conditionally (a `nil` binding leaves default focus
    /// behaviour untouched). When the resume target is partially watched the
    /// label becomes `▶  [progress bar]  … left`, keeping the button's normal
    /// height; otherwise it's the plain `▶  Play/Resume`.
    @ViewBuilder
    private func playButton(title: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        // The plain "▶ Play" form must occupy the SAME width as the wider resume
        // form ("▶ [bar] … left") so that flipping between them — e.g. when the
        // user marks the item Watched, which clears the live resume text — never
        // resizes Play or shifts the action row beside it. We size to a *latched*
        // resume text (`reservedResumeText`) that survives the watched transition,
        // rather than a fixed over-wide frame. With no resume target ever (a plain
        // unwatched title) there's nothing to reserve and Play takes its natural,
        // tight default width.
        let liveResumeText = resumeText
        let sizingText = reservedResumeText ?? liveResumeText
        let button = Button {
            heroTrailerController.stop()
            action()
        } label: {
            ZStack {
                if let sizingText {
                    playResumeSizer(remaining: sizingText).hidden()
                }
                PlayResumeButtonLabel(
                    title: title,
                    progress: playProgress,
                    remainingText: playRemainingText,
                    seasonEpisodeText: playSeasonEpisodeText,
                    onLight: playButtonHasFocus || colorScheme == .light,
                    barHeight: 10
                )
            }
        }
        .modifier(HeroActionButtonStyle(prominent: true))
        .focused($playButtonHasFocus)
        .focused($heroActionRowFocus, equals: .play)
        .onChange(of: liveResumeText) { _, new in
            if let new { reservedResumeText = new }
        }
        .onAppear {
            if let liveResumeText { reservedResumeText = liveResumeText }
        }

        if let playButtonFocus {
            button
                .focused(playButtonFocus, equals: true)
                .prefersDefaultFocus(true, in: heroActionsScope)
        } else {
            button
                .prefersDefaultFocus(true, in: heroActionsScope)
        }
    }

    /// The single request/status pill shown in place of the library action row for
    /// a not-in-library discovery (Seerr) title. Mirrors the Home hero's CTA:
    /// a prominent, actionable **Request** button when the title is requestable, or
    /// an informational **Requested** / **Downloading n%** status pill for a request
    /// that's already in flight. Whichever pill renders is the action row's
    /// preferred default focus so entering the row lands on it.
    @ViewBuilder
    private func requestPill() -> some View {
        if item.kind == .series {
            seriesRequestPill()
        } else {
            titleRequestPill()
        }
    }

    @ViewBuilder
    private func seriesRequestPill() -> some View {
        if let seasonRequestAvailability, seasonRequestAvailability.hasSeasonRequestContent {
            let hasRequestable = !seasonRequestAvailability.requestableSeasonNumbers.isEmpty
            let label = isRequestingSeasons
                ? "Requesting…"
                : (hasRequestable ? "Request Seasons" : "Season Requests")
            SeasonRequestMenu(
                availability: seasonRequestAvailability,
                requestAllTitle: "Request All Seasons",
                onRequest: { onRequestSeasons?($0) }
            ) {
                Label(label, systemImage: "plus.circle")
            }
            .menuStyle(.button)
            .modifier(HeroActionButtonStyle(prominent: hasRequestable))
            .prefersDefaultFocus(true, in: heroActionsScope)
            .focused($heroActionRowFocus, equals: .request)
            .disabled(onRequestSeasons == nil || isRequestingSeasons)
            .accessibilityLabel(requestActingName.map { "\(label) as \($0)" } ?? label)
        } else if seasonRequestAvailabilityFailed {
            Button { onRetrySeasonRequestAvailability?() } label: {
                Label("Retry Seasons", systemImage: "arrow.clockwise")
            }
            .modifier(HeroActionButtonStyle(prominent: true))
            .prefersDefaultFocus(true, in: heroActionsScope)
            .focused($heroActionRowFocus, equals: .request)
            .disabled(onRetrySeasonRequestAvailability == nil)
            .accessibilityLabel("Retry loading seasons")
        } else {
            let label = SeasonRequestHeroPresentation.inactiveTitle(
                availabilityLoaded: seasonRequestAvailability != nil,
                resolved: seasonRequestAvailabilityResolved
            )
            Button {} label: {
                Label(label, systemImage: seasonRequestAvailabilityResolved ? "exclamationmark.circle" : "clock")
            }
            .modifier(HeroActionButtonStyle(prominent: false))
            .prefersDefaultFocus(true, in: heroActionsScope)
            .focused($heroActionRowFocus, equals: .request)
            .accessibilityLabel(label)
        }
    }

    @ViewBuilder
    private func titleRequestPill() -> some View {
        switch requestCTA {
        case .request:
            let label = requestActingName.map { "Request as \($0)" } ?? "Request"
            Button { onRequest?() } label: {
                Label(label, systemImage: "plus.circle")
            }
            .modifier(HeroActionButtonStyle(prominent: true))
            .prefersDefaultFocus(true, in: heroActionsScope)
            .focused($heroActionRowFocus, equals: .request)
            .accessibilityLabel(label)
        case let .downloading(progress):
            let percent = Int((progress * 100).rounded())
            Button {} label: {
                HStack(spacing: 16) {
                    Image(systemName: "arrow.down.circle")
                    ResumeProgressCapsule(progress: progress, onLight: requestPillHasFocus || colorScheme == .light, floorsMinimumFill: false)
                    Text("\(percent)%").lineLimit(1)
                }
            }
            .modifier(HeroActionButtonStyle(prominent: false))
            .focused($requestPillHasFocus)
            .prefersDefaultFocus(true, in: heroActionsScope)
            .focused($heroActionRowFocus, equals: .request)
            .accessibilityLabel("Downloading \(percent) percent")
        case .requested:
            Button {} label: {
                Label("Requested", systemImage: "clock")
            }
            .modifier(HeroActionButtonStyle(prominent: false))
            .prefersDefaultFocus(true, in: heroActionsScope)
            .focused($heroActionRowFocus, equals: .request)
            .accessibilityLabel("Requested")
        case .play, .unavailable:
            EmptyView()
        }
    }

    /// The live resume trailing text — `S{n}, E{m} • {remaining}` (or just the
    /// remaining time for a movie) — when the item has a real partial position
    /// (0 < progress < 1), else `nil`. Used to reserve the Play button's width.
    private var resumeText: String? {
        guard let playRemainingText, let playProgress, playProgress > 0, playProgress < 1 else { return nil }
        return playSeasonEpisodeText.map { "\($0) • \(playRemainingText)" } ?? playRemainingText
    }

    /// An invisible copy of the resume form used purely to reserve the Play
    /// button's width. The progress capsule is a fixed width, so any progress
    /// value sizes identically; only the variable trailing text matters.
    private func playResumeSizer(remaining: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "play.fill")
            ResumeProgressCapsule(progress: 1, onLight: playButtonHasFocus || colorScheme == .light, width: 75)
            Text(remaining)
                .lineLimit(1)
        }
    }

    /// The distinct servers offered in the server picker, primary first, one row
    /// per account (two accounts on the same backend stay distinct). A title held
    /// on a single server yields a single entry, which hides the picker.
    private var serverChoices: [MediaSourceRef] {
        var seen = Set<String>()
        var result: [MediaSourceRef] = []
        for source in sources where seen.insert(source.accountID).inserted {
            result.append(source)
        }
        return result
    }

    /// Whether the trailing "…" menu has anything to offer: more than one server
    /// hosting the title, or more than one playable version on the active server.
    private var showsMoreMenu: Bool {
        (serverChoices.count > 1 && onSelectSource != nil)
            || (versions.count > 1 && onSelectVersion != nil)
    }

    /// A single subtle trailing "…" menu that folds BOTH the cross-server picker
    /// and the version picker into one place, so a multi-server / multi-version
    /// title shows one unobtrusive ellipsis button instead of two prominent
    /// pickers crowding the action row. The menu groups choices under a "Server"
    /// section (which server hosts this title — primary first, one row per
    /// account, active one checkmarked; picking one retargets Play and repopulates
    /// the version list with that server's files) and a "Version" section (the
    /// active server's factual edition/quality labels, active one checkmarked).
    /// Either section is omitted
    /// when it has only one option.
    ///
    /// The menu is extracted into a dedicated `Equatable` child view so that
    /// re-renders of the surrounding hero (e.g. from `@FocusState` toggles when
    /// the picker takes focus, from async cross-server discovery completing
    /// after the page has settled, or from optimistic watched-state updates)
    /// don't tear down the already-presented native Menu. Without this, every
    /// hero re-render rebuilds the Menu's content closure, which can produce a
    /// visible single-frame flash right after the user opens it.
    @ViewBuilder
    private func moreMenu() -> some View {
        PlaybackSourceMenuButton(
            sources: serverChoices,
            selectedSourceID: selectedSourceAccountID,
            offlineSourceAccountIDs: offlineSourceAccountIDs,
            versions: versions,
            selectedVersionID: selectedVersionID,
            onSelectSource: { accountID in
                userInitiatedSourceSwitch = true
                onSelectSource?(accountID)
            },
            onSelectVersion: { versionID in
                onSelectVersion?(versionID)
            },
            onDismiss: {
                heroActionRowFocus = .more
            }
        ) {
            Image(systemName: "ellipsis")
                .font(.system(size: heroGlyphSize))
                .foregroundStyle(Color.primary)
                .frame(width: heroIconSize, height: heroIconSize)
        }
        .modifier(HeroActionButtonStyle(prominent: false, circular: true))
        .focused($heroActionRowFocus, equals: .more)
        .accessibilityLabel("More actions")
    }

    @ViewBuilder
    private var heroContextMenu: some View {
        ForEach(heroContextMenuActions) { action in
            Button(action.title, systemImage: action.systemImage) {
                performHeroMenuAction(action)
            }
        }
        if serverChoices.count > 1, let onSelectSource {
            let currentServer = serverChoices.first {
                $0.accountID == selectedSourceAccountID
            } ?? serverChoices.first
            if let currentServer {
                Picker(
                    selection: Binding(
                        get: { currentServer.accountID },
                        set: { accountID in
                            userInitiatedSourceSwitch = true
                            onSelectSource(accountID)
                        }
                    )
                ) {
                    ForEach(serverChoices) { source in
                        Text(source.displayName)
                            .tag(source.accountID)
                    }
                } label: {
                    Label(currentServer.displayName, systemImage: "server.rack")
                }
                .pickerStyle(.menu)
            }
        }
        if versions.count > 1, let onSelectVersion {
            let currentVersion = versions.first {
                $0.id == selectedVersionID
            } ?? versions.first
            if let currentVersion {
                Picker(
                    selection: Binding(
                        get: { currentVersion.id },
                        set: onSelectVersion
                    )
                ) {
                    ForEach(versions.sortedForPicker()) { version in
                        versionTitleText(version.displayLabel)
                            .tag(version.id)
                    }
                } label: {
                    Label {
                        versionTitleText(currentVersion.displayLabel)
                    } icon: {
                        Image(systemName: "film.stack")
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private func performHeroMenuAction(_ action: MediaItemAction) {
        guard !action.isNavigation else {
            performHeroAction(action)
            return
        }
        let target: MediaItem
        if action == .addToWatchlist || action == .removeFromWatchlist {
            target = backdrop
        } else {
            target = item
        }
        actionHandler?.perform(action, on: target, context: actionContext)
    }

    /// Visible Watchlist toggle, shown when the resolving provider conforms to
    /// `WatchlistProviding`. A filled bookmark + "Watchlisted" reflects current
    /// membership; an outline bookmark + "Watchlist" prompts adding. Tapping
    /// routes through the shared handler (optimistic update + cross-provider
    /// fan-out), so the icon flips the instant the mutation broadcasts back.
    @ViewBuilder
    private func watchlistButton(action: MediaItemAction) -> some View {
        Button { performHeroAction(action) } label: {
            Image(systemName: item.isFavorite ? "bookmark.fill" : "bookmark")
                .font(.system(size: heroGlyphSize))
                .foregroundStyle(item.isFavorite ? Color.accentColor : Color.primary)
                .contentTransition(.opacity)
                .symbolEffect(.bounce, value: item.isFavorite)
                .frame(width: heroIconSize, height: heroIconSize)
        }
        .modifier(HeroActionButtonStyle(prominent: false, circular: true))
        .animation(.easeInOut(duration: 0.2), value: item.isFavorite)
        .focused($heroActionRowFocus, equals: .watchlist)
        .accessibilityLabel(action.title)
        .accessibilityValue(item.isFavorite ? "On your watchlist" : "Not on your watchlist")
    }

    /// Visible watched-state toggle, shown when the provider can mutate it.
    ///
    /// Reflects and mutates the **play target**, so its glyph always describes the
    /// same thing the Play button beside it would run. On a series page resting on
    /// the show these differ, and reading `item` here would show the series'
    /// watched state above a button that marks one episode. Unwatched shows a neutral `eye`; marking
    /// watched first pops in a brand-blue filled circle (the same watched colour as
    /// the episode cards), then strokes a white checkmark *onto* it — drawn from the
    /// left point, down to the bottom vertex, up to the top-right — via an animated
    /// path so only the glyph animates, not the button.
    @ViewBuilder
    private func watchedButton(action: MediaItemAction) -> some View {
        Button { performHeroAction(action) } label: {
            ZStack {
                Image(systemName: "eye")
                    .font(.system(size: heroGlyphSize))
                    .foregroundStyle(Color.primary)
                    .opacity(watchedActionItem.isPlayed ? 0 : 1)
                    .scaleEffect(watchedActionItem.isPlayed ? 0.4 : 1)

                ZStack {
                    Circle()
                        .fill(ThemePalette.brandBlue)
                    // The check's draw-on is a direct function of `watchedActionItem.isPlayed`
                    // and carries its OWN animation keyed to that same value. This
                    // is deliberate: the surrounding `.animation(value:)` on the
                    // frame installs a *nil* animation on this whole subtree for any
                    // transaction where `isPlayed` didn't change, which silently
                    // squashed every previous draw-on (it ran in a separate, deferred
                    // transaction). Keeping the draw in the one transaction where
                    // `isPlayed` actually flips — and giving it a short delay so the
                    // circle pops first — makes it reliably animate on-device.
                    CheckmarkShape(progress: watchedActionItem.isPlayed ? 1 : 0)
                        .stroke(Color.white,
                                style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                        .padding(heroIconSize * 0.20)
                        .animation(.easeOut(duration: 0.32).delay(0.24), value: watchedActionItem.isPlayed)
                }
                .opacity(watchedActionItem.isPlayed ? 1 : 0)
                .scaleEffect(watchedActionItem.isPlayed ? 1 : 0.4)
            }
            .frame(width: heroIconSize, height: heroIconSize)
            .animation(.easeOut(duration: 0.18), value: watchedActionItem.isPlayed)
        }
        .modifier(HeroActionButtonStyle(prominent: false, circular: true))
        .focused($heroActionRowFocus, equals: .watched)
        .accessibilityLabel(action.title)
        .accessibilityValue(watchedActionItem.isPlayed ? "Watched" : "Not watched")
    }

    /// Visible Refresh Metadata button, shown when the provider conforms to
    /// `MetadataRefreshing`. The server task is fire-and-forget, so the icon walks
    /// through a small animated state machine for feedback: a real spinning
    /// progress indicator while "refreshing", then a green success check,
    /// then back to the refresh glyph — each state scaling/fading in and out.
    @ViewBuilder
    private func refreshButton() -> some View {
        Button {
            guard refreshPhase == .idle else { return }
            performHeroAction(.refreshMetadata)
            setRefreshPhase(.refreshing)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                setRefreshPhase(.success)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                    setRefreshPhase(.idle)
                }
            }
        } label: {
            refreshIcon
        }
        .modifier(HeroActionButtonStyle(prominent: false, circular: true))
        .focused($refreshButtonHasFocus)
        .focused($heroActionRowFocus, equals: .refresh)
        .accessibilityLabel(MediaItemAction.refreshMetadata.title)
    }

    /// Animates the refresh state transition.
    private func setRefreshPhase(_ phase: RefreshPhase) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
            refreshPhase = phase
        }
    }

    /// The single glyph shown for the current `refreshPhase`. Keyed by phase so a
    /// change removes the old glyph (transition out) and inserts the new one
    /// (transition in); the refreshing phase shows a real circular spinner.
    @ViewBuilder
    private var refreshIcon: some View {
        Group {
            switch refreshPhase {
            case .idle:
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: heroGlyphSize))
            case .refreshing:
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.primary)
                    .scaleEffect(0.9)
            case .success:
                Image(systemName: "checkmark")
                    .font(.system(size: heroGlyphSize))
                    .foregroundStyle(refreshButtonHasFocus
                        ? Color(red: 0.0, green: 0.4, blue: 0.07)
                        : .green)
            }
        }
        .id(refreshPhase)
        .transition(.scale(scale: 0.4).combined(with: .opacity))
        .frame(width: heroIconSize, height: heroIconSize)
    }

    /// The plain text title, used both under spoilers and as the fallback when no
    /// logo art can be resolved. Width is capped (and the text wraps/scales) so a
    /// very long title can never render as a single line wider than the screen —
    /// which would blow the hero's content past the viewport and shove the whole
    /// page (title + focusable buttons) off the left edge.
    private func titleText(hideText: Bool) -> some View {
        // `normalizedTitle` resolves an episode to its *show's* name, which is
        // right when a series hero fronts a focused episode — but wrong when the
        // episode is the page's own subject, where the breadcrumb already names
        // the show and the headline must be the episode.
        let resolvedTitle = seriesContextTitle == nil
            ? HeroPresentation.normalizedTitle(for: item)
            : item.title
        let title: Text
        if let override = titleFallbackOverride {
            title = Text(verbatim: override)
        } else if hideText {
            title = Text(spoilerSettings.maskedTitle(for: item))
        } else {
            title = Text(verbatim: resolvedTitle)
        }
        return VStack(alignment: .leading, spacing: 4) {
            // The show's name above the episode's, quiet and small — the episode
            // is the subject of this page, the series is the context it sits in.
            // Only when the episode IS the page: on a series page the hero already
            // carries the show's logo, so repeating the name would be noise.
            if let show = seriesContextTitle {
                if let action = heroParentNavigationAction {
                    seriesBreadcrumb(show, action: action)
                } else {
                    Text(show)
                        .font(.system(size: 30, weight: .semibold))
                        .plozzForeground(.secondary)
                        .lineLimit(1)
                }
            }
            title
                .font(.system(size: 64, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 1200, alignment: .leading)
                .contentTransition(.opacity)
        }
    }

    /// Renders a `MediaVersion` title: the joined technical facts (or provider
    /// name) verbatim when known, otherwise our own generic "Version" copy —
    /// kept as a real resource here rather than baked into a `String` so it
    /// translates like everything else.
    private func versionTitleText(_ displayLabel: String?) -> Text {
        if let displayLabel {
            return Text(verbatim: displayLabel)
        }
        return Text("Version", comment: "Generic label for a playback version/source with no distinguishing facts (resolution, edition, etc.) known.")
    }

    /// The owning show's name, shown above the title when this page's subject is
    /// an episode in its own right. `nil` on a series page, whose hero already
    /// shows the show's logo — and where `titleFallbackOverride` pins the title to
    /// the series anyway.
    private var seriesContextTitle: String? {
        guard titleFallbackOverride == nil, item.kind == .episode else { return nil }
        return item.parentTitle
    }

    /// Full screen height, the basis for the backdrop's height (scaled by
    /// `heroHeightFraction`). Falls back to a 1080p constant where UIKit isn't
    /// available (non-Apple toolchains/tests).
    private static var screenHeight: CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.bounds.height
        #else
        return 1080
        #endif
    }

    /// Full screen width, the basis for the inset episode still. Same fallback
    /// rationale as `screenHeight`.
    private static var screenWidth: CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.bounds.width
        #else
        return 1920
        #endif
    }

    /// The leading (horizontal) overscan safe-area inset for the current screen.
    /// On tvOS the title-safe overscan margin is wider horizontally than the hero
    /// content's own `heroLeadingPadding`, so the content sits this much further
    /// from the *physical* left edge. The full-screen movie hero mirrors this on
    /// its bottom inset so the action row is the same visible distance from the
    /// bottom as from the left. Read live so it stays correct across devices /
    /// future overscan changes; falls back to the standard 1080p margin where
    /// UIKit (or a key window) isn't available.
    private static var horizontalSafeAreaInset: CGFloat {
        #if canImport(UIKit)
        let inset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.left
        return inset ?? 90
        #else
        return 90
        #endif
    }

    /// Last-resort backdrop art for the hero: look the show/movie up on TMDb and
    /// use a wide fanart image. Many anime (via Shoko/AniDB) ship no backdrop, so
    /// this fills the otherwise-empty hero. Uses the *backdrop* item (the series,
    /// when pinned) and its TMDb id when that id refers to the show itself; for an
    /// episode/season backdrop it queries by series title. Inert without a token.
    private var tmdbBackdropFallback: (@Sendable () async -> URL?)? {
        let source = backdrop
        switch source.kind {
        case .folder, .collection, .unknown:
            return nil
        default:
            break
        }
        // art → TMDb hero → the item's own poster. Some titles (e.g. a Plex movie
        // with a poster but no fanart/`art`) carry no landscape backdrop anywhere,
        // so fall back to the poster rather than leaving the hero blank — matching
        // the resolution order documented on `heroBackgroundSample`. Only reached
        // when the server backdrop URLs fail, so titles with real backdrop art are
        // unaffected.
        return {
            if let hero = await ArtworkRouter.shared.artworkURL(.hero, for: source) { return hero }
            return source.posterURL
        }
    }

    /// Last-resort title art for the hero: look the show/movie up on TMDb and use
    /// its logo. TV uses the *series* title (never an episode name); inert when no
    /// TMDb token is configured.
    private var tmdbLogoFallback: (@Sendable () async -> URL?)? {
        let source = backdrop
        switch source.kind {
        case .folder, .collection, .unknown:
            return nil
        default:
            break
        }
        return {
            await ArtworkRouter.shared.artworkURL(.logo, for: source)
        }
    }

    /// Effective colour of the hero artwork behind the logo, used to decide
    /// whether the logo needs a legibility halo. Mirrors the backdrop resolution
    /// order (`heroBackdropURL`/`backdropURL` → TMDb hero → poster placeholder) so
    /// it measures the same image the user actually sees. Keyless/on-device; nil
    /// when no image can be sampled, in which case the halo stays on to be safe.
    private var heroBackgroundSample: (@Sendable () async -> HeroBackgroundSample?)? {
        #if canImport(UIKit)
        let urls = [backdrop.heroBackdropURL, backdrop.backdropURL].compactMap { $0 }
        let source = backdrop
        return {
            if let sample = await HeroBackgroundSampler.sample(urls: urls) { return sample }
            if let tmdb = await ArtworkRouter.shared.artworkURL(.hero, for: source),
               let sample = await HeroBackgroundSampler.sample(urls: [tmdb]) { return sample }
            if let poster = source.posterURL,
               let sample = await HeroBackgroundSampler.sample(urls: [poster]) { return sample }
            return nil
        }
        #else
        return nil
        #endif
    }
}

/// The checkmark glyph used by the watched toggle. `progress` (0...1) is the
/// shape's `animatableData`, and the path is built up to that fraction of its
/// *total length* — left point ➝ bottom vertex ➝ top-right — so animating
/// `progress` strokes the check on at a uniform speed. Proportions are inset and
/// balanced so the glyph stands tall without warping into the corners.
private struct CheckmarkShape: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Nothing drawn yet: return an *empty* path so the round line cap doesn't
        // render a dot at the start point while the check is still hidden/delayed.
        guard progress > 0 else { return path }

        let w = rect.width, h = rect.height
        let start = CGPoint(x: w * 0.26, y: h * 0.52)
        let mid   = CGPoint(x: w * 0.44, y: h * 0.70)
        let end   = CGPoint(x: w * 0.74, y: h * 0.24)

        let firstLen = hypot(mid.x - start.x, mid.y - start.y)
        let secondLen = hypot(end.x - mid.x, end.y - mid.y)
        let total = firstLen + secondLen
        let drawn = min(1, progress) * total

        path.move(to: start)
        if drawn <= firstLen {
            let t = firstLen == 0 ? 0 : drawn / firstLen
            path.addLine(to: CGPoint(x: start.x + t * (mid.x - start.x),
                                     y: start.y + t * (mid.y - start.y)))
        } else {
            path.addLine(to: mid)
            let t = secondLen == 0 ? 0 : (drawn - firstLen) / secondLen
            path.addLine(to: CGPoint(x: mid.x + t * (end.x - mid.x),
                                     y: mid.y + t * (end.y - mid.y)))
        }
        return path
    }
}

private struct DetailHeroCreditLine: View {
    let label: LocalizedStringResource
    let values: [String]
    @Environment(\.themePalette) private var palette

    var body: some View {
        let capped = Array(values.prefix(3))
        return text(capped)
    }

    private func text(_ values: [String]) -> some View {
        (
            Text(label).foregroundStyle(palette.tertiaryText)
            + Text(verbatim: " ")
            + Text(verbatim: values.formatted())
                .foregroundStyle(palette.primaryText)
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DetailHeroFactsRow: View {
    let facts: [String]
    let ratings: [ExternalRating]
    let featureBadges: [MediaBadge]

    var body: some View {
        WrappingHStackLayout(
            alignment: .leading,
            spacing: 16,
            lineSpacing: 8
        ) {
            if !facts.isEmpty {
                Text(facts.joined(separator: "  ·  "))
                    .font(.system(size: 23, weight: .medium))
                    .plozzForeground(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .contentTransition(.opacity)
            }
            ForEach(ratings) { rating in
                RatingBadge(rating: rating)
            }
            ForEach(featureBadges) { badge in
                MediaBadgeChip(badge: badge)
            }
        }
        .frame(maxWidth: 1200, alignment: .leading)
    }
}

/// Mirrors Home's recede architecture: the real hero hierarchy remains alive and
/// focusable while a post-layout transform moves it, and a cross-fade — never a
/// translation off the screen edge — is what makes it go away. tvOS will not
/// focus an item whose rendered frame lies entirely outside the screen, so
/// lifting the action row above the top edge (as this did) silently killed UP
/// from the season bar. Opacity does *not* remove focusability (the season bar
/// relies on the same trick for DOWN), so the fade is the safe half of the
/// effect and the travel is purely the visible part of it.
/// Per-view memo for `HeroPresentation`, keyed by the identity of the item it
/// was built from.
///
/// Deliberately a plain reference type rather than `@Observable`: nothing should
/// re-render when the cache fills. It exists purely so repeated reads within one
/// body evaluation — and across re-renders of the same item — cost a dictionary
/// lookup instead of a rebuild.
///
/// Keyed on more than the id: the same item is mutated in place as watched state
/// and enriched badges arrive, and the hero must reflect that immediately.
private final class HeroPresentationCache {
    private struct Key: Hashable {
        let id: String
        let isPlayed: Bool
        let playedPercentage: Double?
        let badgeCount: Int
        let artworkCount: Int
    }

    private var entries: [Key: HeroPresentation] = [:]

    func presentation(for item: MediaItem) -> HeroPresentation {
        let key = Key(
            id: item.id,
            isPlayed: item.isPlayed,
            playedPercentage: item.playedPercentage,
            badgeCount: item.technicalBadges.count,
            artworkCount: item.artworkReferences(for: .logo).count
        )
        if let cached = entries[key] { return cached }
        let built = HeroPresentation(
            item: item,
            artworkStyle: .landscape,
            surface: .detail
        )
        // Bounded: browsing a long season would otherwise accumulate one entry
        // per episode passed. The hero only ever shows one item at a time, so a
        // small window is plenty.
        if entries.count > 8 { entries.removeAll(keepingCapacity: true) }
        entries[key] = built
        return built
    }
}

private struct SeriesHeroContentLiftModifier: ViewModifier {
    let model: SeriesHeroRecedeModel?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let receded = model?.isReceded == true
        // Render-only, deliberately. The hero action row's LAYOUT frame stays
        // parked above the season bar at all times, so tvOS can always reach it
        // with UP and never has to scroll the page to reveal it. What the viewer
        // sees is pure transform: dropped into the lower third for the resting
        // page, travelling back up to its parked position — and fading out —
        // once the browser takes over.
        //
        // No `.animation` here: the recede/restore call sites wrap the state
        // change in one `withAnimation`, and an explicit modifier would override
        // that ambient transaction, letting the hero travel at a different speed
        // from everything else.
        content
            .offset(y: heroOffset(receded: receded))
            // A MASK, not `.opacity`: UIKit will not focus a view whose alpha is
            // zero, and this content has to stay reachable with UP from the
            // season bar the entire time it is invisible. A mask hides the
            // rendering while the view's own alpha stays 1.
            //
            // The generous negative padding is load-bearing: a mask is sized to
            // the content, so a plain `Rectangle()` clipped whatever a focused
            // hero button drew outside that frame — its scale and focus halo —
            // and shaved a few pixels off Play's left edge.
            .mask {
                Rectangle()
                    .padding(-600)
                    .opacity(model == nil || !receded ? 1 : 0)
                    // Scoped to the mask, so only the fade is retimed — the
                    // content's travel still runs on the ambient clock with the
                    // rest of the transition.
                    .animation(
                        reduceMotion
                            ? nil
                            : (receded
                                ? SeriesHeroRevealTransition.heroContentFadeExit
                                : SeriesHeroRevealTransition.ambient),
                        value: receded
                    )
            }
    }

    private func heroOffset(receded: Bool) -> CGFloat {
        guard model != nil else { return 0 }
        if reduceMotion {
            return receded ? -SeriesEpisodeBrowserLayout.heroContentRecedeLift : 0
        }
        return receded
            ? -SeriesEpisodeBrowserLayout.heroContentRecedeLift
            : SeriesEpisodeBrowserLayout.heroContentRestDrop
    }
}

private struct SeriesDetailHeroBackdrop: View {
    let references: [ArtworkReference]
    let asyncFallbackURL: (@Sendable () async -> URL?)?
    let width: CGFloat
    let height: CGFloat
    let scrimTone: Color
    let recedeModel: SeriesHeroRecedeModel?
    let trailerController: HeroTrailerController
    let showsTrailer: Bool

    var body: some View {
        let receded = recedeModel?.isReceded == true
        HeroBackdropLayer(
            references: references,
            asyncFallbackURL: asyncFallbackURL,
            height: height,
            scrimTone: scrimTone,
            verticalOffset: 0,
            ignoresOverscan: false,
            stillImageOpacity: showsTrailer ? 0 : 1
        ) {
            if showsTrailer {
                ZStack {
                    if let handoffImage = trailerController.handoffImage {
                        Image(uiImage: handoffImage)
                            .resizable()
                            .scaledToFill()
                    }
                    HeroTrailerVideoLayer(
                        controller: trailerController,
                        role: .detail
                    )
                }
                .clipped()
                .transition(.opacity)
            }
        }
        // The detail ScrollView is proposed the tvOS title-safe width. Give its
        // purely-visual background the physical panel width explicitly instead of
        // using `ignoresSafeArea(.horizontal)`, which can feed a wider proposal
        // back through a freshly-pushed NavigationStack before the safe area
        // settles and temporarily center the whole page off-screen.
        .frame(width: width)
        // Match Home's slower parallax track, but transform the completed backdrop
        // layer so its mask/artwork do not re-render on every animation frame.
        .offset(y: receded ? -SeriesEpisodeBrowserLayout.heroBackdropRecedeLift : 0)
        .animation(.smooth(duration: 0.9), value: receded)
    }
}
#endif
