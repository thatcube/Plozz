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
    /// The regular-size numbers, for the tvOS transport's parking offset.
    ///
    /// `PlayerControls` needs a card height before the first frame — measuring
    /// it instead meant the parked offset changed the moment the measurement
    /// landed, which showed up as the transport jumping. tvOS has exactly one
    /// size, so a static answer is a true one there; every other surface reads
    /// `playerCardMetrics` from the environment, because a resizable window has
    /// no single answer.
    static var thumbHeight: CGFloat { PlayerCardMetrics.platformDefault.contentHeight }
    static var contentPadding: CGFloat { PlayerCardMetrics.platformDefault.contentPadding }
    static var cardHeight: CGFloat { PlayerCardMetrics.platformDefault.cardHeight }

    @Environment(\.playerCardMetrics) private var metrics

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
        let contentPad = metrics.contentPadding

        return Group {
            if metrics.showsThumbnail {
                regularBody(thumbRadius: thumbRadius, thumbHeight: metrics.contentHeight)
                    .padding(contentPad)
            } else {
                compactBody
                    .padding(contentPad)
                    // Hugs its content rather than filling to the ceiling: a
                    // three-line synopsis should not leave a well of empty glass
                    // under it. The natural copy is the NON-scrolling column —
                    // see the modifier.
                    .playerCardNaturalHeight(cap: metrics.cardHeight) {
                        compactNaturalBody.padding(contentPad)
                    }
            }
        }
        // Pinned in the horizontal layout, where `cardHeight` is a promise the
        // transport's parking offset depends on. The vertical card takes its
        // content's height instead and stops at the ceiling: a column of text
        // has no business holding a fixed height, and a short synopsis would
        // leave a well of empty glass under it.
        .modifier(PlayerCardHeight(metrics: metrics))
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PanelGlassBackground(cornerRadius: metrics.panelCornerRadius))
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
        compactStack {
            // Title and synopsis SCROLL rather than truncating to a line count —
            // but only when they have to.
            //
            // The horizontal card truncates because it is a band across the video
            // and cannot grow. This one is a column with room to spare, so a long
            // synopsis can simply be read. A ScrollView always accepts the full
            // height it is offered, though, so wrapping the text unconditionally
            // made every card as tall as its ceiling; `ViewThatFits` takes the
            // plain column when it fits and the scrolling copy only when it does
            // not.
            ViewThatFits(in: .vertical) {
                infoTextColumn
                ScrollView(.vertical, showsIndicators: false) { infoTextColumn }
            }
        }
    }

    /// The same card with the text at its natural height and no scroll view, so
    /// it can be measured — a `ScrollView` has no ideal height to report.
    private var compactNaturalBody: some View {
        compactStack { infoTextColumn }
    }

    private func compactStack<TextColumn: View>(
        @ViewBuilder textColumn: () -> TextColumn
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            textColumn()

            // Metadata gives up its badges rather than clipping them.
            //
            // `ViewThatFits` because the badge row's width is content, not
            // layout: four badges on a 4K Dolby Vision Atmos file are far wider
            // than the one on a plain SDR episode, so no fixed breakpoint gets
            // this right. It takes the full row when it fits and the meta line
            // alone when it does not — the badges being available on the item's
            // detail page, while the season/episode/runtime is the line that
            // says WHERE you are.
            ViewThatFits(in: .horizontal) {
                metaRow(includingBadges: true)
                metaRow(includingBadges: false)
            }

            // Playback Info at the far left, apart from the three transport
            // actions: it is a diagnostics toggle rather than something reached
            // for while watching, and grouping it with them would invite it to
            // be pressed by mistake.
            HStack(spacing: 10) {
                infoActionButton(
                    title: "Playback Info",
                    icon: "cpu",
                    prominent: model.diagnosticsEnabled,
                    slot: .infoStats
                ) {
                    model.diagnosticsEnabled.toggle()
                }

                Spacer(minLength: 12)

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

    private var infoTextColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.infoCard.headline.isEmpty ? "Now Playing" : model.infoCard.headline)
                .font(metrics.titleFont)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            if !model.infoCard.overview.isEmpty {
                Text(model.infoCard.overview)
                    .font(metrics.bodyFont)
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func metaRow(includingBadges: Bool) -> some View {
        HStack(spacing: 10) {
            if !infoMetaLine.isEmpty {
                Text(infoMetaLine)
                    .font(metrics.captionFont)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    // Holds its size, like the badges beside it — see the note at
                    // the call site.
                    .fixedSize(horizontal: true, vertical: false)
            }
            if includingBadges, !model.infoCard.badges.isEmpty {
                MediaBadgeRow(badges: model.infoCard.badges)
            }
            Spacer(minLength: 0)
        }
    }

    private func regularBody(thumbRadius: CGFloat, thumbHeight: CGFloat) -> some View {
        HStack(alignment: .top, spacing: metrics.columnSpacing) {
            infoThumbnail(cornerRadius: thumbRadius, height: thumbHeight)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.infoCard.headline.isEmpty ? "Now Playing" : model.infoCard.headline)
                    .font(metrics.titleFont)
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
                    // The shared scale (see `PlayerCardMetrics`) is smaller than the
                    // semantic fonts this used to use — .headline 45.35pt per line
                    // and .footnote 34.61 — so there is now real slack here rather
                    // than the ~5pt there was.
                    //
                    // Sizing the overview first inverts that: it always gets its
                    // three lines, and the headline takes the remainder — keeping
                    // both of its lines whenever the synopsis is short enough to
                    // leave room, and truncating to one when it isn't.
                    Text(model.infoCard.overview)
                        .font(metrics.bodyFont)
                        .foregroundStyle(.white.opacity(0.82))
                        // Four lines now that the card is 40pt taller. Still a
                        // cap rather than a reservation — see the note above.
                        .lineLimit(metrics.overviewLineLimit)
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
                //
                // Every badge is `fixedSize`, so in a row that overflows the meta
                // line was the only thing that could give — and "S2 · E9 · 1h"
                // truncated to "S2…" while the badges kept every pixel. It is the
                // shorter string AND the more useful one, so it holds its size and
                // the badges are dropped instead when the row will not fit.
                ViewThatFits(in: .horizontal) {
                    metaRow(includingBadges: true)
                    metaRow(includingBadges: false)
                }
            }
            .frame(maxWidth: metrics.textColumnMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: thumbHeight, alignment: .topLeading)

            // NO Spacer here. A Spacer is flexible and so is the text column, so
            // the two split the width left over by the thumbnail and the action
            // column — which is why the synopsis truncated with obvious empty
            // card beside it. The text column takes the whole remainder now, and
            // the HStack's own spacing does what the Spacer was for.

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
            .font(metrics.actionFont)
            .lineLimit(1)
            // Scope the animation to the label's layout: the capsule (sized to the
            // label in the style) follows this and grows smoothly, while the fill
            // and text colours — applied OUTSIDE this scope — change instantly.
            .animation(.easeOut(duration: 0.2), value: isFocused)
        }
        .buttonStyle(InfoActionButtonStyle(
            focused: isFocused,
            prominent: prominent,
            hPadding: metrics.actionHPadding,
            vPadding: metrics.actionVPadding
        ))
        .focused($focus, equals: slot)
    }
}
#endif
