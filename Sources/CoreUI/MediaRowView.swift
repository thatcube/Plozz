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
    /// Tracks whether focus has settled inside this row. While `false` and a
    /// `defaultFocusID` is set, every *other* card is non-focusable, so focus
    /// entering the row (from Play or the season tabs above) can only land on the
    /// target card — no geometric guessing, no visible snap. Once focus lands it
    /// flips `true`, re-enabling the whole row for free left/right browsing, and
    /// resets to `false` when focus leaves so the next entry re-targets.
    @State private var focusEngaged = false

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

    /// Whether the row restricts entry focus to a single target card. Only when a
    /// `defaultFocusID` is set *and* it actually exists in the row.
    private var gatesFocus: Bool {
        guard let defaultFocusID else { return false }
        return items.contains { $0.id == defaultFocusID }
    }

    /// Whether `item` may receive focus right now: always once focus has engaged
    /// the row, otherwise only the target card (so entry lands deterministically
    /// on it). Rows without gating leave every card focusable as before.
    private func isFocusable(_ item: MediaItem) -> Bool {
        !gatesFocus || focusEngaged || item.id == defaultFocusID
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
                    }
                    // Let a focused card's lift, drop shadow and border render
                    // outside the rail's bounds instead of being clipped.
                    .scrollClipDisabled()
                    .onAppear { applyInitialFocus(using: proxy) }
                    .onChange(of: focusedID) { _, newValue in
                        // Engage the row the moment focus lands inside it; release
                        // when focus leaves so re-entry re-targets the default card.
                        if gatesFocus { focusEngaged = newValue != nil }
                        onFocusChange?(items.first { $0.id == newValue })
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
                // Gate non-target cards out of the focus system until the row is
                // engaged. These cards aren't `Button`s and draw no enabled/
                // disabled styling, so this only affects focusability — no dimming.
                .disabled(!isFocusable(item))
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
}

#endif
