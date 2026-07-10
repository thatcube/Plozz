#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A horizontally-scrolling, focusable row of media cards with a title.
/// Reused by Home (Continue Watching, Latest) and detail (episodes, related).
public struct MediaRowView: View {
    private let title: String
    private let items: [MediaItem]
    private let style: PosterCardView.Style
    private let spoilerSettings: SpoilerSettings
    /// When set, the row scrolls to and moves focus onto the matching item the
    /// first time it appears (used by series/season detail to surface the
    /// "next up" episode). `nil` keeps the platform's default focus behaviour.
    private let initialFocusID: String?
    /// When set, the row scrolls so the matching item is leading-aligned the first
    /// time it appears, **without** moving focus onto it. Used when focus should
    /// stay elsewhere (e.g. the hero's Play button) while the row is still
    /// pre-positioned at a chosen episode. Ignored when `initialFocusID` is set.
    private let initialScrollID: String?
    /// When set, the matching item becomes the row's *default focus* — the card
    /// focus lands on when focus first moves **into** the row from outside (e.g.
    /// pressing down from the hero Play button), regardless of which card is
    /// geometrically nearest. Used so the episode the Play button resumes is the
    /// one focused on entry, even when it's far down a long season.
    private let defaultFocusID: String?
    /// Bumped by the parent whenever focus moves to a sibling control *above* the
    /// row (e.g. the season tab bar). This is the deterministic signal that focus
    /// has genuinely left the row, so the entry gate re-arms *only* here — never by
    /// inferring "focus left" from a transient `nil`, which a fast horizontal hold
    /// produces constantly (the focused card is recycled between frames) and which
    /// would otherwise disable cards mid-browse and strand the focus indicator.
    private let focusResetToken: Int
    /// Leading inset for the row's title and first card. Defaults to the standard
    /// screen padding (Home rows); detail pages pass the larger hero leading
    /// padding so the row aligns with the hero text above it.
    private let leadingInset: CGFloat
    private let onSelect: (MediaItem) -> Void
    /// Called whenever focus moves onto a card (with that item). Used by series
    /// detail to mirror the focused episode into the page hero. When set, every
    /// card becomes individually focus-tracked.
    private let onFocusChange: ((MediaItem?) -> Void)?
    /// Stable lookup tables so focus/prefetch hot paths avoid repeated linear scans.
    private let itemIDSet: Set<String>
    private let itemIndexByID: [String: Int]
    private let itemByID: [String: MediaItem]

    @FocusState private var focusedID: String?
    @Environment(\.plozzMetrics) private var metrics
    @State private var didApplyInitialFocus = false
    /// Whether focus currently sits inside this row. While `false` and a gate
    /// target is set, the first card focus lands on (whatever tvOS picks
    /// geometrically) is overridden by moving focus to the target. It is re-armed
    /// when focus genuinely leaves the row (signalled by `focusResetToken`, e.g.
    /// going up to the season bar) and when the supplied `defaultFocusID` changes
    /// (e.g. season swap) — never from a transient mid-scroll `nil`.
    @State private var focusEngaged = false
    /// Card ids currently realised in the lazy stack. Used to avoid redundant
    /// `scrollTo` work that can cause visible snap/jump when the target is already
    /// on screen.
    @State private var visibleIDs: Set<String> = []
    /// Coalesces focus-change reporting to `onFocusChange` (the page hero). Holding
    /// RIGHT moves focus through many cards per second; without coalescing the hero
    /// would fully rebuild + cross-fade on each one, stuttering the scroll. We defer
    /// the report a beat and only fire for the card focus actually settles on.
    @State private var pendingReport: DispatchWorkItem?
    /// The card focus last settled on inside this row, remembered after focus
    /// leaves so the gate re-targets where the user actually was — not the
    /// came-in/resume episode. A stale id from another season is ignored because it
    /// won't exist in the current `items`.
    @State private var lastFocusedID: String?
    /// Items whose artwork has already been queued for prefetch, so each card's
    /// `onAppear` only ever schedules its forward window once.
    @State private var prefetchedIDs: Set<String> = []

    public init(
        title: String,
        items: [MediaItem],
        style: PosterCardView.Style = .poster,
        spoilerSettings: SpoilerSettings = .default,
        initialFocusID: String? = nil,
        initialScrollID: String? = nil,
        defaultFocusID: String? = nil,
        focusResetToken: Int = 0,
        leadingInset: CGFloat = PlozzTheme.Metrics.screenPadding,
        onFocusChange: ((MediaItem?) -> Void)? = nil,
        onSelect: @escaping (MediaItem) -> Void
    ) {
        self.title = title
        self.items = items
        self.style = style
        self.spoilerSettings = spoilerSettings
        self.initialFocusID = initialFocusID
        self.initialScrollID = initialScrollID
        self.defaultFocusID = defaultFocusID
        self.focusResetToken = focusResetToken
        self.leadingInset = leadingInset
        self.onFocusChange = onFocusChange
        self.onSelect = onSelect
        self.itemIDSet = Set(items.map(\.id))
        var indexByID: [String: Int] = [:]
        var byID: [String: MediaItem] = [:]
        for (offset, item) in items.enumerated() {
            if indexByID[item.id] == nil { indexByID[item.id] = offset }
            byID[item.id] = item
        }
        self.itemIndexByID = indexByID
        self.itemByID = byID
    }

    /// Whether each card needs an individual focus binding installed — required
    /// to drive initial/default focus and to report focus changes to the hero.
    private var tracksFocus: Bool {
        initialFocusID != nil || onFocusChange != nil || defaultFocusID != nil
    }

    /// The card the entry gate targets: the card focus last settled on in this row
    /// once the user has browsed (`lastFocusedID`), otherwise the externally
    /// supplied `defaultFocusID` (the resume/came-in episode). This is what makes
    /// re-entry land on the episode you were last looking at, not the one you
    /// arrived on. A stale `lastFocusedID` from another season is ignored because
    /// it won't be present in the current `items`.
    private var gateTarget: String? {
        if let lastFocusedID, itemIDSet.contains(lastFocusedID) {
            return lastFocusedID
        }
        guard let defaultFocusID, itemIDSet.contains(defaultFocusID) else { return nil }
        return defaultFocusID
    }

    /// Whether the row restricts entry focus to a single target card — only when a
    /// `gateTarget` is set *and* it exists in the row. We keep that card scrolled
    /// into view whenever the row isn't engaged (see `handleFocusChange` /
    /// `onChange(of: defaultFocusID)`), so it's always realised in the lazy stack
    /// and the row never becomes unreachable while the others are disabled.
    private var gatesFocus: Bool {
        guard let gateTarget else { return false }
        return itemIDSet.contains(gateTarget)
    }

    /// While the row is gated and not yet engaged, every card *except* the target
    /// is removed from the focus system, so focus entering the row can only ever
    /// land on the target — no transient highlight on the geometrically-nearest
    /// card. `PosterCardView` ignores `isEnabled`, so this affects focusability
    /// only, never appearance.
    private func cardIsDisabled(_ item: MediaItem) -> Bool {
        gatesFocus && !focusEngaged && item.id != gateTarget
    }

    public var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: metrics.sectionTitleSpacing) {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: metrics.sectionHeaderFontSize, weight: .bold))
                        .padding(.leading, leadingInset)
                }

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: metrics.cardSpacing) {
                            ForEach(items) { item in
                                card(for: item)
                            }
                        }
                        .padding(.leading, leadingInset)
                        .padding(.trailing, PlozzTheme.Metrics.screenPadding)
                        // Reserve generous vertical room *inside* the clip so a
                        // focused card's lift + drop shadow are never cut. The rail
                        // keeps clipping (no `scrollClipDisabled`) — that's what
                        // keeps the focus engine's edge math correct so the first/
                        // last card holds its inset instead of being yanked flush to
                        // the screen. The negative outer padding below cancels this
                        // clearance in layout, so the row's height and its gap to the
                        // neighbouring rows are unchanged; only the clip grows.
                        .padding(.vertical, metrics.railShadowClearance)
                    }
                    .padding(.top, metrics.railTopClearanceOffset)
                    .padding(.bottom, metrics.railBottomClearanceOffset)
                    // Section the whole rail VIEWPORT (the full-width horizontal
                    // ScrollView) — NOT the scrolled inner LazyHStack — but ONLY for
                    // the gated single-target flow (the episode rail). tvOS only enters
                    // a focus section if part of its FRAME sits in the swipe's path, and
                    // then forwards focus to the section's sole enabled focusable
                    // regardless of where that card is scrolled. On the inner LazyHStack
                    // the section only spanned the scrolled/visible cards, so pressing
                    // DOWN from a horizontally-distant season chip found no rail geometry
                    // in its corridor and either missed the target (landing on the cast
                    // avatar below) or didn't move at all when the target was scrolled to
                    // the opposite side. At the ScrollView level the section is the full,
                    // static viewport width — directly below the season bar for every
                    // chip position — so DOWN reliably reaches the gated target wherever
                    // it sits (last far-right, first far-left, or middle), with no
                    // repositioning. This mirrors the season bar's own ScrollView-level
                    // `.focusSection()` (which makes UP work the same way) and the hero
                    // action row (commit eddd937e). Ordinary rows (Home, detail children —
                    // `tracksFocus == false`) stay UNsectioned so vertical navigation
                    // keeps tvOS's column-aligned X-projection (the "focus jumps to the
                    // opposite side" bug, commit f812fe64).
                    .focusSectionIf(tracksFocus)
                    .onAppear { applyInitialFocus(using: proxy) }
                    .onChange(of: focusedID) { _, newValue in
                        handleFocusChange(to: newValue, using: proxy)
                    }
                    .onChange(of: defaultFocusID) { _, newTarget in
                        // The supplied target changed (e.g. switching seasons). Drop
                        // any remembered focus from the previous set, re-arm the gate
                        // and bring the new target into view only when needed so it's
                        // realised and is
                        // the only focusable card on the next entry.
                        focusEngaged = false
                        lastFocusedID = nil
                        guard let newTarget, itemIDSet.contains(newTarget) else { return }
                        scrollToIfNeeded(newTarget, using: proxy)
                    }
                    .onChange(of: focusResetToken) { _, _ in
                        // Focus genuinely left the row for a sibling above (the season
                        // bar told us). Re-arm the entry gate so the next down-press
                        // lands on the episode you were last on (`lastFocusedID`, kept
                        // so re-entry returns there — not the came-in episode), and
                        // make sure it's realised/in view for the gate to target.
                        focusEngaged = false
                        if let target = gateTarget { scrollToIfNeeded(target, using: proxy) }
                    }
                }
                .onDisappear {
                    pendingReport?.cancel()
                    pendingReport = nil
                }
            }
        }
    }

    @ViewBuilder
    private func card(for item: MediaItem) -> some View {
        // Pin every card to its true rendered width so a `LazyHStack` can compute
        // the offset of a far-off initial-focus target (e.g. episode 132 of a long
        // season) without first realising every card in between — which is what
        // made focusing the "next up" episode lag on huge seasons.
        //
        // The pinned width must equal the card's *glass surface* width, not just
        // its artwork width, or the layout slot is narrower than what's drawn and
        // the surfaces overhang into the inter-card gap. A poster's artwork is
        // flexible, so its glass equals `posterWidth`. A landscape card's artwork
        // is fixed and sits inside a `cardInset` glass margin, so its glass
        // is `landscapeWidth + 2 * cardInset` — pin to that so `cardSpacing`
        // is a real gap and adjacent cards never overlap at rest.
        let card = PosterCardView(item: item, style: style, spoilerSettings: spoilerSettings) { onSelect(item) }
            .frame(width: cardSlotWidth)
            .id(item.id)
            .onAppear {
                visibleIDs.insert(item.id)
                prefetchArtwork(ahead: item)
            }
            .onDisappear { visibleIDs.remove(item.id) }
        if tracksFocus {
            card
                .focused($focusedID, equals: item.id)
                .disabled(cardIsDisabled(item))
        } else {
            card
        }
    }

    /// The layout width reserved for one card in the rail — its full glass-surface
    /// width, so `cardSpacing` lands as a true visible gap between cards.
    private var cardSlotWidth: CGFloat {
        switch style {
        case .poster:
            return metrics.posterWidth
        case .landscape:
            return metrics.landscapeCardSlotWidth
        }
    }

    /// Warms the decoded-image cache for a forward window of cards starting at the
    /// one that just appeared, so artwork is already resolved by the time each
    /// scrolls into view — eliminating the gray placeholder flash during a rapid
    /// RIGHT hold. Each card schedules its window at most once; the cache itself
    /// skips URLs already resident or in flight, so this stays cheap. Decoding runs
    /// off the main thread, so it never stutters the scroll.
    private func prefetchArtwork(ahead item: MediaItem) {
        #if canImport(UIKit)
        guard let index = itemIndexByID[item.id] else { return }
        let lookahead = 8
        let upper = min(index + lookahead, items.count - 1)
        guard index <= upper else { return }
        let variant: ArtworkImageVariant = {
            switch style {
            case .poster: return .posterCard
            case .landscape: return .landscapeCard
            }
        }()
        for i in index...upper {
            let candidate = items[i]
            guard !prefetchedIDs.contains(candidate.id) else { continue }
            prefetchedIDs.insert(candidate.id)
            for url in candidate.artworkCandidates(for: style).prefix(2) {
                ArtworkImageCache.shared.prefetch(url, variant: variant)
            }
        }
        #endif
    }

    /// Scrolls to and focuses `initialFocusID`, or — when only `initialScrollID`
    /// is set — scrolls to the target without moving focus onto it. Runs exactly
    /// once, after the row first lays out. The focus assignment is deferred a
    /// runloop tick so SwiftUI has installed the focusable cards before we move
    /// focus onto one.
    private func applyInitialFocus(using proxy: ScrollViewProxy) {
        if let target = initialFocusID,
           !didApplyInitialFocus,
           itemIDSet.contains(target) {
            didApplyInitialFocus = true
            scrollToIfNeeded(target, using: proxy)
            DispatchQueue.main.async { focusedID = target }
            return
        }
        if let target = initialScrollID,
           !didApplyInitialFocus,
           itemIDSet.contains(target) {
            didApplyInitialFocus = true
            // Defer a tick so the LazyHStack has realised enough cards to compute
            // the target's offset before we scroll; focus is deliberately left
            // wherever it currently is (typically the hero Play button).
            DispatchQueue.main.async { scrollToIfNeeded(target, using: proxy) }
        }
    }

    /// Responds to focus moving onto a card (`newValue` non-nil) or off the row
    /// (`nil`). When focus *enters* the row and a gate target is set, the first
    /// card tvOS picks (the geometrically-nearest one) is overridden by moving
    /// focus to the target — the episode you came in on, or the one you last
    /// looked at — so down-from-the season tabs always lands on the right episode
    /// regardless of geometry. Once engaged, normal left/right browsing is
    /// untouched; leaving the row (debounced) re-arms entry targeting on the card
    /// you were last on.
    private func handleFocusChange(to newValue: String?, using proxy: ScrollViewProxy) {
        // A fast horizontal hold constantly blips focus to `nil` between cards (the
        // focused card is recycled out of the lazy stack for a frame). Ignore it
        // entirely: re-arming here is what used to disable every card mid-scroll and
        // strand the focus indicator. The gate now re-arms only on `focusResetToken`
        // (focus actually left the row, up to the season bar).
        guard let newValue else { return }
        lastFocusedID = newValue
        if !focusEngaged,
           let target = gateTarget,
           newValue != target,
           itemIDSet.contains(target) {
            // Safety net: if focus somehow lands on a non-target card while gated
            // (e.g. a frame before `.disabled` applied), redirect to the target and
            // don't report the transient card to the hero.
            focusEngaged = true
            lastFocusedID = target
            redirectFocus(to: target, using: proxy)
            return
        }
        focusEngaged = true
        scheduleFocusReport(for: newValue)
    }

    /// Coalesces hero updates: each focus change schedules a deferred report and
    /// cancels the previous one, so blasting RIGHT through a long season rebuilds
    /// the hero once — when focus settles — instead of once per card passed.
    private func scheduleFocusReport(for id: String) {
        guard let onFocusChange else { return }
        let item = itemByID[id]
        pendingReport?.cancel()
        let work = DispatchWorkItem {
            // Only report the card focus actually settled on, skipping every card
            // blown past during a rapid hold.
            guard focusedID == id else { return }
            onFocusChange(item)
        }
        pendingReport = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Scrolls the target card into view (realising it in the lazy stack if needed)
    /// then moves focus onto it a runloop tick later, once it exists.
    private func redirectFocus(to target: String, using proxy: ScrollViewProxy) {
        scrollToIfNeeded(target, using: proxy, animated: true)
        DispatchQueue.main.async { focusedID = target }
    }

    /// Avoids unnecessary `scrollTo` calls when the target is already realised and
    /// visible in the row, eliminating jumpy re-entry and extra layout churn.
    private func scrollToIfNeeded(
        _ target: String,
        using proxy: ScrollViewProxy,
        anchor: UnitPoint = .leading,
        animated: Bool = false
    ) {
        guard !visibleIDs.contains(target) else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(target, anchor: anchor)
            }
        } else {
            proxy.scrollTo(target, anchor: anchor)
        }
    }
}

private extension View {
    /// Applies `.focusSection()` only when `enabled`. Used so the gated episode
    /// rail keeps its single-section entry behavior while ordinary rows stay plain
    /// focusable scrollers whose vertical navigation is column-aligned by tvOS's
    /// geometric X-projection (no per-section last-focus memory).
    @ViewBuilder
    func focusSectionIf(_ enabled: Bool) -> some View {
        if enabled {
            focusSection()
        } else {
            self
        }
    }
}

#endif
