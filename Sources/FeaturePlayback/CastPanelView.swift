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
    @Environment(\.playerCardMetrics) private var metrics
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
    /// Each card's PHOTO, in the same space — measured, not derived.
    @State private var photoFrames: [String: CGRect] = [:]
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
    static let drillDuration: TimeInterval = 0.38
    static let drill: Animation = .smooth(duration: drillDuration)
    /// How long to hold the detail alive after asking it to shrink.
    ///
    /// DERIVED from the curve above, never written out again. These were
    /// independent numbers — 340ms against a 380ms curve — so the pane was torn
    /// down 40ms before its headshot finished travelling, and the card's own
    /// face was already sitting at the exact resting position underneath. The
    /// handoff moved the circle by a few points, right at the very end, which
    /// is the hardest kind of glitch to place: the animation looks fine and
    /// then something twitches after it.
    ///
    /// The margin covers the frame the curve settles on; landing a frame late
    /// costs nothing and landing a frame early is the bug.
    static let drillTeardown: Duration = .milliseconds(Int(drillDuration * 1000) + 30)

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
            castCollection
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
                    onOpenTitle: model.infoCard.openTitlePage,
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
                // The drill is a HORIZONTAL-card effect: it grows a pane out of
                // one portrait card in a row. A vertical list has no such card to
                // grow from — the row is full-width, so "expanding" it is just
                // the pane appearing — and the pane's own layout is a column
                // there. So the mask is skipped and the two cross-fade.
                .mask(alignment: .topLeading) {
                    if metrics.isVertical {
                        Rectangle()
                    } else {
                        revealMask
                    }
                }
            }
        }
        // Every card's frame in this panel's own space, so the drill knows where
        // to grow from and shrink back to.
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(CastCardFrameKey.self) { cardFrames = $0 }
        .onPreferenceChange(CastPhotoFrameKey.self) { photoFrames = $0 }
        .modifier(PlayerCardHeight(metrics: metrics))
        // The vertical panel takes the height its rows actually need, up to the
        // ceiling — a four-person cast should not leave two thirds of a card
        // empty. Computed rather than measured: every row is exactly
        // `castRowHeight`, so there is nothing to find out. Floored so that
        // drilling into a short cast does not leave the biography in a letterbox.
        .frame(height: metrics.isVertical ? verticalPanelHeight : nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Measured AFTER the frames above, which is the whole point of it
        // sitting here rather than up beside the preference readers.
        //
        // Applied before them it reported the ZStack's INTRINSIC size — the
        // width the face row happens to want — and the drill's reveal mask is
        // sized from this, so the detail pane was masked to the row's width
        // instead of the card's. On tvOS the row is long enough to fill the card
        // and the two agree by accident; on a smaller card, with fewer and
        // narrower face cards, the pane visibly stopped short of every edge.
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { panelSize = geometry.size }
                    .onChange(of: geometry.size) { _, size in panelSize = size }
            }
        }
        .onChange(of: closeRequest) { _, _ in
            guard detailPerson != nil else { return }
            closeDetail()
        }
    }

    /// The panel's coordinate space, which card frames are reported in.
    static let space = "cast.panel"

    private var verticalPanelHeight: CGFloat {
        let rows = CGFloat(people.count)
        let natural = metrics.contentPadding * 2 + rows * metrics.castRowHeight
            + max(rows - 1, 0) * 8
        return min(max(natural, 260), metrics.cardHeight)
    }

    /// Out of the focus order while the detail covers the row, and — while
    /// returning — for every face except the one being returned to.
    private func isFaceDisabled(_ index: Int) -> Bool {
        if detailPerson != nil { return true }
        if let restoringToIndex { return index != restoringToIndex }
        return false
    }

    /// Whether this card is the one the detail pane grew out of.
    private func isDrillSource(_ person: MediaPerson) -> Bool {
        detailPerson?.id == person.id
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
    /// Where the chosen card's photo actually is — measured by the card, not
    /// reconstructed from its constants.
    ///
    /// Reconstruction was tried twice and failed twice. Once naively, which
    /// ignored that a focused card is DRAWN 10% larger than it is laid out; then
    /// with the lift added back, which landed the face 13pt high because the
    /// card is not drawn lifted at the instant the pane hands off to it. Neither
    /// attempt could have accounted for the press depress either, which moves
    /// the photo the moment Select goes down.
    ///
    /// Falls back to the arithmetic only if a measurement has not arrived —
    /// which, since the card is on screen before it can be chosen, means never
    /// in practice.
    private var collapsedHeadshotFrame: CGRect? {
        guard let person = detailPerson else { return nil }
        guard let measured = photoFrames[person.id] else {
            // Only before the row has laid out, which cannot happen for a card
            // the viewer has just chosen.
            return openedCardFrame.map {
                CGRect(
                    x: $0.minX + metrics.castHeadshotOrigin.x,
                    y: $0.minY + metrics.castHeadshotOrigin.y,
                    width: metrics.castHeadshot,
                    height: metrics.castHeadshot
                )
            }
        }
        // The measurement, used AS MEASURED.
        //
        // The card also reports the factor it is drawn at, and multiplying by it
        // looks like the last honest gap — a measured frame is the card at rest,
        // while a focused card is drawn a tenth larger. It was tried and it puts
        // a visible hitch in the middle of the transition, because that factor
        // is not constant during it: opening the detail disables this card, so
        // focus leaves, so the lift unwinds — and the rectangle the animation is
        // flying toward changes underneath it.
        //
        // A target that moves mid-flight is worse than one that is 10% off, and
        // the resting frame is what the card returns to anyway.
        return measured
    }

    private var revealMask: some View {
        // As measured, matching the headshot above — see the note there on why
        // the reported focus scale is deliberately not applied.
        let collapsed = openedCardFrame ?? CGRect(
            x: 0, y: 0,
            width: metrics.castCardWidth,
            height: metrics.cardHeight
        )
        let radius = isExpanded
            ? metrics.panelCornerRadius
            : metrics.panelCornerRadius
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
            try? await Task.sleep(for: Self.drillTeardown)
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

    /// The cast, laid out for the card's shape.
    ///
    /// A row of portrait cards is the right answer on a wide card and the wrong
    /// one on a narrow column: at phone width barely two fit, so the row becomes
    /// a horizontal scroll through a list the viewer cannot see the length of.
    /// A vertical list shows six at once in the same space. Apple's own player
    /// makes exactly this swap between landscape and portrait.
    @ViewBuilder
    private var castCollection: some View {
        if metrics.isVertical {
            castList
        } else {
            faceRow
        }
    }

    /// The narrow-card cast: a vertical list of rows.
    private var castList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 8) {
                ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                    Button { openDetail(person, at: index) } label: {
                        CastListRow(person: person)
                    }
                    // The SAME surface the face cards use. A row and a card are
                    // two shapes of one thing, and giving them different
                    // materials made switching orientation look like switching
                    // apps. No lift or depress: nothing focuses on a touch
                    // surface, and a row this wide has nowhere to grow.
                    .buttonStyle(PlayerOverVideoCardStyle(
                        focused: false,
                        cornerRadius: metrics.panelCornerRadius - 6,
                        focusScale: 1,
                        pressScale: 0.98
                    ))
                    .disabled(isFaceDisabled(index))
                    .focused($focus, equals: .castMember(index))
                    .id(Self.faceID(person))
                    // Its rectangle in the panel's space, so a drill — if this
                    // layout ever grows one — has somewhere to start.
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
            // NO horizontal inset. These rows stand in the Info card's place when
            // the tab switches, so their edges have to be its edges — and that
            // card's glass runs to the strip's own edge. An inset here made the
            // cast sit narrower than everything around it, which reads as the two
            // tabs having different margins rather than as breathing room.
            .padding(.vertical, metrics.contentPadding)
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
            HStack(spacing: metrics.columnSpacing) {
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
                        cornerRadius: metrics.panelCornerRadius,
                        focusScale: CastFaceCard.focusScale,
                        // No depress. This card is what the detail pane grows
                        // out of, and a press that shifts it means the rectangle
                        // the drill starts from moves while Select is held down.
                        pressScale: 1
                    ))
                    // The source card is not faded with the row — it is
                    // switched off outright, the instant the pane exists.
                    //
                    // The pane IS this card as far as the viewer is concerned,
                    // so the two must never be on screen together. Fading it
                    // over the drill left its surface, its photo and its white
                    // focus ring sitting under a second surface growing out of
                    // the same place, which is what made one object read as
                    // two — and made every pixel of disagreement between them
                    // visible for the whole animation instead of for none of it.
                    .opacity(isDrillSource(person) ? 0 : 1)
                    // Instant in both directions. Anything gradual here is the
                    // overlap this exists to remove.
                    .transaction { transaction in
                        if isDrillSource(person) { transaction.animation = nil }
                    }
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
            .padding(.trailing, metrics.contentPadding)
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
    @Environment(\.playerCardMetrics) private var metrics
    let person: MediaPerson
    let focused: Bool

    /// The labels' own inset, which is narrower — they may run closer to the
    /// card's edge than the circle does.
    private static let inset: CGFloat = 12
    /// The full tvOS card lift. These are small cards in a row, where the gentle
    /// default barely registered.
    static let focusScale: CGFloat = 1.10

    var body: some View {
        VStack(spacing: 12) {
            avatar
                .frame(width: metrics.castHeadshot, height: metrics.castHeadshot)
                .clipShape(Circle())
                // The photo reports where it actually IS, rather than the drill
                // reconstructing it from this card's internal constants.
                //
                // Those constants were only ever a description of this layout at
                // one moment: change the padding, the name's font, or the
                // accessibility text size, and the circle moves while the drill
                // keeps aiming at where it used to be. Measuring is the only
                // version of this that survives the page being edited.
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .preference(
                                key: CastPhotoFrameKey.self,
                                value: [person.id: geometry.frame(in: .named(CastPanelView.space))]
                            )

                    }
                }

            // Names are the one thing on this card that must be readable in
            // full, and a card this narrow truncates plenty of real ones. The
            // same marquee the subtitle list uses: truncated and feathered at
            // rest, scrolling the whole name once the card has focus.
            VStack(spacing: 3) {
                MarqueeText(
                    text: person.name,
                    font: metrics.castNameFont,
                    isFocused: focused,
                    restingAlignment: .center
                )
                .foregroundStyle(.white)
                if let role = person.role, !role.isEmpty {
                    MarqueeText(
                        text: role,
                        font: metrics.castRoleFont,
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
        .padding(.vertical, metrics.castVerticalInset)
        .padding(.horizontal, Self.inset)
        .frame(width: metrics.castCardWidth)
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

/// One person as a full-width row: circular headshot, name and character.
///
/// The narrow-card counterpart to ``CastFaceCard``. A row rather than a card
/// because width is the scarce thing here and a row spends none of it: the
/// headshot is small, and the name gets the entire remaining span rather than
/// the ~150pt a portrait card could offer — so it reads in full instead of
/// needing the marquee the card resorts to.
private struct CastListRow: View {
    @Environment(\.playerCardMetrics) private var metrics
    let person: MediaPerson

    var body: some View {
        HStack(spacing: 12) {
            CastAvatar(person: person)
                .frame(width: metrics.castHeadshot, height: metrics.castHeadshot)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(person.name)
                    .font(metrics.castNameFont)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let role = person.role, !role.isEmpty {
                    Text(role)
                        .font(metrics.castRoleFont)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: metrics.castRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Surface comes from PlayerOverVideoCardStyle, exactly as the face
        // cards' does.
    }
}

/// A person's headshot, or their initials when there is no photo.
private struct CastAvatar: View {
    let person: MediaPerson

    var body: some View {
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
                .minimumScaleFactor(0.4)
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
    @Environment(\.playerCardMetrics) private var metrics
    let person: MediaPerson
    let loader: PlayerCastDetailLoading?
    let onOpenPage: ((MediaPerson) -> Void)?
    /// Leave the film for one of these titles.
    let onOpenTitle: ((MediaItem) -> Void)?
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
    private var headshot: CGFloat { contentHeight }
    /// Wide enough for a name beside the headshot and a biography that reads as
    /// prose beneath it. The artwork pays for every point of this, but the row
    /// scrolls and a truncated sentence does not. A phone cannot spend 900 —
    /// that is wider than the screen — so it takes what a landscape iPhone has
    /// left once the headshot and the Back lane are paid for.
    private var identityWidth: CGFloat { metrics.castIdentityWidth }
    /// The stage, less its inset. Everything in the pane is pinned to this: a
    /// column that exceeds it pushes the whole HStack past the frame that is
    /// meant to contain it, and the overflow is then split between the top and
    /// bottom — which is exactly what made the top inset look tighter than the
    /// bottom one.
    var contentHeight: CGFloat { metrics.contentHeight }
    /// Kept clear on the right for the Back button, which floats above the
    /// content rather than sitting in the row with it.
    ///
    /// Measured from the button rather than fixed at the 62 the tvOS chevron
    /// happens to need: the same button is drawn smaller on a small card, and a
    /// lane that does not shrink with it eats a poster's worth of a narrow card
    /// — while one that does not GROW lets the chevron sit on top of the last
    /// poster, which is what these were doing.
    private var backButtonLane: CGFloat {
        metrics.contentPadding * 2 + 40
    }

    /// How many lines of biography fit, derived from the budget rather than
    /// guessed at.
    ///
    /// The stage is a hard 210pt and the column must also hold the name and the
    /// "See more" chip; five lines needed 261 and simply overflowed, clipping
    /// the name at the top and the chip at the bottom. Three is what is left,
    /// and the chip is there precisely so a longer life story has somewhere to
    /// be read in full.
    private var biographyLineLimit: Int {
        let budget = contentHeight - metrics.detailChromeHeight
        return max(2, Int(budget / metrics.bodyLineHeight))
    }

    /// `nil` while the request is in flight, which is NOT the same as an empty
    /// result — an empty state shown during a load flashes "nothing known about
    /// them" at someone who is about to be told plenty.
    @State private var detail: PlayerCastDetail?

    var body: some View {
        Group {
            if metrics.isVertical {
                verticalBody
            } else {
                horizontalBody
            }
        }
        // Scoped to this subtree on purpose — see the loader below.
        .animation(.easeOut(duration: 0.25), value: detail)
        .padding(metrics.contentPadding)
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
            .padding(metrics.contentPadding)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .modifier(PlayerCardHeight(metrics: metrics))
        // Literally the chosen card's own surface, grown: the panel does not
        // draw one of its own, it inherits the matched one. No focus state —
        // this is a pane, and lighting it up would suggest it were selectable.
        //
        // OUTERMOST, and that is the fix rather than a tidy-up. Applied at the
        // foot of the horizontal body it wrapped the bare content — inside the
        // padding and before the width frame — so the glass hugged the headshot
        // and the posters and stopped well short of the card's edges. A
        // background draws around whatever it is attached to, so it has to be
        // attached to the finished card, not to what goes in it. The vertical
        // body had no surface at all for the same reason.
        .background {
            PlayerOverVideoSurface(cornerRadius: metrics.panelCornerRadius)
        }
        // Keyed on the person: switching between two faces without leaving the
        // detail has to re-ask, and re-asking must not show the previous
        // person's credits while it does.
        .task(id: person.id) { await load() }
    }

    /// The narrow card: the person as a column.
    ///
    /// The face shrinks to a row-sized circle and the biography takes the width
    /// the poster rail cannot have here — a rail of 2:3 posters beside a text
    /// column simply does not fit, so the credits go underneath and the pane
    /// reads top to bottom like the list it opened from.
    private var verticalBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CastAvatar(person: person)
                    .frame(width: metrics.castHeadshot, height: metrics.castHeadshot)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: person.name)
                        .font(metrics.titleFont)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let role = person.role, !role.isEmpty {
                        Text(verbatim: role)
                            .font(metrics.castRoleFont)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                // Clear of the Back button, which is an overlay pinned to this
                // corner rather than a member of the row.
                Spacer(minLength: backButtonLane)
            }

            // No line limit: the column scrolls, so a long life story is read
            // rather than truncated with nowhere else to go.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    biographyBlock(lineLimit: nil)

                    if expectsCredits {
                        Group {
                            if hasCredits, let credits = detail?.credits {
                                CastCreditsRow(
                                    items: credits,
                                    focus: $focus,
                                    onOpenTitle: onOpenTitle
                                )
                            } else {
                                CastCreditsRow(
                                    items: [],
                                    focus: $focus,
                                    onOpenTitle: nil,
                                    placeholderCount: 5
                                )
                            }
                        }
                        .opacity(contentVisible ? 1 : 0)
                    }

                    if let onOpenPage {
                        Button { onOpenPage(person) } label: {
                            HStack(spacing: 8) {
                                Text(LocalizedStringResource(
                                    "player.cast.openPersonPage",
                                    defaultValue: "See more",
                                    comment: "Button in the in-player cast card; opens the person's own page, which ends playback."
                                ))
                                Image(systemName: "chevron.forward")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(PlozzPanelHeaderButtonStyle())
                        .focusEffectDisabled()
                        .focused($focus, equals: .castMore)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .opacity(contentVisible ? 1 : 0)
    }

    private var horizontalBody: some View {
        // Identity in a column on the left, so whatever we know about them gets
        // the pane's FULL height rather than what is left under a name. With the
        // name above them, posters could only be 88pt wide — too small to
        // recognise from a sofa, which defeats the entire point of showing art.
        HStack(alignment: .top, spacing: metrics.columnSpacing) {
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
                .frame(height: contentHeight, alignment: .leading)
                // Full width when there is nothing to sit beside, so the
                // biography can run properly instead of hugging one edge with
                // half the pane left empty.
                .frame(
                    width: expectsCredits ? identityWidth : nil,
                    alignment: .leading
                )
                .frame(maxWidth: expectsCredits ? nil : .infinity, alignment: .leading)
                // Stop short of the Back button in the full-width case too.
                // With a poster rail beside it the rail reserved this lane; with
                // no credits the column takes the whole stage and ran straight
                // under the chevron.
                .padding(.trailing, expectsCredits ? 0 : backButtonLane)

            if expectsCredits {
                // The lane is CLAIMED for the whole load, not only once there
                // are posters to put in it.
                //
                // The Back button is an overlay pinned to the pane's trailing
                // edge, so the pane's width has to be settled before the row
                // arrives. With nothing holding this space the pane measured
                // only as wide as the identity column, parking the button
                // halfway across and snapping it outward when the posters
                // landed — the same travel the overlay exists to prevent.
                Group {
                    if hasCredits, let credits = detail?.credits {
                        CastCreditsRow(
                            items: credits,
                            focus: $focus,
                            onOpenTitle: onOpenTitle
                        )
                    } else {
                        // Enough to read as a row continuing past the edge,
                        // which is what the real one almost always does.
                        CastCreditsRow(
                            items: [],
                            focus: $focus,
                            onOpenTitle: nil,
                            placeholderCount: 5
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .opacity(contentVisible ? 1 : 0)
                // Stop short of the Back button. Without this the row ran under
                // it and a poster scrolled beneath the chevron.
                .padding(.trailing, backButtonLane)
            }
        }
        .frame(height: contentHeight, alignment: .topLeading)
    }

    private func load() async {
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
            // matters: from pressing Select to the pane showing something, and to
            // it being complete. The provider timings are measured separately and
            // do not include image loading or render time.
            PersonDiagnostics.emit(
                "pane.\(first ? "first" : "update") name=\(person.name) "
                + "credits=\(loaded.credits.count) "
                + "bio=\(loaded.biography == nil ? "no" : "yes") "
                + "ms=\(Int(Date().timeIntervalSince(opened) * 1000))"
            )
            first = false
        }
    }

    /// Whether to reserve the poster lane — asked of what we EXPECT, not of
    /// what has arrived.
    ///
    /// Credits are withheld until their order is settled, so for the first
    /// half-second there are none yet for almost everybody who has some. Keying
    /// the layout on arrival meant the biography opened full width and then
    /// visibly collapsed to half as the row appeared.
    ///
    /// So the split layout is the assumption while loading, and the full-width
    /// one is adopted only once we KNOW there is nothing to show. That puts the
    /// single unavoidable layout change on the rare case — a person with no
    /// credits anywhere — instead of on the common one.
    private var expectsCredits: Bool {
        if let detail, detail.isComplete { return !detail.credits.isEmpty }
        return true
    }

    private var hasCredits: Bool { !(detail?.credits.isEmpty ?? true) }

    /// Who they are: face, name, character, and what we can say about them.
    ///
    /// The biography sits WITH the identity rather than competing with the
    /// credits for the same slot. They answer different questions — "who is
    /// that" and "where do I know them from" — and having them take turns meant
    /// a well-stocked library could never show a biography at all.

    /// Whatever we actually know about them: a biography, failing that the
    /// life summary that places them, and failing both a plain admission.
    ///
    /// Shared by the two layouts. `lineLimit` is `nil` in the vertical card,
    /// where the column scrolls and a life story can simply be read; the
    /// horizontal card has a fixed stage and must cap it — see
    /// `biographyLineLimit`.
    @ViewBuilder
    private func biographyBlock(lineLimit: Int?) -> some View {
            if let biography = detail?.biography, !biography.isEmpty {
                Text(verbatim: biography)
                    .font(metrics.bodyFont)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineSpacing(2)
                    // As many lines as the column has room for; with no rail
                    // beside it there is the whole pane to fill.
                    // What the column can actually HOLD, which is three
                    // lines either way — see `biographyLineLimit`.
                    .lineLimit(lineLimit)
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
                .font(metrics.bodyFont)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 12)
            } else if let life = detail?.lifeSummary, !life.isEmpty {
                // ONLY when there is no biography. A biography's first
                // sentence says where someone was born almost without
                // exception, so showing both reads as a stutter — but with
                // no biography at all this is the one thing that places
                // them, and Plex often has it when it has nothing else.
                Text(verbatim: life)
                    .font(metrics.bodyFont)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
                    .padding(.top, 12)
            }
    }

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
        HStack(alignment: .center, spacing: metrics.columnSpacing) {
            avatar
                .frame(width: headshot, height: headshot)
                .clipShape(Circle())
                // Travels between the card's circle and its own.
                //
                // A UNIFORM scale, unlike the pane's reveal: both are circles,
                // so one factor serves and nothing can distort. Anchored at the
                // top-leading corner so the offset below places that corner
                // exactly, rather than fighting a centre-anchored scale.
                .scaleEffect(headshotScale, anchor: .topLeading)
                .offset(x: headshotOffset.width, y: headshotOffset.height)
                // Pinned to the drill curve EXPLICITLY, rather than inheriting
                // the transaction that set `isExpanded`.
                //
                // This circle sits inside the subtree carrying
                // `.animation(_:value: detail)`, and a scoped animation
                // swallows ambient transactions for everything beneath it — so
                // the headshot was travelling on that 0.25s ease while the
                // pane it is travelling across revealed on a 0.38s smooth.
                // Close enough to look almost right, which is why it read as
                // slightly off rather than plainly wrong: the face arrived
                // ahead of the panel and on a different easing.
                //
                // Narrow on purpose — attached to the leaf, not the cluster.
                // An animation modifier further up retimes the whole reveal.
                .animation(CastPanelView.drill, value: isExpanded)

            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: person.name)
                    .font(metrics.titleFont)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    // The name holds its size. It is the heading of this pane,
                    // and shrinking it to buy room for a supporting line got the
                    // priority exactly backwards.
                    .minimumScaleFactor(1)
                // No character name here. It is already on the face card this
                // pane grew out of, so repeating it spends a line saying what
                // the viewer just read.
                biographyBlock(lineLimit: biographyLineLimit)
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
                        .font(metrics.captionFont)
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
                    // Through the shared wrapper, because `onMoveCommand` is
                    // tvOS-only and this file also builds for iPad.
                    .plozzMoveCommand { direction in
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
    private var restingOrigin: CGPoint {
        CGPoint(x: metrics.contentPadding, y: metrics.contentPadding)
    }

    private var headshotScale: CGFloat {
        guard !isExpanded, let collapsedHeadshot else { return 1 }
        return collapsedHeadshot.width / headshot
    }

    private var headshotOffset: CGSize {
        guard !isExpanded, let collapsedHeadshot else { return .zero }
        return CGSize(
            width: collapsedHeadshot.minX - restingOrigin.x,
            height: collapsedHeadshot.minY - restingOrigin.y
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
    @Environment(\.playerCardMetrics) private var metrics
    /// Whether an unowned credit here can be requested or is only flagged.
    @Environment(\.plozzSeerConnected) private var seerConnected
    let items: [MediaItem]
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    /// Opens a title's own page, ending playback. `nil` leaves the posters inert.
    let onOpenTitle: ((MediaItem) -> Void)?
    /// Renders this many placeholder tiles instead of posters.
    ///
    /// A mode of this row rather than a view beside it, because the two have to
    /// occupy EXACTLY the same place. A separate view was tried and could only
    /// ever approximate this one's geometry — the scroll container, its content
    /// margins, the fixed height and the edge mask all move the first tile — so
    /// the posters landed a few points off their placeholders. Sharing the
    /// container makes that class of drift impossible rather than merely fixed.
    var placeholderCount: Int?

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
    private var posterHeight: CGFloat { metrics.contentHeight }
    private var posterWidth: CGFloat { (posterHeight * 2 / 3).rounded() }
    /// Card-edge inset for the not-in-library mark, proportional to the poster so
    /// it isn't jammed into the corner of a card this small.
    private var markInset: CGFloat { max(6, posterWidth * 0.035) }
    /// Modest on purpose: every percent of growth is height the poster gives up
    /// at rest to make room for it.
    private static let focusScale: CGFloat = 1.06
    /// How wide the edges feather.
    ///
    /// Wider than it was (46): the same curve compressed into a narrow band has
    /// to change alpha faster per point, and a fast ramp is exactly what reads
    /// as a hard edge rather than a fade. The row's content margins are keyed to
    /// this, so the gradient still lies over empty space at rest and dims
    /// nothing.
    private static let fade: CGFloat = 64
    /// Concentric with the panel: the app's own rule is outer = inner + inset
    /// (see `playerPanelCornerRadius`, which is this plus `contentPadding`), so
    /// inverting it for content inset by exactly that padding gives curves that
    /// stay parallel to the panel's own.
    private var cornerRadius: CGFloat {
        PlozzTheme.Metrics.playerPanelCornerRadius - metrics.contentPadding
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
        .frame(height: posterHeight)
        .contentMargins(.horizontal, Self.fade, for: .scrollContent)
        // The scroll view's own clip is off on tvOS ONLY, where the mask below
        // does all the clipping instead — because there the two axes want
        // opposite things. A scrolled poster must never slide over the biography
        // or the Back button, so the sides have to be clipped; but a FOCUSED
        // poster grows past the row, and clipping vertically would shave it.
        //
        // Touch has no focus lift, so nothing ever needs to overflow and the
        // ordinary clip is simply correct — leaving it off let posters draw
        // outside the card entirely, under the Back button and past the rounded
        // corner.
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
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
        .padding(.vertical, -liftOverhang)
    }

    /// An EASED ramp, not a straight one.
    ///
    /// A two-stop gradient changes opacity at a constant rate, so it leaves a
    /// visible crease where it begins and ends — the eye reads those corners,
    /// not the ramp between them. These stops ease in and out of both ends, so
    /// the fade starts and finishes imperceptibly and only moves quickly through
    /// its middle, where nothing is looking.
    private static func edgeFade(reversed: Bool) -> some View {
        // Sampled from smoothstep rather than written out by hand.
        //
        // The hand-picked seven-stop ramp was an approximation of this curve,
        // and being an approximation it had small kinks in it — a gradient is
        // read by the eye as a rate of change, so an uneven rate shows up as
        // banding even when no individual step is large. Sampling the real
        // function at enough points removes that, and the count is the cheap
        // part: this is a static gradient, not something re-evaluated per frame.
        let samples = 24
        let stops = (0...samples).map { step -> Gradient.Stop in
            let t = Double(step) / Double(samples)
            // 3t² − 2t³: zero slope at both ends, so the fade begins and ends
            // imperceptibly and only moves quickly through its middle, where
            // nothing is looking.
            let eased = t * t * (3 - 2 * t)
            return Gradient.Stop(
                color: .black.opacity(reversed ? 1 - eased : eased),
                location: t
            )
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    /// How far a focused poster grows past the row, per edge.
    private var liftOverhang: CGFloat {
        #if os(tvOS)
        return (posterHeight * (Self.focusScale - 1) / 2).rounded(.up) + 2
        #else
        // No focus, no lift, nothing to make room for.
        return 0
        #endif
    }


    @ViewBuilder
    private var content: some View {
        if let placeholderCount {
            ForEach(0..<placeholderCount, id: \.self) { index in
                CastCreditPlaceholderTile(
                    width: posterWidth,
                    height: posterHeight,
                    cornerRadius: cornerRadius,
                    delay: Double(index) * 0.08
                )
            }
        } else {
            realContent
        }
    }

    @ViewBuilder
    private var realContent: some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let isFocused = focus == .castCredit(index)
                // Select opens the title's own page, ending playback — the same
                // contract "See more" has.
                //
                // Not merely focusable: a focusable control that does nothing
                // reads as broken, and these spent a build like that. It applies
                // to every entry, owned or not; the detail page is what knows
                // the difference, offering Play for a title in the library and a
                // request for one that is not.
                let libraryMark = MediaLibraryMark.mark(for: item, seerConnected: seerConnected)
                Button { onOpenTitle?(item) } label: {
                    poster(for: item)
                        .frame(width: posterWidth, height: posterHeight)
                        // Most of this row is external credits the viewer does
                        // not own, and until now they rendered exactly like
                        // owned titles — you selected one and got a page you
                        // could not play anything from, with no warning. The
                        // mark is that warning, and it needs the artwork
                        // darkened behind it exactly as the caption does.
                        .overlay(alignment: .top) {
                            if libraryMark != nil {
                                MediaArtworkChromeScrim(top: true, bottom: false)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if let libraryMark {
                                MediaLibraryMarkView(
                                    mark: libraryMark,
                                    size: MediaLibraryMarkView.size(forCardWidth: posterWidth)
                                )
                                .padding(markInset)
                            }
                        }
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
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .animation(.easeOut(duration: 0.2), value: isFocused)
                }
                .buttonStyle(PlayerOverVideoCardStyle(
                    focused: isFocused,
                    cornerRadius: cornerRadius,
                    focusScale: Self.focusScale
                ))
                .focused($focus, equals: .castCredit(index))
                .accessibilityLabel(Text(verbatim: item.title))
                // The mark's own label is additional, not a replacement: the
                // title still has to be the first thing announced.
                .accessibilityValue(
                    libraryMark.map { Text($0.accessibilityLabel) } ?? Text(verbatim: "")
                )
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

/// Where each card's photo is, in the panel's coordinate space.
///
/// Separate from `CastCardFrameKey`: that one is the whole card, which sizes the
/// pane's reveal, while this is the circle the headshot flies to and from. They
/// are measured independently so neither has to know how the other is laid out.
private struct CastPhotoFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct CastCardFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// One poster-shaped gap in the lane while the row loads.
///
/// Sized by the row that owns it rather than by its own constants, so it cannot
/// drift from the poster that replaces it.
private struct CastCreditPlaceholderTile: View {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    /// Staggered per tile, so the lane reads as one object breathing rather
    /// than five rectangles flashing in unison.
    let delay: Double

    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.white.opacity(dim ? 0.05 : 0.11))
            .frame(width: width, height: height)
            .animation(
                .easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(delay),
                value: dim
            )
            .onAppear { dim = true }
    }
}

#endif
