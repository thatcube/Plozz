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
    /// Leading inset for the row's title and first card. Defaults to the standard
    /// screen padding (Home rows); detail pages pass the larger hero leading
    /// padding so the row aligns with the hero text above it.
    private let leadingInset: CGFloat
    private let onSelect: (MediaItem) -> Void
    /// Called whenever focus moves onto a card (with that item). Used by series
    /// detail to mirror the focused episode into the page hero. When set, every
    /// card becomes individually focus-tracked.
    private let onFocusChange: ((MediaItem?) -> Void)?

    @FocusState private var focusedID: String?
    @State private var didApplyInitialFocus = false
    /// Whether focus currently sits inside this row. While `false` and a gate
    /// target is set, the first card focus lands on (whatever tvOS picks
    /// geometrically) is overridden by moving focus to the target. It is re-armed
    /// whenever focus genuinely *leaves* the row (debounced via `pendingDisengage`
    /// so transient mid-browse `nil`s don't churn it) and when the supplied
    /// `defaultFocusID` changes (e.g. season swap).
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
    /// Pending "focus left the row" work, deferred briefly so a transient `nil`
    /// reported while moving between cards during a rapid hold doesn't re-arm the
    /// gate (which would disable cards mid-browse and strand the focus indicator).
    /// If focus returns to a card before it fires, the non-nil branch cancels it.
    @State private var pendingDisengage: DispatchWorkItem?
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
        self.leadingInset = leadingInset
        self.onFocusChange = onFocusChange
        self.onSelect = onSelect
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
        if let lastFocusedID, items.contains(where: { $0.id == lastFocusedID }) {
            return lastFocusedID
        }
        guard let defaultFocusID, items.contains(where: { $0.id == defaultFocusID }) else { return nil }
        return defaultFocusID
    }

    /// Whether the row restricts entry focus to a single target card — only when a
    /// `gateTarget` is set *and* it exists in the row. We keep that card scrolled
    /// into view whenever the row isn't engaged (see `handleFocusChange` /
    /// `onChange(of: defaultFocusID)`), so it's always realised in the lazy stack
    /// and the row never becomes unreachable while the others are disabled.
    private var gatesFocus: Bool {
        guard let gateTarget else { return false }
        return items.contains { $0.id == gateTarget }
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
            VStack(alignment: .leading, spacing: 16) {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 32, weight: .bold))
                        .padding(.leading, leadingInset)
                }

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: PlozzTheme.Metrics.cardSpacing) {
                            ForEach(items) { item in
                                card(for: item)
                            }
                        }
                        .padding(.leading, leadingInset)
                        .padding(.trailing, PlozzTheme.Metrics.screenPadding)
                        // Give the focused card's lift + drop shadow room so it is
                        // never clipped by the scroll view's bounds.
                        .padding(.top, 16)
                        .padding(.bottom, PlozzTheme.Metrics.railVerticalPadding)
                        // Treat the rail as a single focus section so pressing down
                        // *enters the section* and selects its only focusable card
                        // (the gated target) regardless of horizontal alignment with
                        // the season tab above — without this, a target parked far to
                        // the right falls outside tvOS's downward search and the row
                        // becomes unreachable.
                        .focusSection()
                    }
                    // Let a focused card's lift, drop shadow and border render
                    // outside the rail's bounds instead of being clipped.
                    .scrollClipDisabled()
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
                        guard let newTarget, items.contains(where: { $0.id == newTarget }) else { return }
                        scrollToIfNeeded(newTarget, using: proxy)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func card(for item: MediaItem) -> some View {
        // Poster cards are flexible-width (they stretch to fill a grid column);
        // in a horizontal rail we pin them to the standard poster width so the
        // row lays out consistently. Landscape cards keep their intrinsic size.
        // Pin every card to a known width so a `LazyHStack` can compute the
        // offset of a far-off initial-focus target (e.g. episode 132 of a long
        // season) without first realising every card in between — which is what
        // made focusing the "next up" episode lag on huge seasons.
        let card = PosterCardView(item: item, style: style, spoilerSettings: spoilerSettings) { onSelect(item) }
            .frame(width: style == .poster ? PlozzTheme.Metrics.posterWidth : PlozzTheme.Metrics.landscapeWidth)
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

    /// Warms the decoded-image cache for a forward window of cards starting at the
    /// one that just appeared, so artwork is already resolved by the time each
    /// scrolls into view — eliminating the gray placeholder flash during a rapid
    /// RIGHT hold. Each card schedules its window at most once; the cache itself
    /// skips URLs already resident or in flight, so this stays cheap. Decoding runs
    /// off the main thread, so it never stutters the scroll.
    private func prefetchArtwork(ahead item: MediaItem) {
        #if canImport(UIKit)
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let lookahead = 8
        let upper = min(index + lookahead, items.count - 1)
        guard index <= upper else { return }
        for i in index...upper {
            let candidate = items[i]
            guard !prefetchedIDs.contains(candidate.id) else { continue }
            prefetchedIDs.insert(candidate.id)
            if let url = candidate.artworkCandidates(for: style).first {
                ArtworkImageCache.shared.prefetch(url)
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
           items.contains(where: { $0.id == target }) {
            didApplyInitialFocus = true
            scrollToIfNeeded(target, using: proxy)
            DispatchQueue.main.async { focusedID = target }
            return
        }
        if let target = initialScrollID,
           !didApplyInitialFocus,
           items.contains(where: { $0.id == target }) {
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
        guard let newValue else {
            // Focus appears to have left the row. Defer re-arming briefly: during a
            // rapid left/right hold tvOS can drop focus to `nil` for a frame between
            // cards, and re-arming there would disable cards and yank the scroll back
            // mid-browse. If focus really left (e.g. up to the season bar) the work
            // runs and re-arms the gate to the last-focused card; if focus returned,
            // the non-nil branch below cancels it.
            scheduleDisengage(using: proxy)
            return
        }
        // Focus is on a card; cancel any pending disengage from a transient blip and
        // remember it as the gate's next re-entry target.
        pendingDisengage?.cancel()
        pendingDisengage = nil
        lastFocusedID = newValue
        if !focusEngaged,
           let target = gateTarget,
           newValue != target,
           items.contains(where: { $0.id == target }) {
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

    /// Debounced re-arm of the entry gate once focus genuinely leaves the row.
    /// Keeps the (last-focused) gate target realised and in view for the next
    /// entry, but only scrolls when it isn't already visible so an up/down
    /// round-trip to an on-screen card never snap-scrolls the rail.
    private func scheduleDisengage(using proxy: ScrollViewProxy) {
        guard gatesFocus else { return }
        pendingDisengage?.cancel()
        let work = DispatchWorkItem {
            guard focusedID == nil else { return }
            focusEngaged = false
            if let target = gateTarget { scrollToIfNeeded(target, using: proxy) }
        }
        pendingDisengage = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Coalesces hero updates: each focus change schedules a deferred report and
    /// cancels the previous one, so blasting RIGHT through a long season rebuilds
    /// the hero once — when focus settles — instead of once per card passed.
    private func scheduleFocusReport(for id: String) {
        guard let onFocusChange else { return }
        let item = items.first { $0.id == id }
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

#endif
