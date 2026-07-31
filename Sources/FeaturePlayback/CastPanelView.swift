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

    /// Enough faces to answer the question, few enough that the row stays a
    /// glance rather than a browse.
    private static let maximumFaces = 20

    /// Which face was opened, so Back returns to it rather than to the start of
    /// the row.
    @State private var lastOpenedIndex = 0

    /// Ties the row's card to the detail it becomes. Without it the drill-in was
    /// two unrelated events — a row vanishing and a panel appearing — which left
    /// the viewer to work out for themselves that the panel was about the face
    /// they had just chosen.
    @Namespace private var hero

    /// The drill's clock. Same family as the card's own reveal, quicker: this is
    /// one surface growing, not the whole cluster arriving.
    ///
    /// Not private: `PlayerControls.handleExit` reverses this same drill when
    /// Menu is pressed, and the two directions have to run on one clock.
    static let drill: Animation = .smooth(duration: 0.38)

    private static func surfaceID(_ person: MediaPerson) -> String { "cast.surface.\(person.id)" }
    private static func faceID(_ person: MediaPerson) -> String { "cast.face.\(person.id)" }

    private var people: [MediaPerson] {
        Array(model.infoCard.cast.prefix(Self.maximumFaces))
    }

    var body: some View {
        Group {
            if let person = detailPerson {
                CastMemberDetail(
                    person: person,
                    loader: model.infoCard.castDetailLoader,
                    onOpenPage: model.infoCard.openPersonPage,
                    focus: $focus,
                    hero: hero,
                    surfaceID: Self.surfaceID(person),
                    faceID: Self.faceID(person),
                    onBack: { withAnimation(Self.drill) { detailPerson = nil } }
                )
                // No fade on the way IN. The detail's surface is the matched
                // one, so fading the pane fades that surface too — and a
                // surface that fades while it grows reads as a new panel
                // arriving on top of the row rather than as the chosen card
                // opening out. Its contents fade themselves instead, from
                // inside, leaving the surface to do nothing but travel. On the
                // way out it may fade: there is nothing left to confuse it with.
                .transition(.asymmetric(
                    insertion: .identity,
                    removal: .opacity.animation(.easeOut(duration: 0.12))
                ))
            } else {
                // Quick out, so the chosen card's own surface is gone before the
                // travelling one has covered any distance — two surfaces visible
                // at once is precisely what made the move feel detached.
                faceRow.transition(.asymmetric(
                    insertion: .opacity.animation(.easeIn(duration: 0.22).delay(0.10)),
                    removal: .opacity.animation(.easeOut(duration: 0.12))
                ))
            }
        }
        .frame(height: InfoPanelView.cardHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // No surface on the container. Unlike the Info panel, which is one slab,
        // the cast row is a set of separate cards floating over the video — the
        // glass belongs to each of them, not to a sheet behind them all.
        // Focus has to be placed across the swap, in both directions. The card
        // replaces its whole content, so whatever was focused is destroyed — and
        // with nothing left to hold it the engine falls back to the nearest
        // candidate, which is the tab row above. That is why selecting a face
        // jumped focus to the Info tab.
        //
        // In `onChange` rather than in the button's action: the destination does
        // not exist yet at the moment the state changes, so assigning focus there
        // targets a view that has not been built.
        .onChange(of: detailPerson) { _, person in
            focus = person == nil ? .castMember(lastOpenedIndex) : .castBack
        }
    }

    private var faceRow: some View {
        ScrollViewReader { proxy in
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
                    Button {
                        lastOpenedIndex = index
                        withAnimation(Self.drill) { detailPerson = person }
                    } label: {
                        CastFaceCard(
                            person: person,
                            focused: focus == .castMember(index),
                            hero: hero,
                            faceID: Self.faceID(person)
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
                    .focused($focus, equals: .castMember(index))
                    .id(Self.faceID(person))
                    // The frame the detail's surface grows out of, published as
                    // an empty view rather than as the card's own surface: that
                    // one is drawn inside a ButtonStyle body, and a match
                    // declared in there never reaches the panel's namespace —
                    // which is why the headshot travelled and the background
                    // simply appeared. Invisible, so the card still looks like
                    // one card, and it carries the focus lift with it.
                    .background {
                        Color.clear
                            .matchedGeometryEffect(id: Self.surfaceID(person), in: hero)
                            // Grown to the focus lift. A layout frame ignores
                            // `scaleEffect`, so a focused card published a rect
                            // 10% smaller than the one on screen and the surface
                            // began by snapping inwards. Negative padding is real
                            // layout, so it lands where the eye expects.
                            .padding(.horizontal, -CastFaceCard.lift.width)
                            .padding(.vertical, -CastFaceCard.lift.height)
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
        // Put the face back on screen as well as in focus. The row is rebuilt at
        // offset zero, so without this a restored face could hold focus from
        // somewhere off the right-hand edge.
        .onAppear {
            guard people.indices.contains(lastOpenedIndex) else { return }
            proxy.scrollTo(Self.faceID(people[lastOpenedIndex]), anchor: .center)
        }
        }
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
    let hero: Namespace.ID
    let faceID: String

    /// The headshot plus the space that has always sat either side of it, so
    /// enlarging the face widens the CARD rather than crowding it. Previously
    /// 190 and 128 were independent constants and the relationship between them
    /// was accidental; this keeps it at the 31pt it happened to be.
    static var width: CGFloat { headshot + headshotSideSpace * 2 }
    private static let headshot: CGFloat = 160
    private static let headshotSideSpace: CGFloat = 31
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
                .matchedGeometryEffect(id: faceID, in: hero)

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
    let hero: Namespace.ID
    let surfaceID: String
    let faceID: String
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

    /// Drives the contents' own fade, so the surface behind them can arrive
    /// without one. See the branch's transition.
    @State private var contentVisible = false

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
        .onAppear {
            withAnimation(.easeIn(duration: 0.22).delay(0.12)) { contentVisible = true }
        }
        // Keyed on the person: switching between two faces without leaving the
        // detail has to re-ask, and re-asking must not show the previous
        // person's credits while it does.
        .task(id: person.id) {
            detail = nil
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
            }
        }
        // Literally the chosen card's own surface, grown: the panel does not
        // draw one of its own, it inherits the matched one. No focus state —
        // this is a pane, and lighting it up would suggest it were selectable.
        .background {
            PlayerOverVideoSurface(cornerRadius: PlozzTheme.Metrics.playerPanelCornerRadius)
                .matchedGeometryEffect(id: surfaceID, in: hero)
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
                .matchedGeometryEffect(id: faceID, in: hero)

            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: person.name)
                    .font(PlayerCardText.title)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                // No character name here. It is already on the face card this
                // pane grew out of, so repeating it spends a line saying what
                // the viewer just read.
                // The factual line, above the prose. Shown whenever a source
                // has it — which is often when it has no biography at all, and
                // is then the only thing that places the person.
                if let life = detail?.lifeSummary, !life.isEmpty {
                    Text(verbatim: life)
                        .font(PlayerCardText.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .padding(.top, 10)
                }
                if let biography = detail?.biography, !biography.isEmpty {
                    Text(verbatim: biography)
                        .font(PlayerCardText.body)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineSpacing(2)
                        // As many lines as the column has room for; with no rail
                        // beside it there is the whole pane to fill.
                        // What the column has room for at the shared body size
                        // (see `PlayerCardText`), beside the face and under the
                        // name; with no rail opposite there is more of the pane
                        // to fill.
                        .lineLimit(hasCredits ? 3 : 5)
                        .fixedSize(horizontal: false, vertical: true)
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
                        .overlay { captionScrim(shown: isFocused) }
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
    private func captionScrim(shown: Bool) -> some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.30),
                .init(color: .black.opacity(0.12), location: 0.52),
                .init(color: .black.opacity(0.48), location: 0.72),
                .init(color: .black.opacity(0.80), location: 0.88),
                .init(color: .black.opacity(0.88), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .opacity(shown ? 1 : 0)
    }

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
#endif
