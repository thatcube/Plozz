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
    /// Extends *only the backdrop image* (and its dissolve-to-background) below
    /// the hero content by this fraction of the screen height, without moving the
    /// title/Play (which stay pinned within `heroHeightFraction`). Used by the
    /// series page so the seamless fade lands closer to the top of the episode
    /// rail instead of completing high up the page.
    var backdropBottomExtensionFraction: CGFloat = 0
    let spoilerSettings: SpoilerSettings
    /// Replaces the hero's own subtitle when set. Used by a TV-show hero that is
    /// presenting the *series* (not a focused episode) to still surface the
    /// next-up episode's "S{n} · E{m}" — so the season/episode is shown on every
    /// entry path, including a plain series open, without swapping the series hero
    /// out for an episode (which would drop the series art / Trailer button).
    var subtitleOverride: String? = nil
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
    /// When provided, a secondary "Trailer" button is shown next to Play.
    var onPlayTrailer: (() -> Void)? = nil
    /// The selectable versions for this title. When more than one exists and
    /// `onSelectVersion` is set, a "Version" picker button is shown next to Play
    /// so the user can choose which source `Play` targets.
    var versions: [MediaVersion] = []
    /// The currently-effective selected version id (drives the picker's label and
    /// the menu checkmark). `nil` falls back to the first/recommended version.
    var selectedVersionID: String? = nil
    /// This device's capabilities, used to predict Direct Play vs Transcode for
    /// each version in the picker (the creative compatibility badge).
    var capabilities: MediaCapabilities = .detected()
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

    /// Local focus state of the Play button, so the inline resume progress bar
    /// can flip its colours to stay visible against the button's focused (white)
    /// vs unfocused (dark) background.
    @FocusState private var playButtonHasFocus: Bool
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

    /// Routes a hero button through the shared action handler with this hero's
    /// item + context — the exact same path the context menu uses.
    private func performHeroAction(_ action: MediaItemAction) {
        actionHandler?.perform(action, on: item, context: actionContext)
    }

    /// The capability badges shown above the ratings: resolution/HDR/audio. The
    /// content-rating certificate is rendered separately, inline with the
    /// year/runtime/genre metadata line.
    private var featureBadges: [MediaBadge] {
        // Prefer the focused item's own tech badges; fall back to the derived
        // series-level set for a series/season hero (or an episode whose stream
        // info hasn't loaded), so tech badges are present on every kind.
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

    var body: some View {
        let hideText = spoilerSettings.shouldHideText(for: item)
        let hideThumbnail = spoilerSettings.shouldHideThumbnail(for: item)
        let heroHeight = Self.screenHeight * heroHeightFraction
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
                backgroundSample: heroBackgroundSample
            ) {
                titleText(hideText: hideText)
            }
            if let subtitle = subtitleOverride ?? item.subtitle, !isYearOnlySubtitle(subtitle) {
                Text(subtitle)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            let metadata = item.metadataComponents()
            if heroRatingBadge != nil || !metadata.isEmpty {
                HStack(alignment: .center, spacing: 16) {
                    if let badge = heroRatingBadge {
                        MediaBadgeChip(badge: badge)
                    }
                    if !metadata.isEmpty {
                        Text(metadata.joined(separator: "  ·  "))
                            .font(.system(size: 23, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
            }
            if !hideText, let tagline = item.tagline {
                Text(tagline)
                    .font(.system(size: 24, weight: .medium))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 960, alignment: .topLeading)
                    .contentTransition(.opacity)
            }
            if !featureBadges.isEmpty {
                MediaBadgeRow(badges: featureBadges)
            }
            if !heroRatings.isEmpty && !spoilerSettings.shouldHideRatings(for: item) {
                RatingsBadgeRow(ratings: heroRatings)
            }
            if hideText {
                Label("Overview hidden to avoid spoilers", systemImage: "eye.slash.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 960, alignment: .topLeading)
            } else if let overview = item.overview {
                Text(overview)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    // Reserve three lines of height even when the text is
                    // shorter, so swapping the focused item never makes the
                    // controls below jump up and down.
                    .lineLimit(3, reservesSpace: true)
                    .frame(maxWidth: 960, alignment: .topLeading)
                    .contentTransition(.opacity)
            }
            if (playTitle != nil && onPlay != nil) || onPlayTrailer != nil || showsMoreMenu || hasHeroActionButtons {
                HStack(spacing: 24) {
                    if let playTitle, let onPlay {
                        playButton(title: playTitle, action: onPlay)
                    }
                    if let onPlayTrailer {
                        Button(action: onPlayTrailer) {
                            Label("Trailer", systemImage: "film.fill")
                        }
                        .modifier(HeroButtonStyle(prominent: false))
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
                .padding(.top, 8)
                // Make the action row its own focus section so pressing "up" from
                // a season parked far to the right reliably lands here. Note we no
                // longer stretch this to `.infinity`: a full-width focusable HStack
                // inside the hero, combined with the over-wide full-bleed backdrop,
                // was part of what let the focus engine pan the page off the left
                // edge. Leading-sized + `.focusSection()` keeps the "up" target
                // without contributing any over-wide focusable geometry.
                .focusSection()
            }
        }
        .padding(.vertical, PlozzTheme.Metrics.screenPadding)
        .padding(.trailing, PlozzTheme.Metrics.screenPadding)
        .padding(.leading, PlozzTheme.Metrics.heroLeadingPadding)
        // Occupy the backdrop's height and pin the content to the bottom-leading
        // corner — exactly what the old `ZStack(alignment: .bottomLeading)` did,
        // but measured at the *safe* viewport width (`.infinity` reports the
        // proposed width), never the full 1920pt panel.
        .frame(maxWidth: .infinity, minHeight: heroHeight, alignment: .bottomLeading)
        // The full-bleed backdrop lives in a `.background`, which by definition is
        // sized to the host and does NOT contribute to the host's measured size.
        // That is the fix: previously the backdrop was a ZStack *sibling* whose
        // `.ignoresSafeArea(.horizontal)` inflated the ZStack — and therefore the
        // whole scroll column — to the full panel width (~1920). A vertical
        // ScrollView then centred that over-wide content, throwing the
        // leading-aligned title/Play off the left edge while the centred image
        // still looked correct. As a background, the image bleeds edge-to-edge
        // purely visually and the content column stays at the safe width.
        .background(alignment: backdropBottomExtensionFraction > 0 ? .top : .bottom) {
            heroBackdrop(hideThumbnail: hideThumbnail)
                // Re-key on the backdrop identity so a server switch (the only
                // thing that changes the backdrop — episode focus deliberately
                // keeps the show-level backdrop) cross-fades the old artwork out
                // and the new one in instead of hard-cutting.
                .id(backdrop.id)
                .transition(.opacity)
        }
        // Fade the whole hero (backdrop + text) in on first appearance rather
        // than hard-cutting, for a more polished open.
        .opacity(heroVisible ? 1 : 0)
        .onAppear {
            guard !heroVisible else { return }
            withAnimation(.easeInOut(duration: 0.35)) { heroVisible = true }
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
    private func heroBackdrop(hideThumbnail: Bool) -> some View {
        FallbackAsyncImage(
            urls: [backdrop.heroBackdropURL, backdrop.backdropURL].compactMap { $0 },
            maxAspectRatio: 3.0,
            asyncFallbackURL: tmdbBackdropFallback
        ) {
            heroPlaceholder
        }
        .frame(height: Self.screenHeight * (heroHeightFraction + backdropBottomExtensionFraction))
        .frame(maxWidth: .infinity)
        .clipped()
        .blur(radius: hideThumbnail && spoilerSettings.mode == .blur ? 40 : 0)
        .overlay(
            // Legibility scrim: fade a mode-appropriate tone in over the leading
            // side so the title/logo/overview read clearly against the artwork —
            // a dark tone in dark mode (for light content), a light tone in light
            // mode (for dark content). The *geometry is identical in both modes*;
            // only the tone flips, so legibility is consistent across appearances.
            // It lives *under* the dissolve mask below, so it fades away with the
            // image and never tints the revealed background.
            //
            // The vertical ramp starts high enough to reach the logo (which sits
            // above the title), and a horizontal falloff concentrates the wash on
            // the leading side (where the content sits) while leaving the right
            // side of the image — the hero subject — clear.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.20),
                    .init(color: scrimTone.opacity(0.72), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0.0),
                        .init(color: .white, location: 0.40),
                        .init(color: .clear, location: 0.85)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        )
        // Dissolve the backdrop's own alpha to transparent over the lower
        // portion (top third stays a clean image) so the real `AppBackground`
        // shows straight through. Because that is the *same* fixed surface the
        // content below sits on, the transition is perfectly seamless — there
        // is no second colour to mismatch, so no hard line ever appears.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .white, location: 0.0),
                    .init(color: .white, location: 0.33),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        // Break out of the tvOS overscan safe area so the backdrop spans the
        // full screen edge to edge — across the top as well, otherwise the
        // top overscan inset shows through as a black bar above the artwork.
        .ignoresSafeArea(edges: [.top, .horizontal])
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
        let showProgress = liveResumeText != nil && !item.isPlayed
        let sizingText = reservedResumeText ?? liveResumeText
        let button = Button(action: action) {
            ZStack {
                if let sizingText {
                    playResumeSizer(remaining: sizingText).hidden()
                }
                playButtonLabel(showProgress: showProgress, title: title)
            }
        }
        .modifier(HeroButtonStyle(prominent: true))
        .focused($playButtonHasFocus)
        .onChange(of: liveResumeText) { _, new in
            if let new { reservedResumeText = new }
        }
        .onAppear {
            if let liveResumeText { reservedResumeText = liveResumeText }
        }

        if let playButtonFocus {
            button.focused(playButtonFocus, equals: true)
        } else {
            button
        }
    }

    /// The live resume "… left" text when the item has a real partial position
    /// (0 < progress < 1), else `nil`.
    private var resumeText: String? {
        guard let playRemainingText, let playProgress, playProgress > 0, playProgress < 1 else { return nil }
        return playRemainingText
    }

    /// The Play button's inner label: either `▶  [progress bar]  … left` (resume
    /// form) or the plain `▶  Play/Resume` title.
    @ViewBuilder
    private func playButtonLabel(showProgress: Bool, title: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "play.fill")
            if showProgress, let playRemainingText, let playProgress {
                resumeProgressCapsule(progress: playProgress)
                Text(playRemainingText)
                    .lineLimit(1)
            } else {
                Text(title)
                    .lineLimit(1)
            }
        }
    }

    /// An invisible copy of the resume form used purely to reserve the Play
    /// button's width. The progress capsule is a fixed width, so any progress
    /// value sizes identically; only the variable "… left" text matters.
    private func playResumeSizer(remaining: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "play.fill")
            resumeProgressCapsule(progress: 1)
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
    /// active server's editions/qualities with a predicted Direct Play / Transcode
    /// badge for this device, active one checkmarked). Either section is omitted
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
            capabilities: capabilities,
            glyphSize: heroGlyphSize,
            iconSize: heroIconSize,
            onSelectSource: onSelectSource,
            onSelectVersion: onSelectVersion,
            onUserInitiatedSourceSwitch: { userInitiatedSourceSwitch = true }
        )
        .equatable()
        .modifier(HeroButtonStyle(prominent: false))
        .focused($moreMenuFocused)
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
        .modifier(HeroButtonStyle(prominent: false))
        .animation(.easeInOut(duration: 0.2), value: item.isFavorite)
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
        .modifier(HeroButtonStyle(prominent: false))
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
        .modifier(HeroButtonStyle(prominent: false))
        .focused($refreshButtonHasFocus)
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
    /// play icon and the "… left" line. Its colours flip with the button's focus
    /// state — light fill on the dark unfocused button, dark fill on the white
    /// focused button — so it stays clearly visible either way.
    private func resumeProgressCapsule(progress: Double) -> some View {
        let onLight = playButtonHasFocus || colorScheme == .light
        let track = onLight ? Color.black.opacity(0.22) : Color.white.opacity(0.32)
        let fill = onLight ? Color.black.opacity(0.85) : Color.white
        let width: CGFloat = 150
        return Capsule()
            .fill(track)
            .frame(width: width, height: 6)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(fill)
                    .frame(width: max(8, width * progress), height: 6)
            }
            .animation(.easeInOut(duration: 0.2), value: onLight)
    }

    /// The plain text title, used both under spoilers and as the fallback when no
    /// logo art can be resolved. Width is capped (and the text wraps/scales) so a
    /// very long title can never render as a single line wider than the screen —
    /// which would blow the hero's content past the viewport and shove the whole
    /// page (title + focusable buttons) off the left edge.
    private func titleText(hideText: Bool) -> some View {
        Text(hideText ? spoilerSettings.maskedTitle(for: item) : item.title)
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

    /// The hero's final, always-keyless background when no real landscape art is
    /// available from the server or any external provider. Rather than a flat grey
    /// panel, it blows up the item's own poster, scaled to fill and heavily blurred
    /// into a soft cinematic wash, so a movie/show with only a poster still gets a
    /// rich coloured hero instead of an empty one. Falls back to the neutral fill
    /// only when there is no poster at all.
    @ViewBuilder
    private var heroPlaceholder: some View {
        if let poster = backdrop.posterURL {
            AsyncImage(url: poster) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 60)
                        .scaleEffect(1.2)
                        .overlay(Color.black.opacity(0.35))
                default:
                    Rectangle().fill(.tertiary)
                }
            }
        } else {
            Rectangle().fill(.tertiary)
        }
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
        return {
            await ArtworkRouter.shared.artworkURL(.hero, for: source)
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

/// Applies the native Liquid Glass button style to the hero's action buttons on
/// OS versions that ship it (tvOS 26+), falling back to the classic bordered
/// styles below that. `prominent` picks the tinted primary glass (Play) versus
/// the lighter clear glass (secondary actions like Trailer).
private struct HeroButtonStyle: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
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
    let capabilities: MediaCapabilities
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
            && lhs.capabilities == rhs.capabilities
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
                            let badge = version.compatibility(with: capabilities).badge
                            let suffix = badge.isEmpty ? "" : "  •  \(badge)"
                            if version.id == currentVersion?.id {
                                Label(version.displayLabel + suffix, systemImage: "checkmark")
                            } else {
                                Text(version.displayLabel + suffix)
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

#endif
