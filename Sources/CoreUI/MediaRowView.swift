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
    /// Called whenever focus moves onto a card (with that item) or off the row
    /// entirely (`nil`). Used by series detail to mirror the focused episode into
    /// the page hero. When set, every card becomes individually focus-tracked.
    private let onFocusChange: ((MediaItem?) -> Void)?

    @FocusState private var focusedID: String?
    @State private var didApplyInitialFocus = false
    /// Whether focus currently sits inside this row. Used to redirect focus to the
    /// came-in episode exactly once per entry: while `false` and a `defaultFocusID`
    /// is set, the first card focus lands on (whatever tvOS picks geometrically) is
    /// overridden by moving focus to the target. Resets when focus leaves the row.
    @State private var focusEngaged = false
    /// Pending "focus left the row" work, deferred briefly so a transient `nil`
    /// while moving between cards during fast navigation doesn't re-arm the gate
    /// (which would disable cards and yank the scroll back to the target mid-browse).
    @State private var pendingDisengage: DispatchWorkItem?

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

    /// Whether the row restricts entry focus to a single target card — only when a
    /// `defaultFocusID` is set *and* it exists in the row. We keep that card
    /// scrolled into view whenever the row isn't engaged (see `handleFocusChange`
    /// / `onChange(of: defaultFocusID)`), so it's always realised in the lazy stack
    /// and the row never becomes unreachable while the others are disabled.
    private var gatesFocus: Bool {
        guard let defaultFocusID else { return false }
        return items.contains { $0.id == defaultFocusID }
    }

    /// While the row is gated and not yet engaged, every card *except* the target
    /// is removed from the focus system, so focus entering the row can only ever
    /// land on the target — no transient highlight on the geometrically-nearest
    /// card. `PosterCardView` ignores `isEnabled`, so this affects focusability
    /// only, never appearance.
    private func cardIsDisabled(_ item: MediaItem) -> Bool {
        gatesFocus && !focusEngaged && item.id != defaultFocusID
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
                        // The target changed (e.g. switching seasons). Re-arm the
                        // gate and bring the new target into view so it's realised
                        // and remains the only focusable card on the next entry.
                        focusEngaged = false
                        guard let newTarget, items.contains(where: { $0.id == newTarget }) else { return }
                        proxy.scrollTo(newTarget, anchor: .leading)
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
        if tracksFocus {
            card
                .focused($focusedID, equals: item.id)
                .disabled(cardIsDisabled(item))
        } else {
            card
        }
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
            proxy.scrollTo(target, anchor: .leading)
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
            DispatchQueue.main.async { proxy.scrollTo(target, anchor: .leading) }
        }
    }

    /// Responds to focus moving onto a card (`newValue` non-nil) or off the row
    /// (`nil`). When focus *enters* the row and a `defaultFocusID` is set, the
    /// first card tvOS picks (the geometrically-nearest one) is overridden by
    /// moving focus to the target — the episode you came in on — so down-from-the
    /// season tabs always lands on the right episode regardless of geometry. Once
    /// engaged, normal left/right browsing is untouched; leaving the row re-arms it.
    private func handleFocusChange(to newValue: String?, using proxy: ScrollViewProxy) {
        guard let newValue else {
            // Focus appears to have left the row. Defer re-arming briefly: during
            // fast left/right navigation tvOS can drop focus to `nil` for a frame
            // between cards, and re-arming there would disable cards and snap the
            // scroll back to the target. If focus really left, the work runs; if it
            // returned, the non-nil branch below cancels it.
            let work = DispatchWorkItem {
                guard focusedID == nil else { return }
                focusEngaged = false
                // Bring the target back into view so it stays realised and is the
                // only focusable card next time — even after browsing far away.
                if let target = defaultFocusID, items.contains(where: { $0.id == target }) {
                    proxy.scrollTo(target, anchor: .leading)
                }
                onFocusChange?(nil)
            }
            pendingDisengage?.cancel()
            pendingDisengage = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            return
        }
        // Focus is on a card; cancel any pending disengage from a transient blip.
        pendingDisengage?.cancel()
        pendingDisengage = nil
        if !focusEngaged,
           let target = defaultFocusID,
           newValue != target,
           items.contains(where: { $0.id == target }) {
            // Safety net: if focus somehow lands on a non-target card while gated
            // (e.g. a frame before `.disabled` applied), redirect to the target and
            // don't report the transient card to the hero.
            focusEngaged = true
            redirectFocus(to: target, using: proxy)
            return
        }
        focusEngaged = true
        onFocusChange?(items.first { $0.id == newValue })
    }

    /// Scrolls the target card into view (realising it in the lazy stack if needed)
    /// then moves focus onto it a runloop tick later, once it exists.
    private func redirectFocus(to target: String, using proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(target, anchor: .leading)
        }
        DispatchQueue.main.async { focusedID = target }
    }
}

#endif
