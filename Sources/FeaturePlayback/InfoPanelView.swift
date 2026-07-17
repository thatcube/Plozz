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
    let model: PlayerControlsModel
    let actions: PlayerOptionsActions
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    /// Dismiss the panel (used by Restart, which returns to playback). Focus is
    /// restored centrally by `PlayerControls`'s `onChange(of: openPanel)`.
    let onClose: () -> Void

    /// The bottom metadata row content: "S2 · E7 · 42m" (season/episode + runtime),
    /// shown inline with the technical badges — Apple-TV style.
    private var infoMetaLine: String {
        [model.infoEpisodeTag, model.infoRuntimeLabel]
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
        let contentPad: CGFloat = 24
        let thumbHeight: CGFloat = 210

        return HStack(alignment: .top, spacing: 28) {
            infoThumbnail(cornerRadius: thumbRadius, height: thumbHeight)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.infoHeadline.isEmpty ? "Now Playing" : model.infoHeadline)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if !model.overview.isEmpty {
                    // Ellipsis, no `fixedSize`: the overview truncates instead of
                    // forcing its full height, so a long synopsis can never push
                    // the meta/badge row off the bottom of the card (it stays
                    // pinned by the Spacer below).
                    Text(model.overview)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .padding(.top, 1)
                }
                Spacer(minLength: 8)
                // Bottom metadata row: season/episode + runtime, then the technical
                // badges, all on one baseline pinned to the card's bottom edge.
                HStack(alignment: .center, spacing: 12) {
                    if !infoMetaLine.isEmpty {
                        Text(infoMetaLine)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    if !model.infoBadges.isEmpty {
                        MediaBadgeRow(badges: model.infoBadges)
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
                    if model.hasPreviousEpisode {
                        infoActionButton(title: "Previous", icon: "backward.end.fill", prominent: false, slot: .infoPrev) {
                            actions.playPreviousEpisode()
                        }
                    }
                    if model.hasNextEpisode {
                        infoActionButton(title: "Next Episode", icon: "forward.end.fill", prominent: true, slot: .infoNext) {
                            actions.playNextEpisode()
                        }
                    }
                }
                .focusSection()
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
                .focusSection()
            }
            .frame(height: thumbHeight, alignment: .topTrailing)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(contentPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PanelGlassBackground(cornerRadius: PlozzTheme.Metrics.playerPanelCornerRadius))
    }

    private func infoThumbnail(cornerRadius: CGFloat, height: CGFloat) -> some View {
        Color.clear
            .frame(width: height * 16.0 / 9.0, height: height)
            .overlay {
                FallbackAsyncImage(urls: model.artworkURLs, variant: .landscapeCard) {
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
        title: String,
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
