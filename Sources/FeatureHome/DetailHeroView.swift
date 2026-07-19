#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
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
    /// Optional series-only cosmetic recede state. The model is consumed by leaf
    /// modifiers so changing it never invalidates the parent page or episode rail.
    var seriesRecedeModel: SeriesHeroRecedeModel? = nil
    let spoilerSettings: SpoilerSettings
    /// Title for the Play/Resume button, or `nil` to omit the button entirely
    /// (e.g. a season with no resolved episodes yet).
    let playTitle: String?
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

    /// Whether the trailing "…" (server/version) menu holds focus. After a
    /// cross-server switch the page rebuilds the hero in place (same "…" menu is
    /// still present), but the focus engine can otherwise drop focus to the
    /// default Play button; re-asserting this on `selectedSourceAccountID` change
    /// keeps the user parked on the "…" menu where they just made the switch. It
    /// is *not* set on first appearance (only on change), so it never steals the
    /// initial focus that Play should have when the page opens.
    @FocusState private var moreMenuFocused: Bool

    /// Identifies each focusable control in the hero action row. A single
    /// `@FocusState` bound to this enum funnels every action button through one
    /// signal, so the parent can be told the instant focus lands on — or moves
    /// between — any of them. This exists purely to drive the "keep the row pinned
    /// to the hero top" correction (see ``onHeroActionFocused``); the per-button
    /// bool focus states above still own their local colour/behaviour tweaks.
    private enum HeroRowAction: Hashable {
        case play, trailer, watchlist, watched, refresh, more, request
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
    /// Drives the Refresh button's animated state machine: the refresh itself is
    /// a fire-and-forget server task, so this gives the user visible feedback —
    /// idle ➝ a spinning "refreshing" indicator ➝ a green success check ➝ back to
    /// idle, with each icon animating in and out.
    @State private var refreshPhase: RefreshPhase = .idle

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

    /// The item supplying the backdrop artwork (the pinned series, when set).
    private var backdrop: MediaItem { backdropItem ?? item }

    /// Tone of the hero legibility scrim: a dark wash in dark mode (so light
    /// content reads against the artwork) and a light wash in light mode (so dark
    /// content does). The scrim geometry is identical across modes — only this
    /// tone flips — so legibility stays consistent between appearances.
    private var scrimTone: Color { colorScheme == .dark ? .black : .white }

    private var heroLogoHeight: CGFloat { 200 }

    // MARK: - Visible item actions (discoverability)

    /// The capability-gated actions the installed handler offers for the focused
    /// `item`. Identical to what the context menu shows, so the visible buttons
    /// and the long-press menu can never drift apart.
    private var heroActions: [MediaItemAction] {
        actionHandler?.actions(for: item, context: actionContext) ?? []
    }

    /// The watchlist toggle for `item`, if its resolving provider conforms to
    /// `WatchlistProviding` (offered only for whole titles — movies/series).
    private var heroWatchlistAction: MediaItemAction? {
        heroActions.first { $0 == .addToWatchlist || $0 == .removeFromWatchlist }
    }

    /// The watched-state toggle for `item`, if its provider can mutate it. On a
    /// series page this lights up for the focused *episode* (the hero mirrors it),
    /// giving episodes a visible watched toggle without touching the rail.
    private var heroWatchedAction: MediaItemAction? {
        heroActions.first { $0 == .markWatched || $0 == .markUnwatched }
    }

    /// Whether to show the Refresh Metadata button (provider conforms to
    /// `MetadataRefreshing`).
    private var heroOffersRefresh: Bool { heroActions.contains(.refreshMetadata) }

    /// Whether any visible item-action button should render — used to decide
    /// whether the action row appears even when there's no Play/Trailer/Version.
    private var hasHeroActionButtons: Bool {
        heroWatchlistAction != nil || heroWatchedAction != nil || heroOffersRefresh
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

    /// Routes a hero button through the shared action handler with this hero's
    /// item + context — the exact same path the context menu uses.
    private func performHeroAction(_ action: MediaItemAction) {
        actionHandler?.perform(action, on: item, context: actionContext)
    }

    /// The capability badges shown above the ratings: resolution/HDR/audio. The
    /// content-rating certificate is rendered separately, inline with the
    /// year/runtime/genre metadata line.
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
        item.ratingBadge ?? backdrop.ratingBadge
    }

    /// External ratings to show. Falls back to the backdrop item (the series)
    /// when the focused item (an episode) carries none of its own, so a show's
    /// rating stays visible while scrubbing episodes.
    private var heroRatings: [ExternalRating] {
        item.ratings.isEmpty ? backdrop.ratings : item.ratings
    }

    /// True when `subtitle` is just the production year — the richer metadata
    /// line below already opens with the year, so we drop the duplicate.
    private func isYearOnlySubtitle(_ subtitle: String) -> Bool {
        guard let year = item.productionYear else { return false }
        return subtitle == String(year)
    }

    /// Top-billed cast names for the right-aligned "Starring …" line, joined in
    /// billing order (our proxy for "stars" — the provider returns cast top-billed
    /// first). Falls back to the backdrop item (the series) when the focused item
    /// (an episode) carries no cast of its own, so a show's stars stay shown while
    /// scrubbing episodes. `nil` when no cast is available.
    private var starringCastNames: String? {
        let cast = item.cast.isEmpty ? backdrop.cast : item.cast
        let names = cast.prefix(3).map(\.name)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// The film's director(s) for the right-aligned "Director …" line shown just
    /// below "Starring" on movie heroes. Reads crew from `people` (role kind
    /// `Director`) in provider order, capped so a rare multi-director credit stays
    /// on one line. Movies only — episodes/series direction varies per episode, so
    /// it isn't shown there. `nil` when no director is reported.
    private var directorNames: String? {
        guard item.kind == .movie else { return nil }
        let people = item.people.isEmpty ? backdrop.people : item.people
        let names = people
            .filter { $0.kind?.lowercased() == "director" }
            .prefix(2)
            .map(\.name)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    var body: some View {
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
            // The hero logo is the *show's* branded title art — identical for
            // every episode — so it is never a spoiler and stays visible even
            // when an unwatched episode is focused (spoiler-hiding only masks the
            // episode's name and overview, handled below). Only the *text*
            // fallback respects masking, so a show with no logo still hides an
            // unwatched episode's title rather than leaking it.
            HeroLogoArtwork(
                primaryURL: backdrop.logoURL,
                asyncFallbackURL: tmdbLogoFallback,
                backgroundSample: heroBackgroundSample,
                maxHeight: heroLogoHeight
            ) {
                titleText(hideText: hideText)
            }
            ZStack(alignment: .leading) {
                // The season/episode ("S{n} · E{m}") is now shown only in the Play
                // button, so it's omitted here for episodes to avoid a redundant
                // line. Non-episode subtitles (e.g. a movie's collection/parent
                // title) still show.
                if let subtitle = item.subtitle,
                   !isYearOnlySubtitle(subtitle),
                   item.kind != .episode {
                    Text(subtitle)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            let comps = item.metadataComponents()
            let genreSet = Set(item.genres)
            // Split the facts line: genres ride the certificate line up top; the
            // year/runtime facts drop to the bottom row beside the ratings.
            let genreParts = comps.filter { genreSet.contains($0) }
            let factParts = comps.filter { !genreSet.contains($0) }
            let showRatings = !heroRatings.isEmpty && !spoilerSettings.shouldHideRatings(for: item)

            // Line 1: content-rating certificate + genres.
            ZStack(alignment: .leading) {
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
                }
            }
            // Description directly beneath the genres line.
            SpoilerSafeOverviewText(
                overview: item.overview,
                hidesSpoilers: hideText,
                mode: spoilerSettings.mode,
                lineCount: 3,
                maxWidth: 800,
                reservesSpace: false
            )
            // Bottom facts line just above the action buttons: year · runtime,
            // then the ratings, then the capability badges (4K / Atmos / HDR …),
            // all inline on one row.
            ZStack(alignment: .leading) {
                if !factParts.isEmpty || showRatings || !featureBadges.isEmpty {
                    HStack(alignment: .center, spacing: 16) {
                        if !factParts.isEmpty {
                            Text(factParts.joined(separator: "  ·  "))
                                .font(.system(size: 23, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .contentTransition(.opacity)
                        }
                        if showRatings {
                            RatingsBadgeRow(ratings: heroRatings)
                        }
                        if !featureBadges.isEmpty {
                            MediaBadgeRow(badges: featureBadges)
                        }
                    }
                }
            }
            if isDiscoveryItem ? showsRequestPill : ((playTitle != nil && onPlay != nil) || onPlayTrailer != nil || showsMoreMenu || hasHeroActionButtons) {
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
                    if let heroWatchlistAction {
                        watchlistButton(action: heroWatchlistAction)
                    }
                    if let heroWatchedAction {
                        watchedButton(action: heroWatchedAction)
                    }
                    if heroOffersRefresh {
                        refreshButton()
                    }
                    // The server + version choices live together in one subtle
                    // trailing "…" menu (not separate prominent buttons), so a
                    // multi-server / multi-version title stays uncluttered: one
                    // tap reveals which servers host it and which files each has.
                    if showsMoreMenu {
                        moreMenu(onSelectSource: onSelectSource, onSelectVersion: onSelectVersion)
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
                // The receded row is visually hidden, so remove only its controls
                // from focus. Disabling the entire hero would also disable the
                // sibling return proxy that restores Play on an UP press.
                .disabled(seriesRecedeModel?.isReceded == true)
                // Keep the whole action row pinned to the hero top: this row is
                // bottom-anchored in a hero that is full-screen-height for a
                // childless movie, so when focus lands on any button tvOS
                // auto-scrolls the page down to reveal it. Firing on every non-nil
                // change (not just row entry) corrects the drift for horizontal
                // moves *within* the row too, since tvOS re-nudges the scroll for
                // each newly-focused button.
                .onChange(of: heroActionRowFocus) { _, focus in
                    if focus != nil { onHeroActionFocused?() }
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
        .modifier(SeriesHeroContentRecedeModifier(model: seriesRecedeModel))
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
            heroBackdrop()
                // Re-key on the backdrop identity so a server switch (the only
                // thing that changes the backdrop — episode focus deliberately
                // keeps the show-level backdrop) cross-fades the old artwork out
                // and the new one in instead of hard-cutting.
                .id(backdrop.id)
                .transition(.opacity)
        }
        .overlay(alignment: .bottomLeading) {
            if let seriesRecedeModel {
                SeriesHeroFocusProxy(
                    model: seriesRecedeModel,
                    playButtonFocus: playButtonFocus,
                    bottomInset: bottomInset,
                    onRestore: { onHeroActionFocused?() }
                )
            }
        }
        // A right-aligned "Starring …" line opposite the action buttons (mirrors
        // the Apple TV detail layout). Billing order is our proxy for the stars;
        // the full cast still lives in the Cast row below. Shares the buttons'
        // `bottomInset` so the two sit on the same baseline, and is hidden while
        // the hero is receded for the episode browser.
        .overlay(alignment: .bottomTrailing) {
            if seriesRecedeModel?.isReceded != true, starringCastNames != nil || directorNames != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if let starringCastNames {
                        (Text("Starring ").foregroundStyle(.tertiary)
                            + Text(starringCastNames).foregroundStyle(.primary))
                            .lineLimit(2)
                    }
                    if let directorNames {
                        (Text("Director ").foregroundStyle(.tertiary)
                            + Text(directorNames).foregroundStyle(.primary))
                            .lineLimit(1)
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
            }
        }
        // Fade the whole hero (backdrop + text) in on first appearance rather
        // than hard-cutting, for a more polished open.
        .opacity(heroVisible ? 1 : 0)
        .onAppear {
            guard !heroVisible else { return }
            if reduceMotion {
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
            if showsMoreMenu { moreMenuFocused = true }
        }
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
            urls: [backdrop.heroBackdropURL, backdrop.backdropURL].compactMap { $0 },
            asyncFallbackURL: tmdbBackdropFallback,
            height: Self.screenHeight * heroHeightFraction,
            scrimTone: scrimTone,
            recedeModel: seriesRecedeModel
        )
    }

    /// The hero Play button. Extracted so the optional initial-focus binding can
    /// be applied to it conditionally (a `nil` binding leaves default focus
    /// behaviour untouched). When the resume target is partially watched the
    /// label becomes `▶  [progress bar]  … left`, keeping the button's normal
    /// height; otherwise it's the plain `▶  Play/Resume`.
    @ViewBuilder
    private func playButton(title: String, action: @escaping () -> Void) -> some View {
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
        let button = Button(action: action) {
            ZStack {
                if let sizingText {
                    playResumeSizer(remaining: sizingText).hidden()
                }
                PlayResumeButtonLabel(
                    title: title,
                    progress: playProgress,
                    remainingText: playRemainingText,
                    seasonEpisodeText: playSeasonEpisodeText,
                    onLight: playButtonHasFocus || colorScheme == .light
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
                    ResumeProgressCapsule(progress: progress, onLight: requestPillHasFocus || colorScheme == .light)
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
        (serverChoices.count > 1 && onSelectSource != nil) || (versions.count > 1 && onSelectVersion != nil)
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
    private func moreMenu(onSelectSource: ((String) -> Void)?, onSelectVersion: ((String) -> Void)?) -> some View {
        HeroMoreMenu(
            serverChoices: serverChoices,
            versions: versions,
            selectedSourceAccountID: selectedSourceAccountID,
            selectedVersionID: selectedVersionID,
            glyphSize: heroGlyphSize,
            iconSize: heroIconSize,
            onSelectSource: onSelectSource,
            onSelectVersion: onSelectVersion,
            onUserInitiatedSourceSwitch: { userInitiatedSourceSwitch = true }
        )
        .equatable()
        .modifier(HeroActionButtonStyle(prominent: false, circular: true))
        .focused($moreMenuFocused)
        .focused($heroActionRowFocus, equals: .more)
        .accessibilityLabel("Server and version options")
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

    /// Visible watched-state toggle, shown when the provider can mutate it. On a
    /// series page the hero mirrors the focused episode, so this doubles as the
    /// episode's visible watched toggle. Unwatched shows a neutral `eye`; marking
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
                    .opacity(item.isPlayed ? 0 : 1)
                    .scaleEffect(item.isPlayed ? 0.4 : 1)

                ZStack {
                    Circle()
                        .fill(ThemePalette.brandBlue)
                    // The check's draw-on is a direct function of `item.isPlayed`
                    // and carries its OWN animation keyed to that same value. This
                    // is deliberate: the surrounding `.animation(value:)` on the
                    // frame installs a *nil* animation on this whole subtree for any
                    // transaction where `isPlayed` didn't change, which silently
                    // squashed every previous draw-on (it ran in a separate, deferred
                    // transaction). Keeping the draw in the one transaction where
                    // `isPlayed` actually flips — and giving it a short delay so the
                    // circle pops first — makes it reliably animate on-device.
                    CheckmarkShape(progress: item.isPlayed ? 1 : 0)
                        .stroke(Color.white,
                                style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                        .padding(heroIconSize * 0.20)
                        .animation(.easeOut(duration: 0.32).delay(0.24), value: item.isPlayed)
                }
                .opacity(item.isPlayed ? 1 : 0)
                .scaleEffect(item.isPlayed ? 1 : 0.4)
            }
            .frame(width: heroIconSize, height: heroIconSize)
            .animation(.easeOut(duration: 0.18), value: item.isPlayed)
        }
        .modifier(HeroActionButtonStyle(prominent: false, circular: true))
        .focused($heroActionRowFocus, equals: .watched)
        .accessibilityLabel(action.title)
        .accessibilityValue(item.isPlayed ? "Watched" : "Not watched")
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
        let title = titleFallbackOverride
            ?? (hideText ? spoilerSettings.maskedTitle(for: item) : item.title)
        return Text(title)
            .font(.system(size: 64, weight: .bold))
            .lineLimit(2)
            .minimumScaleFactor(0.5)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 1200, alignment: .leading)
            .contentTransition(.opacity)
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

/// Equatable wrapper around the hero's "…" overflow Menu. Sits in its own view
/// so that re-renders of `DetailHeroView` (e.g. when `@FocusState
/// moreMenuFocused` flips as the picker opens, when async cross-server
/// discovery / alternate-source enrichment in `ItemDetailViewModel` updates
/// `sources` after the page has settled, or when an optimistic watched-state
/// notification arrives) don't rebuild the Menu while it's already open — that
/// rebuild is what produces the single-frame flash users see right after
/// opening the menu. Closures are intentionally excluded from `==`: they're
/// recreated on every parent render but invoke stable view-model methods, so
/// comparing the data inputs is sufficient to decide whether the menu needs
/// to redraw.
private struct HeroMoreMenu: View, Equatable {
    let serverChoices: [MediaSourceRef]
    let versions: [MediaVersion]
    let selectedSourceAccountID: String?
    let selectedVersionID: String?
    let glyphSize: CGFloat
    let iconSize: CGFloat
    let onSelectSource: ((String) -> Void)?
    let onSelectVersion: ((String) -> Void)?
    let onUserInitiatedSourceSwitch: () -> Void

    static func == (lhs: HeroMoreMenu, rhs: HeroMoreMenu) -> Bool {
        lhs.serverChoices == rhs.serverChoices
            && lhs.versions == rhs.versions
            && lhs.selectedSourceAccountID == rhs.selectedSourceAccountID
            && lhs.selectedVersionID == rhs.selectedVersionID
            && lhs.glyphSize == rhs.glyphSize
            && lhs.iconSize == rhs.iconSize
            && (lhs.onSelectSource == nil) == (rhs.onSelectSource == nil)
            && (lhs.onSelectVersion == nil) == (rhs.onSelectVersion == nil)
    }

    var body: some View {
        Menu {
            if serverChoices.count > 1, let onSelectSource {
                let currentServer = serverChoices.first { $0.accountID == selectedSourceAccountID } ?? serverChoices.first
                Section("Server") {
                    ForEach(serverChoices) { source in
                        Button {
                            onUserInitiatedSourceSwitch()
                            onSelectSource(source.accountID)
                        } label: {
                            if source.accountID == currentServer?.accountID {
                                Label(source.displayName, systemImage: "checkmark")
                            } else {
                                Text(source.displayName)
                            }
                        }
                    }
                }
            }
            if versions.count > 1, let onSelectVersion {
                let currentVersion = versions.first { $0.id == selectedVersionID } ?? versions.first
                Section("Version") {
                    ForEach(versions) { version in
                        Button {
                            onSelectVersion(version.id)
                        } label: {
                            if version.id == currentVersion?.id {
                                Label(version.displayLabel, systemImage: "checkmark")
                            } else {
                                Text(version.displayLabel)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: glyphSize))
                .foregroundStyle(Color.primary)
                .frame(width: iconSize, height: iconSize)
        }
    }
}

private struct SeriesHeroContentRecedeModifier: ViewModifier {
    let model: SeriesHeroRecedeModel?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let receded = model?.isReceded == true
        content
            .opacity(receded ? 0 : 1)
            .offset(y: reduceMotion ? 0 : (receded ? -120 : 0))
            .accessibilityHidden(receded)
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.3),
                value: receded
            )
    }
}

private struct SeriesDetailHeroBackdrop: View {
    let urls: [URL]
    let asyncFallbackURL: (@Sendable () async -> URL?)?
    let height: CGFloat
    let scrimTone: Color
    let recedeModel: SeriesHeroRecedeModel?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let receded = recedeModel?.isReceded == true
        HeroBackdropLayer(
            urls: urls,
            asyncFallbackURL: asyncFallbackURL,
            height: height,
            scrimTone: scrimTone,
            verticalOffset: reduceMotion ? 0 : (receded ? -260 : 0)
        )
        .animation(reduceMotion ? nil : .smooth(duration: 0.9), value: receded)
    }
}

private struct SeriesHeroFocusProxy: View {
    let model: SeriesHeroRecedeModel
    let playButtonFocus: FocusState<Bool>.Binding?
    let bottomInset: CGFloat
    let onRestore: () -> Void

    @FocusState private var focused: Bool

    @ViewBuilder
    var body: some View {
        if model.isReceded {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .contentShape(Rectangle())
                .focusable(true)
                .focused($focused)
                .focusEffectDisabled()
                .padding(.leading, PlozzTheme.Metrics.heroLeadingPadding)
                .padding(.trailing, PlozzTheme.Metrics.screenPadding)
                // Stand in for the receded action row as the same full-width focus
                // section, so UP from any Season chip has a section to enter.
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
                // Match the real action row's bottom band. This keeps the proxy
                // strictly above Seasons/Episodes instead of inserting an invisible
                // focusable between them.
                .padding(.bottom, bottomInset)
                .onChange(of: focused) { _, isFocused in
                    guard isFocused else { return }
                    model.restore()
                    onRestore()
                    // The action row becomes focusable after the recede-state update
                    // commits. Hand focus to Play on the following run-loop turn.
                    DispatchQueue.main.async {
                        playButtonFocus?.wrappedValue = true
                    }
                }
        }
    }
}

#endif
