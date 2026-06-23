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
                        // Direct focus to the resume-target card when focus first
                        // enters the row (e.g. pressing down from Play), instead of
                        // the geometrically-nearest one.
                        .modifier(DefaultFocusModifier(focusedID: $focusedID, targetID: defaultFocusID))
                    }
                    // Let a focused card's lift, drop shadow and border render
                    // outside the rail's bounds instead of being clipped.
                    .scrollClipDisabled()
                    .onAppear { applyInitialFocus(using: proxy) }
                    .onChange(of: focusedID) { _, newValue in
                        guard let onFocusChange else { return }
                        onFocusChange(items.first { $0.id == newValue })
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
            card.focused($focusedID, equals: item.id)
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

/// Applies `.defaultFocus` to a row only when a target id is provided, so the
/// row can direct entry focus to a specific card (e.g. the resume episode)
/// without affecting rows that don't set one.
private struct DefaultFocusModifier: ViewModifier {
    let focusedID: FocusState<String?>.Binding
    let targetID: String?

    func body(content: Content) -> some View {
        if let targetID {
            content.defaultFocus(focusedID, targetID)
        } else {
            content
        }
    }
}

#endif
