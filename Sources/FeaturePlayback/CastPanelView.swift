#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreUI
import CoreModels

/// The Cast tab's card: a row of the people on screen.
///
/// Answers "who is that", and — on Select — a little about them, without ever
/// leaving the film. Both levels live in this one card: the row is replaced in
/// place by a person's details, exactly as the Subtitles panel drills between its
/// own screens, rather than growing the card or pushing a new one. The card is a
/// fixed stage that the reveal transform moves as a unit, so anything that
/// changed its height would make the whole transport jump.
struct CastPanelView: View {
    let model: PlayerControlsModel
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    /// The person shown in detail, or `nil` for the row. Owned by
    /// `PlayerControls` so Back and focus restoration stay with the rest of the
    /// panel choreography.
    @Binding var detailPerson: MediaPerson?

    /// Set by `PlayerControls` when Menu is pressed, so the remote's Back runs
    /// the SAME close as the on-screen button.
    ///
    /// Menu used to clear `detailPerson` directly, which skipped the shrink
    /// entirely — the pane simply vanished — and skipped the focus narrowing
    /// with it, leaving the row disabled except for one face. A binding rather
    /// than a callback because the request has to survive the view being
    /// re-created.
    @Binding var closeRequest: Int
    /// Whether the card this panel fills is open.
    ///
    /// Used to shed the row's glass BEFORE the card parks. Every face wears a
    /// live `glassEffect`, so translating the row off-screen means moving ~20
    /// backdrop blurs over Dolby Vision video — the same per-frame offscreen
    /// cost this player already refuses to pay for shadows, and why leaving from
    /// Cast stuttered while leaving from Info did not, despite identical code.
    ///
    /// Costs nothing visually: this panel draws no surface of its own, so once
    /// its cards go there is nothing left to watch travel.
    ///
    /// Handled HERE rather than by the card, so the fade is scoped to this
    /// subtree — an animation modifier at cluster level retimes the whole
    /// reveal, which is exactly what it did to the Info card when I tried it
    /// there.
    let isCardOpen: Bool
    /// The clock the card travels on, so anything this panel does while it parks
    /// happens as part of that one movement rather than on a timer of its own.
    let revealClock: Animation

    /// Enough faces to answer the question, few enough that the row stays a
    /// glance rather than a browse.
    private static let maximumFaces = 20

    /// Which face was opened, so Back returns to it rather than to the start of
    /// the row.
    @State private var lastOpenedIndex = 0
    /// Whether the detail has grown to fill the stage. Drives the whole drill.
    @State private var isExpanded = false
    /// While returning, the ONLY face allowed in the focus order.
    ///
    /// Removing the detail leaves the engine to pick a face for itself — usually
    /// not the one that was opened — so it scrolled to that card, and the
    /// correction then scrolled again to the right one. Two scroll-into-view
    /// passes, seen as a nudge. Narrowing the order to a single candidate means
    /// the engine's only legal choice IS the right one, so there is no first
    /// landing to correct. The same device as `entryFocusTarget` in
    /// `PlayerControls`, which exists for exactly this reason during a Down
    /// entry.
    @State private var restoringToIndex: Int?
    /// Each face card's frame in the panel's space, keyed by person id.
    @State private var cardFrames: [String: CGRect] = [:]
    /// The stage's own size, so a card's frame can be expressed as a fraction.
    @State private var panelSize: CGSize = .zero

    /// Ties the row's card to the detail it becomes. Without it the drill-in was
    /// two unrelated events — a row vanishing and a panel appearing — which left
    /// the viewer to work out for themselves that the panel was about the face
    /// they had just chosen.
    /// The drill's clock. Same family as the card's own reveal, quicker: this is
    /// one surface growing, not the whole cluster arriving.
    ///
    /// Not private: `PlayerControls.handleExit` reverses this same drill when
    /// Menu is pressed, and the two directions have to run on one clock.
    static let drill: Animation = .smooth(duration: 0.38)

    private static func faceID(_ person: MediaPerson) -> String { "cast.face.\(person.id)" }

    private var people: [MediaPerson] {
        Array(model.infoCard.cast.prefix(Self.maximumFaces))
    }

    var body: some View {
        // The row is NEVER torn down. The detail is laid over it and the drill
        // is animated by hand, from the chosen card's measured frame.
        //
        // This began as a `matchedGeometryEffect` between two views swapped in a
        // `Group`, which animates beautifully but REQUIRES that only one exist at
        // a time — and destroying the row cost three things at once: its scroll
        // offset (so it visibly scrolled back), its focus target (so focus
        // flashed onto the Info tab before landing), and the close animation's
        // destination (so closing did not animate at all). Keeping it alive
        // fixes all three, and the transform below replaces what the matched
        // geometry was doing.
        ZStack(alignment: .topLeading) {
            faceRow
                // Keyed to the DRILL, not to the pane's existence.
                //
                // Tied to `detailPerson` the row could only change at the very
                // end of a close — after the pane had finished shrinking and been
                // removed — so the cast reappeared in one instant step. Keyed to
                // `isExpanded` it comes back WITH the shrink: the cards are
                // already rising as the pane collapses into the one being
                // returned to, which is what makes the two read as a single
                // movement.
                .opacity(isExpanded ? 0 : 1)
                // NO scale. Scaling the row moves every card horizontally, and
                // the further one sits from the leading anchor the further it
                // travels — so the row appeared to slide sideways as it landed,
                // visibly for a card near the end and not at all for the first.
                // The fade alone is the softening; the pane shrinking into the
                // card is what carries the movement.
                // Deliberately NOT `.disabled` here, on the scroll view.
                //
                // Disabling a scroll view whose content holds focus makes tvOS
                // reclaim its offset toward the leading edge — so every drill
                // gave back a little of the viewer's scroll position, drifting
                // the row towards the start a bit at a time. The faces are taken
                // out of the focus order individually instead (see the cards),
                // which leaves the scroll view itself untouched.
                .accessibilityHidden(detailPerson != nil)
                .animation(.easeOut(duration: 0.28), value: isExpanded)

            if let person = detailPerson {
                CastMemberDetail(
                    person: person,
                    loader: model.infoCard.castDetailLoader,
                    onOpenPage: model.infoCard.openPersonPage,
                    focus: $focus,
                    contentVisible: isExpanded,
                    isExpanded: isExpanded,
                    collapsedHeadshot: collapsedHeadshotFrame,
                    onBack: closeDetail
                )
                // A growing MASK, not a scale.
                //
                // Scaling the pane scaled everything in it, and since the card
                // and the stage have very different proportions the x and y
                // factors differ wildly — so the headshot and the text visibly
                // squashed on the way in and out. Masking leaves the pane at its
                // true size throughout and simply reveals more of it, which is
                // what "this card opening out" actually looks like.
                .mask(alignment: .topLeading) { revealMask }
            }
        }
        // Every card's frame in this panel's own space, so the drill knows where
        // to grow from and shrink back to.
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(CastCardFrameKey.self) { cardFrames = $0 }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { panelSize = geometry.size }
                    .onChange(of: geometry.size) { _, size in panelSize = size }
            }
        }
        .frame(height: InfoPanelView.cardHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: closeRequest) { _, _ in
            guard detailPerson != nil else { return }
            closeDetail()
        }
    }

    /// The panel's coordinate space, which card frames are reported in.
    static let space = "cast.panel"

    /// Out of the focus order while the detail covers the row, and — while
    /// returning — for every face except the one being returned to.
    private func isFaceDisabled(_ index: Int) -> Bool {
        if detailPerson != nil { return true }
        if let restoringToIndex { return index != restoringToIndex }
        return false
    }

    private var openedCardFrame: CGRect? {
        guard let person = detailPerson else { return nil }
        return cardFrames[person.id]
    }

    private var originOfOpenedCard: CGPoint {
        openedCardFrame?.origin ?? .zero
    }

    /// The window the pane is seen through: the chosen card's rectangle when
    /// collapsed, the whole stage when open.
    /// The chosen card's photo, in the panel's space — where the detail's
    /// headshot begins and ends its journey.
    private var collapsedHeadshotFrame: CGRect? {
        guard let card = openedCardFrame else { return nil }
        return CGRect(
            x: card.minX + CastFaceCard.headshotOrigin.x,
            y: card.minY + CastFaceCard.headshotOrigin.y,
            width: CastFaceCard.headshot,
            height: CastFaceCard.headshot
        )
    }

    private var revealMask: some View {
        let collapsed = openedCardFrame ?? CGRect(
            x: 0, y: 0,
            width: CastFaceCard.width,
            height: InfoPanelView.cardHeight
        )
        let radius = isExpanded
            ? PlozzTheme.Metrics.playerPanelCornerRadius
            : CastFaceCard.cornerRadius
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .frame(
                width: isExpanded ? panelSize.width : collapsed.width,
                height: isExpanded ? panelSize.height : collapsed.height
            )
            .offset(
                x: isExpanded ? 0 : collapsed.minX,
                y: isExpanded ? 0 : collapsed.minY
            )
    }

    private func openDetail(_ person: MediaPerson, at index: Int) {
        lastOpenedIndex = index
        // Placed collapsed first, then expanded on the next turn — a view cannot
        // animate from a state it was never in.
        detailPerson = person
        isExpanded = false
        Task { @MainActor in
            await Task.yield()
            withAnimation(Self.drill) { isExpanded = true }
            // Focus AFTER the pane exists. Assigning it in the same turn targets
            // a view that has not been built, so the assignment is dropped and
            // the engine — finding the row now disabled — parks on the Info tab.
            claimFocus(.castBack)
        }
    }

    private func closeDetail() {
        // Shrink back INTO the card, then remove. Removing first is what left
        // the close with nothing to animate.
        withAnimation(Self.drill) { isExpanded = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(340))
            // Only take focus back if it is still INSIDE the detail.
            //
            // Pressing Up out of a person's details moves focus to the tab and
            // asks for this close — and restoring unconditionally then dragged
            // focus straight back down onto a face, so the viewer's next Up
            // started from the row again and never reached the scrub bar. It
            // looked as though Up did nothing.
            let shouldRestoreFocus = Self.isInsideDetail(focus)
            if shouldRestoreFocus {
                // Narrow the focus order BEFORE the detail goes, so the engine
                // never has an alternative to choose in the first place.
                restoringToIndex = lastOpenedIndex
            }
            detailPerson = nil
            // The row is alive and re-enabled the moment this clears, so the
            // face is a real focus target immediately — no waiting for it to be
            // rebuilt, which is what used to make this unreliable.
            if shouldRestoreFocus {
                claimFocus(.castMember(lastOpenedIndex))
            }
        }
    }

    /// Whether a focus slot belongs to the person-detail pane.
    private static func isInsideDetail(_ slot: PlayerControls.FocusSlot?) -> Bool {
        switch slot {
        case .castBack, .castMore, .castCredit: return true
        default: return false
        }
    }

    /// Holds focus against the engine for a few turns.
    ///
    /// Removing the view that had focus makes the engine choose a replacement,
    /// and its pass runs AFTER whatever we assign in the same turn — so a single
    /// write loses, and even a second one can. Re-asserting briefly is what
    /// makes the outcome ours; a few turns is enough that the engine has settled
    /// and cheap enough to be invisible.
    private func claimFocus(_ target: PlayerControls.FocusSlot) {
        Task { @MainActor in
            // One write, then a correction only if it genuinely did not take.
            //
            // Writing twice unconditionally fired two scroll-into-view passes
            // and nudged the row on landing; writing once was unreliable and
            // sometimes left the wrong face focused. The middle ground is a
            // single write plus a check late enough to be TRUE — the earlier
            // check ran before the engine had published its result, so it always
            // read "not settled" and always wrote again, which is what made the
            // double scroll unconditional.
            focus = target
            try? await Task.sleep(for: .milliseconds(120))
            let tookFirstTime = focus == target
            if !tookFirstTime { focus = target }
            // Everyone back in the focus order once focus has landed, so
            // Left/Right work again immediately.
            restoringToIndex = nil
        }
    }

    private var faceRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // NOT lazy. A LazyHStack builds only what is on screen, and coming
            // back from a person's details rebuilds this row from offset zero —
            // so restoring focus to a face you had scrolled to targeted a view
            // that did not exist yet. With nothing to hold it, the focus engine
            // fell back to the nearest candidate, the Info tab. That is the
            // "Back sends me to Info" bug, and why it only happened after
            // scrolling. Capped at 20 faces, so building them all is cheap —
            // and the artwork loads lazily regardless.
            HStack(spacing: 20) {
                ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                    Button { openDetail(person, at: index) } label: {
                        CastFaceCard(
                            person: person,
                            focused: focus == .castMember(index)
                        )
                    }
                    // The same treatment as the Up Next card — the shared style
                    // for a card floating over live video, rather than the
                    // browsing-card glass, whose light fill changes the card's
                    // colour against arbitrary footage.
                    .buttonStyle(PlayerOverVideoCardStyle(
                        focused: focus == .castMember(index),
                        cornerRadius: CastFaceCard.cornerRadius,
                        focusScale: CastFaceCard.focusScale
                    ))
                    // Per-card, so the scroll view is never itself disabled.
                    .disabled(isFaceDisabled(index))
                    .focused($focus, equals: .castMember(index))
                    .id(Self.faceID(person))
                    // Its rectangle in the panel's space, so the drill can grow
                    // out of exactly this card and shrink back into it.
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: CastCardFrameKey.self,
                                value: [person.id: geometry.frame(in: .named(CastPanelView.space))]
                            )
                        }
                    }
                }
            }
            // No leading inset: the first card is a panel-level element, so its
            // edge is the panel's edge — flush with the Info tab above it. An
            // inset here made the row start indented from everything else in the
            // cluster.
            .padding(.trailing, InfoPanelView.contentPadding)
            // No vertical inset: a cast card stands in the Info panel's place, so
            // it has to be the Info panel's height. The inset that used to be here
            // was reserving room for the focus lift, which `scrollClipDisabled`
            // already allows — all it actually did was leave the cards short.
        }
        // The row runs the full width of the card. Clipping at the content inset
        // left the first and last cards visibly sliced while scrolling; the inset
        // above still holds them off the edge at rest.
        .scrollClipDisabled()
        // No `scrollPosition` binding. It existed to restore the offset across a
        // teardown that no longer happens — the row is never destroyed — and all
        // it did afterwards was re-centre a row that was already exactly where
        // the viewer left it, which is the small nudge on landing.
        // Put focus back on the face the viewer opened, now that it exists.
        //
        // Only when returning, never on first open: the cast tab is entered with
        // focus on its tab button, and claiming focus here would snatch it away
        // before the viewer had pressed anything.

    }
}

/// One person, as a card sized to fill the panel's height.
///
/// A card rather than a bare circle: it matches the weight of the Info panel it
/// swaps with, gives focus something substantial to land on, and leaves the
/// character name room to read from across a room.
private struct CastFaceCard: View {
    let person: MediaPerson
    let focused: Bool

    /// The headshot plus the space that has always sat either side of it, so
    /// enlarging the face widens the CARD rather than crowding it. Previously
    /// 190 and 128 were independent constants and the relationship between them
    /// was accidental; this keeps it at the 31pt it happened to be.
    static var width: CGFloat { headshot + headshotSideSpace * 2 }
    static let headshot: CGFloat = 160
    private static let headshotSideSpace: CGFloat = 31
    /// Where the circle sits inside the card, so the drill can start the
    /// detail's headshot exactly on top of it.
    static let headshotOrigin = CGPoint(x: headshotSideSpace, y: 18)
    /// The labels' own inset, which is narrower — they may run closer to the
    /// card's edge than the circle does.
    private static let inset: CGFloat = 12
    /// The full tvOS card lift. These are small cards in a row, where the gentle
    /// default barely registered.
    static let focusScale: CGFloat = 1.10
    /// How far the lift pushes each edge out, for anything that has to reason
    /// about where a focused card actually is.
    static let lift = CGSize(
        width: width * (focusScale - 1) / 2,
        height: InfoPanelView.cardHeight * (focusScale - 1) / 2
    )
    /// The panel's radius. These cards stand in the Info panel's place when the
    /// tab switches, so their corners have to be its corners — anything else
    /// makes the two tabs look like different surfaces.
    static let cornerRadius: CGFloat = PlozzTheme.Metrics.playerPanelCornerRadius

    var body: some View {
        VStack(spacing: 12) {
            avatar
                .frame(width: Self.headshot, height: Self.headshot)
                .clipShape(Circle())

            // Names are the one thing on this card that must be readable in
            // full, and a card this narrow truncates plenty of real ones. The
            // same marquee the subtitle list uses: truncated and feathered at
            // rest, scrolling the whole name once the card has focus.
            VStack(spacing: 3) {
                MarqueeText(
                    text: person.name,
                    font: .system(size: 21, weight: .semibold),
                    isFocused: focused,
                    restingAlignment: .center
                )
                .foregroundStyle(.white)
                if let role = person.role, !role.isEmpty {
                    MarqueeText(
                        text: role,
                        font: .system(size: 18),
                        isFocused: focused,
                        restingAlignment: .center
                    )
                    .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity)
            // The card's own 12pt is the whole inset. An extra one here narrowed
            // the label enough that names started scrolling well short of the
            // edge, with dead card either side of them.
        }
        .padding(.vertical, 18)
        .padding(.horizontal, Self.inset)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // Surface, lift and shadow all come from PlozzCardButtonStyle.
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = person.imageURL {
            FallbackAsyncImage(urls: [url], variant: .personHeadshot) { placeholder }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(.white.opacity(0.12))
            Text(verbatim: initials)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var initials: String {
        person.name.split(separator: " ").prefix(2)
            .compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// One person's details, filling the card in place of the row.
///
/// Deliberately terminal: it says who they are and stops. Anything leading
/// elsewhere would end the film, which is the one thing a glance mid-scene must
/// never do.
private struct CastMemberDetail: View {
    let person: MediaPerson
    let loader: PlayerCastDetailLoading?
    let onOpenPage: ((MediaPerson) -> Void)?
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    /// Whether the pane has finished growing, so its contents know when to fade
    /// themselves in — they must not appear while it is still travelling.
    let contentVisible: Bool
    /// Whether the pane has grown. The headshot travels on this.
    let isExpanded: Bool
    /// The face card's photo in the panel's space, so the headshot can start
    /// exactly on top of it and return to it.
    let collapsedHeadshot: CGRect?
    let onBack: () -> Void

    /// The pane's full height. A face is what the viewer came here to place, so
    /// it gets the same room the posters opposite it get. Still a circle, and
    /// deliberately: it has to morph from the circle on the face card without a
    /// shape change halfway.
    private static var headshot: CGFloat { contentHeight }
    /// Wide enough for a name beside the headshot and a biography that reads as
    /// prose beneath it. The artwork pays for every point of this, but the row
    /// scrolls and a truncated sentence does not.
    private static let identityWidth: CGFloat = 900
    /// The stage, less its inset. Everything in the pane is pinned to this: a
    /// column that exceeds it pushes the whole HStack past the frame that is
    /// meant to contain it, and the overflow is then split between the top and
    /// bottom — which is exactly what made the top inset look tighter than the
    /// bottom one.
    static var contentHeight: CGFloat {
        InfoPanelView.cardHeight - InfoPanelView.contentPadding * 2
    }
    /// Kept clear on the right for the Back button, which floats above the
    /// content rather than sitting in the row with it.
    /// Sized to the button itself (a `.body` chevron in 16pt of horizontal
    /// padding, ~61pt) plus a hair of clearance, so the row runs right up to it
    /// instead of stopping well short.
    private static let backButtonLane: CGFloat = 62

    /// How many lines of biography fit, derived from the budget rather than
    /// guessed at.
    ///
    /// The stage is a hard 210pt and the column must also hold the name and the
    /// "See more" chip; five lines needed 261 and simply overflowed, clipping
    /// the name at the top and the chip at the bottom. Three is what is left,
    /// and the chip is there precisely so a longer life story has somewhere to
    /// be read in full.
    private static var biographyLineLimit: Int {
        let budget = contentHeight
            - 41   // name
            - 12   // gap above the biography
            - 58   // "See more" chip and its gap
        return max(2, Int(budget / PlayerCardText.bodyLineHeight))
    }

    /// `nil` while the request is in flight, which is NOT the same as an empty
    /// result — an empty state shown during a load flashes "nothing known about
    /// them" at someone who is about to be told plenty.
    @State private var detail: PlayerCastDetail?

    var body: some View {
        // Identity in a column on the left, so whatever we know about them gets
        // the pane's FULL height rather than what is left under a name. With the
        // name above them, posters could only be 88pt wide — too small to
        // recognise from a sofa, which defeats the entire point of showing art.
        HStack(alignment: .top, spacing: 28) {
            identity
                // A focus SECTION, so Left from the Back button reaches the
                // "See more" chip.
                //
                // tvOS moves focus by searching in the pressed direction, and
                // with no credits the chip sits far to the left AND well below
                // Back — outside the corridor that search considers, so Left
                // found nothing at all. A section is reachable as a unit rather
                // than by the geometry of whatever is inside it.
                .plozzFocusSection()
                // Centred, not top-aligned. Beside a rail of full-height posters
                // a short text block pinned to the top left an obvious well of
                // empty card beneath it.
                .frame(height: Self.contentHeight, alignment: .leading)
                // Full width when there is nothing to sit beside, so the
                // biography can run properly instead of hugging one edge with
                // half the pane left empty.
                .frame(
                    width: hasCredits ? Self.identityWidth : nil,
                    alignment: .leading
                )
                .frame(maxWidth: hasCredits ? nil : .infinity, alignment: .leading)
                // Stop short of the Back button in the full-width case too.
                // With a poster rail beside it the rail reserved this lane; with
                // no credits the column takes the whole stage and ran straight
                // under the chevron.
                .padding(.trailing, hasCredits ? 0 : Self.backButtonLane)

            if hasCredits, let credits = detail?.credits {
                CastCreditsRow(items: credits, focus: $focus)
                .frame(maxWidth: .infinity)
                .opacity(contentVisible ? 1 : 0)
                // Stop short of the Back button. Without this the row ran under
                // it and a poster scrolled beneath the chevron.
                .padding(.trailing, Self.backButtonLane)
            }
        }
        .frame(height: Self.contentHeight, alignment: .topLeading)
        // Scoped to this subtree on purpose — see the loader below.
        .animation(.easeOut(duration: 0.25), value: detail)
        .padding(InfoPanelView.contentPadding)
        // An OVERLAY, not the last item in the row. In the flow its position
        // depended on how wide its neighbour was — so it started beside the
        // name and flew across the pane the instant the credits loaded. Pinned
        // to the corner it belongs to, it simply fades in where it will stay.
        .overlay(alignment: .topTrailing) {
            // The same control the Subtitles sub-screens use. Hand-rolling the
            // focused look left TWO highlights on it: the custom fill plus the
            // system's own focus effect, which `.focusEffectDisabled()` is what
            // suppresses.
            Button(action: onBack) {
                Image(systemName: "chevron.backward")
            }
            .buttonStyle(PlozzPanelHeaderButtonStyle())
            .focusEffectDisabled()
            .focused($focus, equals: .castBack)
            .opacity(contentVisible ? 1 : 0)
            .padding(InfoPanelView.contentPadding)
        }
        // Pinned to the stage in BOTH axes. Height was left to the content, so
        // the pane opened at the height of a name and grew the moment the
        // credits arrived — and since its background is the matched surface,
        // the surface grew with it. The stage is a fixed height; the pane fills
        // it and stays put however much or little there is to say.
        // An EXACT height, not `maxHeight: .infinity`. "At most the proposal" is
        // only as fixed as the proposal is, and the pane is one branch of a
        // Group whose other branch is the Info panel — so the moment the credits
        // arrived the pane could ask for more and get it. This is the same
        // promise `InfoPanelView` makes about itself.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: InfoPanelView.cardHeight)
        // Keyed on the person: switching between two faces without leaving the
        // detail has to re-ask, and re-asking must not show the previous
        // person's credits while it does.
        .task(id: person.id) {
            detail = nil
            let opened = Date()
            var first = true
            guard let loader else { return }
            // Every partial answer, not just the last one — see
            // `PlayerCastDetailLoading`.
            for await loaded in loader(person) {
                guard !Task.isCancelled else { return }
            // Assigned WITHOUT `withAnimation`. That opened a global transaction,
            // and a global transaction re-resolves the matched-geometry surface
            // this pane stands on — so the whole panel re-ran its grow every time
            // the credits landed, dragging the Back button along with it. The
            // arrival is animated by the scoped `.animation(_:value:)` on the
            // content above, which cannot reach the surface.
                detail = loaded
                // What the VIEWER experiences, which is the only number that
                // matters: from pressing Select to the pane showing something,
                // and to it being complete. The provider timings are measured
                // separately and do not include image loading or render time.
                PersonDiagnostics.emit(
                    "pane.\(first ? "first" : "update") name=\(person.name) "
                    + "credits=\(loaded.credits.count) "
                    + "bio=\(loaded.biography == nil ? "no" : "yes") "
                    + "ms=\(Int(Date().timeIntervalSince(opened) * 1000))"
                )
                first = false
            }
        }
        // Literally the chosen card's own surface, grown: the panel does not
        // draw one of its own, it inherits the matched one. No focus state —
        // this is a pane, and lighting it up would suggest it were selectable.
        .background {
            PlayerOverVideoSurface(cornerRadius: PlozzTheme.Metrics.playerPanelCornerRadius)
        }
    }

    private var hasCredits: Bool { !(detail?.credits.isEmpty ?? true) }

    /// Who they are: face, name, character, and what we can say about them.
    ///
    /// The biography sits WITH the identity rather than competing with the
    /// credits for the same slot. They answer different questions — "who is
    /// that" and "where do I know them from" — and having them take turns meant
    /// a well-stocked library could never show a biography at all.

    private var identity: some View {
        // The face, then ONE text column beside it — name, character and
        // biography all sharing a single left edge.
        //
        // The biography used to start under the headshot while the name started
        // beside it, so the column had two different left edges and the text
        // wrapped around the face in an L. Two edges in a block this small read
        // as a mistake however the individual pieces are aligned.
        // Centred against the face rather than top-aligned: at full height the
        // headshot sets this block's height, so hanging the text from its top
        // edge would strand it against the middle of a large circle.
        HStack(alignment: .center, spacing: 24) {
            avatar
                .frame(width: Self.headshot, height: Self.headshot)
                .clipShape(Circle())
                // Travels between the card's circle and its own.
                //
                // A UNIFORM scale, unlike the pane's reveal: both are circles,
                // so one factor serves and nothing can distort. Anchored at the
                // top-leading corner so the offset below places that corner
                // exactly, rather than fighting a centre-anchored scale.
                .scaleEffect(headshotScale, anchor: .topLeading)
                .offset(x: headshotOffset.width, y: headshotOffset.height)

            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: person.name)
                    .font(PlayerCardText.title)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    // The name holds its size. It is the heading of this pane,
                    // and shrinking it to buy room for a supporting line got the
                    // priority exactly backwards.
                    .minimumScaleFactor(1)
                // No character name here. It is already on the face card this
                // pane grew out of, so repeating it spends a line saying what
                // the viewer just read.
                if let biography = detail?.biography, !biography.isEmpty {
                    Text(verbatim: biography)
                        .font(PlayerCardText.body)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineSpacing(2)
                        // As many lines as the column has room for; with no rail
                        // beside it there is the whole pane to fill.
                        // What the column can actually HOLD, which is three
                        // lines either way — see `biographyLineLimit`.
                        .lineLimit(Self.biographyLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                } else if detail?.isComplete == true, detail?.isEmpty == true {
                    // Said plainly, and ONLY once every source has answered.
                    // Some people really do have nothing beyond a name and a
                    // face — no biography anywhere, and their one library credit
                    // is the film currently playing, which is struck from their
                    // own list. A blank card reads as broken; this reads as an
                    // answer.
                    Text(LocalizedStringResource(
                        "player.cast.noDetails",
                        defaultValue: "No further details available.",
                        comment: "Shown in the in-player cast card when no source has a biography or other titles for this person."
                    ))
                    .font(PlayerCardText.body)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 12)
                } else if let life = detail?.lifeSummary, !life.isEmpty {
                    // ONLY when there is no biography. A biography's first
                    // sentence says where someone was born almost without
                    // exception, so showing both reads as a stutter — but with
                    // no biography at all this is the one thing that places
                    // them, and Plex often has it when it has nothing else.
                    Text(verbatim: life)
                        .font(PlayerCardText.body)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                        .padding(.top, 12)
                }
                if let onOpenPage {
                    // The control itself, not a hint at one.
                    //
                    // A labelled chip rather than the whole block: the block is
                    // 900×210, and the house focus treatment for a row in a
                    // player panel is an inverted white card — at that size a
                    // white slab that swallows the pane and dominates everything
                    // beside it. A chip is the same shared control the Back
                    // button in this very pane uses, so focus here looks like
                    // focus anywhere else in the panel.
                    //
                    // Visible at rest, which is the whole point: this replaced a
                    // tile at the END of the credits rail, invisible until you
                    // had scrolled past every poster — so the more titles a
                    // person had, the harder it was to find the way to see them
                    // all.
                    Button { onOpenPage(person) } label: {
                        HStack(spacing: 8) {
                            Text(LocalizedStringResource(
                                "player.cast.openPersonPage",
                                defaultValue: "See more",
                                comment: "Button in the in-player cast card; opens the person's own page, which ends playback."
                            ))
                            Image(systemName: "chevron.forward")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .font(PlayerCardText.caption)
                    }
                    .buttonStyle(PlozzPanelHeaderButtonStyle())
                    .focusEffectDisabled()
                    .focused($focus, equals: .castMore)
                    // Right returns to Back, explicitly.
                    //
                    // With no credits the two sit at opposite corners, too far
                    // apart on both axes for the engine's directional search to
                    // pair them — the identity column being a focus section
                    // gets focus HERE, but nothing gets it back. Making Back a
                    // section too was the symmetrical fix and it worked, but it
                    // also changed where the engine looks when the pane opens,
                    // which closed the details instantly. Naming the
                    // destination affects nothing but this one key.
                    .onMoveCommand { direction in
                        if direction == .right { focus = .castBack }
                    }
                    .padding(.top, 14)
                }
            }
            // Deliberately NOT on the headshot: it is travelling, and has to
            // stay solid the whole way or the thing the eye is following
            // disappears mid-flight.
            .opacity(contentVisible ? 1 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The headshot's own position within the pane, which its travel is
    /// measured from: the pane's inset on both axes.
    private static var restingOrigin: CGPoint {
        CGPoint(x: InfoPanelView.contentPadding, y: InfoPanelView.contentPadding)
    }

    private var headshotScale: CGFloat {
        guard !isExpanded, let collapsedHeadshot else { return 1 }
        return collapsedHeadshot.width / Self.headshot
    }

    private var headshotOffset: CGSize {
        guard !isExpanded, let collapsedHeadshot else { return .zero }
        return CGSize(
            width: collapsedHeadshot.minX - Self.restingOrigin.x,
            height: collapsedHeadshot.minY - Self.restingOrigin.y
        )
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = person.imageURL {
            FallbackAsyncImage(urls: [url], variant: .personHeadshot) { placeholder }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Circle().fill(.white.opacity(0.12))
    }
}

/// The titles the viewer owns with this person.
///
/// Artwork alone, no titles beneath: the pane's height is fixed by the Info
/// panel it shares a stage with, and a caption would cost a third of the poster.
/// Posters are the recognisable object anyway — that is the entire point of
/// cover art — and anything without one falls back to showing its title inside
/// the frame rather than an anonymous grey rectangle.
///
/// Not focusable, by design. Nothing in this card may end the film.
private struct CastCreditsRow: View {
    let items: [MediaItem]
    @FocusState.Binding var focus: PlayerControls.FocusSlot?

    /// Each title label's rendered height, so its scrim can be sized to it.
    @State private var labelHeights: [String: CGFloat] = [:]

    /// The pane's usable height, less the room a focused poster needs to grow
    /// into. The row is now clipped to the pane — it has to be, or a scrolled
    /// poster slides out over the biography and the Back button — so the lift
    /// must fit INSIDE the pane rather than spilling out of it.
    /// The pane's whole usable height — the row is its reason for existing, so
    /// it takes all of it.
    ///
    /// Deliberately NOT reduced to make room for the focus lift. Shrinking every
    /// poster permanently to accommodate a state one of them is in briefly is a
    /// bad trade; the lift is allowed to overflow instead, into the card's own
    /// padding, which is 24pt and swallows it whole.
    private static var height: CGFloat {
        InfoPanelView.cardHeight - InfoPanelView.contentPadding * 2
    }
    private static var width: CGFloat { (height * 2 / 3).rounded() }
    /// Modest on purpose: every percent of growth is height the poster gives up
    /// at rest to make room for it.
    private static let focusScale: CGFloat = 1.06
    /// How wide the edges feather.
    private static let fade: CGFloat = 46
    /// Concentric with the panel: the app's own rule is outer = inner + inset
    /// (see `playerPanelCornerRadius`, which is this plus `contentPadding`), so
    /// inverting it for content inset by exactly that padding gives curves that
    /// stay parallel to the panel's own.
    private static var cornerRadius: CGFloat {
        PlozzTheme.Metrics.playerPanelCornerRadius - InfoPanelView.contentPadding
    }

    var body: some View {
        // A scroll view, so the row's width is whatever it is GIVEN rather than
        // whatever its contents add up to. A plain HStack that overflows pushes
        // the pane wider than the stage — the other half of why this panel
        // changed shape when the posters arrived — and this also lifts the cap
        // that existed only to make the row fit.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                content
            }
        }
        // Margins the width of the fade, so scrolling to a poster parks it just
        // INSIDE the feathered edge instead of underneath it. Without them the
        // row scrolls each newly-focused poster flush to the boundary — which is
        // exactly where it would be both dimmed by the gradient and shaved by
        // the lift.
        // Its own exact height too, so a ScrollView (whose ideal height is its
        // content's) can never report the focused poster's grown size.
        .frame(height: Self.height)
        .contentMargins(.horizontal, Self.fade, for: .scrollContent)
        // The scroll view's own clip is off, and the mask below does ALL the
        // clipping instead — because the two axes want opposite things. A
        // scrolled poster must never slide over the biography or the Back
        // button, so the sides have to be clipped; but nothing sits above or
        // below the row except the card's padding, so clipping there only ever
        // shaves the focused poster.
        .scrollClipDisabled()
        .frame(maxWidth: .infinity, alignment: .leading)
        .mask { fadeMask }
        .onPreferenceChange(CastCreditLabelHeightKey.self) { labelHeights = $0 }
    }

    /// Clips the sides and feathers them; deliberately taller than the row it
    /// masks, so the vertical axis is left alone.
    ///
    /// BOTH edges, always. The leading fade used to appear only once the row had
    /// scrolled, which meant it vanished the moment focus left — turning a soft
    /// edge back into a hard cut. It can be permanent because the content
    /// margins below inset the row by exactly this width: at rest the gradient
    /// lies over empty space and dims nothing.
    private var fadeMask: some View {
        HStack(spacing: 0) {
            Self.edgeFade(reversed: false).frame(width: Self.fade)
            Color.black
            Self.edgeFade(reversed: true).frame(width: Self.fade)
        }
        // Overhang for the focus lift. A mask hides everything its own drawing
        // does not cover, so a mask the exact height of the row IS a vertical
        // clip — this is what was still shaving the focused poster.
        .padding(.vertical, -Self.liftOverhang)
    }

    /// An EASED ramp, not a straight one.
    ///
    /// A two-stop gradient changes opacity at a constant rate, so it leaves a
    /// visible crease where it begins and ends — the eye reads those corners,
    /// not the ramp between them. These stops ease in and out of both ends, so
    /// the fade starts and finishes imperceptibly and only moves quickly through
    /// its middle, where nothing is looking.
    private static func edgeFade(reversed: Bool) -> some View {
        let ramp: [Double] = [0, 0.04, 0.18, 0.5, 0.82, 0.96, 1]
        let stops = ramp.enumerated().map { index, alpha in
            Gradient.Stop(
                color: .black.opacity(reversed ? 1 - alpha : alpha),
                location: Double(index) / Double(ramp.count - 1)
            )
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    /// How far a focused poster grows past the row, per edge.
    private static var liftOverhang: CGFloat {
        (height * (focusScale - 1) / 2).rounded(.up) + 2
    }


    @ViewBuilder
    private var content: some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let isFocused = focus == .castCredit(index)
                // A button so it can take focus and grow. Focus is what makes a
                // 140pt poster readable — and the title label it reveals is what
                // makes it certain, for the covers where the art alone isn't.
                Button {} label: {
                    poster(for: item)
                        .frame(width: Self.width, height: Self.height)
                        // Scrim and label as separate layers over the whole
                        // poster, not one box at its foot: a gradient sized to
                        // the text can only ever be as tall as the text, which
                        // is what made it a hard black band pasted on the art.
                        .overlay(alignment: .bottom) {
                            captionScrim(
                                shown: isFocused,
                                labelHeight: labelHeights[item.id] ?? 0
                            )
                        }
                        .overlay(alignment: .bottom) { titleLabel(item, shown: isFocused) }
                        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                        .animation(.easeOut(duration: 0.2), value: isFocused)
                }
                .buttonStyle(PlayerOverVideoCardStyle(
                    focused: isFocused,
                    cornerRadius: Self.cornerRadius,
                    focusScale: Self.focusScale
                ))
                .focused($focus, equals: .castCredit(index))
                .accessibilityLabel(Text(verbatim: item.title))
        }
    }

    @ViewBuilder
    private func poster(for item: MediaItem) -> some View {
        let references = item.artworkReferences(
            for: item.kind == .episode ? .seriesPoster : .poster
        )
        if references.isEmpty {
            titleTile(item)
        } else {
            FallbackAsyncImage(references: references, variant: .posterCard) {
                titleTile(item)
            }
        }
    }

    /// The darkening under a focused poster's title.
    ///
    /// Spans the whole poster and starts from nothing not far below its middle,
    /// so it arrives as a shadow gathering at the foot of the art rather than a
    /// band laid across it — the same shape as the fades on the Continue
    /// Watching cards, which ramp through the lower half rather than switching
    /// on. Its ramp is a fraction of the poster, so it stays in proportion
    /// whatever height the card gives the row.
    /// Sized to the LABEL, not to the poster.
    ///
    /// The stops used to be fractions of the poster's height, so the darkening
    /// began at a fixed point regardless of how much text sat over it — fine for
    /// one line, and a four-line title climbed out of the dark part and into the
    /// artwork. Measuring the label and adding a fade above it keeps every line
    /// equally legible whatever the title's length.
    private func captionScrim(shown: Bool, labelHeight: CGFloat) -> some View {
        // The ORIGINAL curve, over a variable height.
        //
        // These are the stops the fixed version used, re-expressed as fractions
        // of the ramp itself rather than of the poster — so the softness is
        // identical and only the distance changes. My first attempt replaced
        // them with a two-stop fade above a solid block, which is why it read as
        // harsher.
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black.opacity(0.12), location: 0.314),
                .init(color: .black.opacity(0.48), location: 0.6),
                .init(color: .black.opacity(0.80), location: 0.829),
                .init(color: .black.opacity(0.88), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: max(labelHeight, Self.singleLineLabelHeight) + Self.scrimRamp)
        .frame(maxWidth: .infinity)
        .opacity(shown ? 1 : 0)
    }

    /// A one-line label at this size, so an unmeasured label still gets the
    /// scrim it will need.
    private static let singleLineLabelHeight: CGFloat = 38
    /// The clear-to-dark distance above the text.
    ///
    /// Chosen so a single-line title reproduces the old fixed ramp exactly —
    /// which spanned 70% of a 210pt poster, i.e. 147pt, of which 38 sat behind
    /// the text itself.
    private static let scrimRamp: CGFloat = 109

    /// The title over the foot of the poster, on focus only.
    ///
    /// Over the art rather than beneath it: below the poster is the card's own
    /// bottom edge, and there is no height to spare — the row already uses all
    /// of it. Kept off entirely at rest so nine covers don't read as a wall of
    /// captions. Four lines, because the scrim now reaches far enough up the
    /// poster to hold them; three clipped titles like "Mission: Impossible —
    /// Dead Reckoning Part One".
    private func titleLabel(_ item: MediaItem, shown: Bool) -> some View {
        Text(verbatim: item.title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 7)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: CastCreditLabelHeightKey.self,
                        value: [item.id: geometry.size.height]
                    )
                }
            }
            .opacity(shown ? 1 : 0)
    }

    private func titleTile(_ item: MediaItem) -> some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.14))
            Text(verbatim: item.title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(6)
        }
    }
}

/// Collects every face card's frame, keyed by person id, so the drill knows the
/// rectangle to grow out of and shrink back into.
///
/// A preference rather than a shared observable: the frames are a product of
/// layout, and layout is the only thing that may report them.
private struct CastCreditLabelHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct CastCardFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
#endif
