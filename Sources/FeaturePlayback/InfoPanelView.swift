#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreUI
import CoreModels

/// The Info panel's now-playing card: a 16:9 thumbnail, the episode headline +
/// overview, a metadata/badge row, and the right-hand action column (Restart ·
/// Previous · Next Episode) with a bottom-pinned Playback Info toggle.
///
/// Extracted from `PlayerControls` as a standalone view: it takes the controls
/// model + options actions, a binding to the shared focus slot (so its buttons
/// participate in the same `@FocusState` engine as the rest of the transport),
/// and an `onClose` callback for actions that dismiss the panel (Restart). It
/// owns none of the panel morph/focus-restore choreography — that stays in
/// `PlayerControls` — so this is a pure content extraction.
struct InfoPanelView: View {
    /// Fixed 16:9 thumbnail height; the card's height is derived from it.
    ///
    /// Raised from 210 to give BOTH tabs of the card real room — the Cast tab
    /// shares this stage, and at 210 its credit posters, biography and face
    /// cards were all fighting for the same scarce lines. Everything that sizes
    /// off `cardHeight` follows automatically.
    /// Height of the card's thumbnail, and the peg everything else hangs off.
    ///
    /// Smaller on iPad, where the same card is read at arm's length rather than
    /// across a room: 250 + 24 padding gives a 298pt card that is right at three
    /// metres and overbearing on an 11-inch display. 208 + 16 lands the card at
    /// exactly 240 — a fifth shorter, and every value here a multiple of 8, so
    /// the rhythm survives the change.
    #if os(tvOS)
    static let thumbHeight: CGFloat = 250
    /// Padding between the card's content and its glass edge.
    static let contentPadding: CGFloat = 24
    #else
    /// On a phone the card carries no thumbnail at all (see `body`), so this is
    /// the content's height rather than any picture's. 128 + 12 padding lands
    /// the card at 152 — about a third of an iPhone's landscape height, which is
    /// as much as a card describing the video can take before it buries it.
    static let thumbHeight: CGFloat = PlayerCardSurface.isCompact ? 128 : 208
    /// Padding between the card's content and its glass edge.
    static let contentPadding: CGFloat = PlayerCardSurface.isCompact ? 12 : 16
    #endif

    /// The card's **exact** laid-out height, known up front rather than measured.
    ///
    /// Everything in the card is pinned to `thumbHeight` (the text column and the
    /// action column both are), so this is deterministic. `PlayerControls` needs it
    /// before the first frame to park the cluster with the card just off-screen —
    /// measuring it instead meant the parked offset changed the moment the
    /// measurement landed (and again whenever metadata arrived), which showed up as
    /// the transport jumping.
    static var cardHeight: CGFloat { thumbHeight + contentPadding * 2 }

    let model: PlayerControlsModel
    let actions: PlayerOptionsActions
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    /// Dismiss the panel (used by Restart, which returns to playback). Focus is
    /// restored centrally by `PlayerControls`'s `onChange(of: openPanel)`.
    let onClose: () -> Void

    /// The bottom metadata row content: "S2 · E7 · 42m" (season/episode + runtime),
    /// shown inline with the technical badges — Apple-TV style.
    private var infoMetaLine: String {
        [model.infoCard.episodeTag, model.infoCard.runtimeLabel]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// A wide now-playing card that fades in over the title/description slot (the
    /// video keeps playing full-frame behind it). A fixed-height 16:9 thumbnail
    /// drives the card height so the art fills top-to-bottom and the borders stay
    /// equidistant on every edge whether or not the item has a description. The
    /// headline is the episode (not the show) title; season/episode + runtime ride
    /// inline with the badges on the bottom row.
    ///
    /// The right column holds an **icon-only** action row (Restart · Previous ·
    /// Next Episode) pinned to the top and a subtle **Playback Info** toggle pinned
    /// to the bottom (it drives the diagnostics overlay, moved off the transport
    /// row). The focused action expands to show its label — the tvOS equivalent of
    /// a tooltip, since there is no hover. Icons keep the row short so the artwork —
    /// not a tall stack of text buttons — governs the card height (no dead space
    /// beneath it).
    var body: some View {
        // Concentric radii, matching the app's cards: the thumbnail's media radius
        // nested inside the card's glass radius (outer = inner + content padding),
        // so both corners share a centre.
        let thumbRadius = PlozzTheme.Metrics.mediumMediaCornerRadius
        let contentPad = Self.contentPadding
        let thumbHeight = Self.thumbHeight

        return Group {
            if PlayerCardSurface.isCompact {
                compactBody
            } else {
                regularBody(thumbRadius: thumbRadius, thumbHeight: thumbHeight)
            }
        }
        .padding(contentPad)
        // Pin the height so `cardHeight` is a promise, not an estimate.
        .frame(height: Self.cardHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PanelGlassBackground(cornerRadius: PlozzTheme.Metrics.playerPanelCornerRadius))
    }

    /// The phone card: no thumbnail, and the three columns folded into rows.
    ///
    /// Dropping the artwork is not just a space saving, though it is the biggest
    /// one available — a 16:9 still is 370pt wide at this height, more than half
    /// an iPhone's landscape width. It is also the single most redundant thing on
    /// the card: the video it depicts is playing at full size directly behind it.
    ///
    /// The actions keep their two groups but swap axis, riding the bottom line
    /// with the metadata rather than standing in a column of their own.
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.infoCard.headline.isEmpty ? "Now Playing" : model.infoCard.headline)
                .font(PlayerCardText.title)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            if !model.infoCard.overview.isEmpty {
                Text(model.infoCard.overview)
                    .font(PlayerCardText.body)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }

            Spacer(minLength: 0)

            // One bottom line, because there is no room for two: Playback Info
            // at the far left — kept apart from the three transport actions,
            // being a diagnostics toggle rather than something you reach for
            // while watching — then the metadata, then the actions at the right.
            HStack(spacing: 10) {
                infoActionButton(
                    title: "Playback Info",
                    icon: "cpu",
                    prominent: model.diagnosticsEnabled,
                    slot: .infoStats
                ) {
                    model.diagnosticsEnabled.toggle()
                }

                if !infoMetaLine.isEmpty {
                    Text(infoMetaLine)
                        .font(PlayerCardText.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                if !model.infoCard.badges.isEmpty {
                    MediaBadgeRow(badges: model.infoCard.badges)
                }

                Spacer(minLength: 8)

                infoActionButton(title: "Restart", icon: "arrow.counterclockwise", prominent: false, slot: .infoRestart) {
                    actions.restart()
                    onClose()
                }
                if model.infoCard.hasPreviousEpisode {
                    infoActionButton(title: "Previous", icon: "backward.end.fill", prominent: false, slot: .infoPrev) {
                        actions.playPreviousEpisode()
                    }
                }
                if model.infoCard.hasNextEpisode {
                    infoActionButton(title: "Next Episode", icon: "forward.end.fill", prominent: true, slot: .infoNext) {
                        actions.playNextEpisode()
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func regularBody(thumbRadius: CGFloat, thumbHeight: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 28) {
            infoThumbnail(cornerRadius: thumbRadius, height: thumbHeight)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.infoCard.headline.isEmpty ? "Now Playing" : model.infoCard.headline)
                    .font(PlayerCardText.title)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if !model.infoCard.overview.isEmpty {
                    // Ellipsis, no `fixedSize`: the overview truncates instead of
                    // forcing its full height, so a long synopsis can never push
                    // the meta/badge row off the bottom of the card (it stays
                    // pinned by the Spacer below).
                    //
                    // `layoutPriority` makes the overview the column's *protected*
                    // element rather than its elastic one. This column is locked to
                    // `thumbHeight`, and the budget is tighter than it looks:
                    // a one-line title plus three lines of overview plus the
                    // spacings and the meta row uses most of it. Because
                    // `lineLimit(3)` is a cap rather than a reservation, the
                    // overview is what silently gives up lines when the title
                    // wraps — which is exactly what it used to do.
                    //
                    // The shared scale (see `PlayerCardText`) is smaller than the
                    // semantic fonts this used to use — .headline 45.35pt per line
                    // and .footnote 34.61 — so there is now real slack here rather
                    // than the ~5pt there was.
                    //
                    // Sizing the overview first inverts that: it always gets its
                    // three lines, and the headline takes the remainder — keeping
                    // both of its lines whenever the synopsis is short enough to
                    // leave room, and truncating to one when it isn't.
                    Text(model.infoCard.overview)
                        .font(PlayerCardText.body)
                        .foregroundStyle(.white.opacity(0.82))
                        // Four lines now that the card is 40pt taller. Still a
                        // cap rather than a reservation — see the note above.
                        .lineLimit(4)
                        .truncationMode(.tail)
                        .padding(.top, 1)
                        .layoutPriority(1)
                }
                // Pins the meta/badge row to the card's bottom edge. `minLength: 0`
                // is load-bearing, not laziness: this column has 210pt, and a
                // one-line headline plus three lines of overview plus the meta row
                // and the VStack's own spacings comes to 202.78 — leaving 7.22 here.
                // An 8pt minimum could not be satisfied by 0.78pt, so the *overview*
                // paid for it by dropping to two lines, and this Spacer then grew to
                // ~42pt of dead air. The 6pt VStack spacing on either side already
                // separates the rows, so the floor bought nothing and cost a line.
                Spacer(minLength: 0)
                // Bottom metadata row: season/episode + runtime, then the technical
                // badges, all on one baseline pinned to the card's bottom edge.
                HStack(alignment: .center, spacing: 12) {
                    if !infoMetaLine.isEmpty {
                        Text(infoMetaLine)
                            .font(PlayerCardText.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    if !model.infoCard.badges.isEmpty {
                        MediaBadgeRow(badges: model.infoCard.badges)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(height: thumbHeight, alignment: .topLeading)

            Spacer(minLength: 32)

            // Right column: icon action row pinned top, Playback Info toggle
            // pinned bottom. Both are full-width focus sections so a Down press
            // from ANY top button (even the left-most Restart) routes to Playback
            // Info: a right-aligned single button wouldn't sit under Restart, so
            // the bottom row spans the column width (Spacer + button) and is its
            // own `.focusSection()`, bridging the horizontal offset.
            VStack(alignment: .trailing, spacing: 12) {
                HStack(spacing: 12) {
                    // Order: Restart · Previous · Next Episode (primary, far right).
                    infoActionButton(title: "Restart", icon: "arrow.counterclockwise", prominent: false, slot: .infoRestart) {
                        actions.restart()
                        onClose()   // focus restored centrally in onChange(of: openPanel)
                    }
                    if model.infoCard.hasPreviousEpisode {
                        infoActionButton(title: "Previous", icon: "backward.end.fill", prominent: false, slot: .infoPrev) {
                            actions.playPreviousEpisode()
                        }
                    }
                    if model.infoCard.hasNextEpisode {
                        infoActionButton(title: "Next Episode", icon: "forward.end.fill", prominent: true, slot: .infoNext) {
                            actions.playNextEpisode()
                        }
                    }
                }
                .plozzFocusSection()
                Spacer(minLength: 0)
                // Subtle Playback Info (diagnostics) toggle, bottom-right —
                // balances the tech badges bottom-left. Keeps the Info panel open
                // so the viewer can flip it and watch the top-left overlay appear.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    infoActionButton(
                        title: "Playback Info",
                        icon: "cpu",
                        prominent: model.diagnosticsEnabled,
                        slot: .infoStats
                    ) {
                        model.diagnosticsEnabled.toggle()
                    }
                }
                .plozzFocusSection()
            }
            .frame(height: thumbHeight, alignment: .topTrailing)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func infoThumbnail(cornerRadius: CGFloat, height: CGFloat) -> some View {
        Color.clear
            .frame(width: height * 16.0 / 9.0, height: height)
            .overlay {
                FallbackAsyncImage(urls: model.infoCard.artworkURLs, variant: .landscapeCard) {
                    // Fixed white, NOT palette.fill: this sits over the player's
                    // variable video/artwork backdrop (always dark-scrimmed), so a
                    // theme-tracking fill would be wrong here — it's a scrim-relative
                    // placeholder, not a themed-page surface.
                    Rectangle().fill(Color.white.opacity(0.08))
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 34, weight: .regular))
                                .foregroundStyle(.white.opacity(0.28))
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .plozzMediaEdge(cornerRadius: cornerRadius)
    }

    /// An icon-only Info-card action. At rest it shows just its glyph; while
    /// focused it **expands** to reveal its label (the tvOS stand-in for a hover
    /// tooltip). The width/expand animates, but the focus **colours are instant**:
    /// the `.animation` is scoped to the label's layout only, so the capsule grows
    /// smoothly while `InfoActionButtonStyle` swaps fill/foreground on the same
    /// frame (the stock glass styles animate their focus tint, which can't be
    /// disabled from outside — hence the custom style).
    private func infoActionButton(
        title: LocalizedStringResource,
        icon: String,
        prominent: Bool,
        slot: PlayerControls.FocusSlot,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus == slot
        return Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                if isFocused {
                    // `.identity` (no fade): the label appears at full opacity and
                    // is revealed by the capsule growing around it, so the reveal
                    // reads as pure movement, not a cross-fade.
                    Text(title).fixedSize().transition(.identity)
                }
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            // Scope the animation to the label's layout: the capsule (sized to the
            // label in the style) follows this and grows smoothly, while the fill
            // and text colours — applied OUTSIDE this scope — change instantly.
            .animation(.easeOut(duration: 0.2), value: isFocused)
        }
        .buttonStyle(InfoActionButtonStyle(focused: isFocused, prominent: prominent))
        .focused($focus, equals: slot)
    }
}
#endif
