#if canImport(SwiftUI)
import SwiftUI

#if os(tvOS) && canImport(UIKit)
/// Makes the presenting sheet's own host transparent, so the card floats over
/// the page (dimmed) instead of on an opaque full-screen plate.
private struct ClearExpandableSheetBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async {
            view.superview?.superview?.backgroundColor = .clear
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#else
private struct ClearExpandableSheetBackground: View {
    var body: some View { Color.clear }
}
#endif

private struct ExpandableVisibleHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ExpandableFullHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ExpandableCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A block of prose capped to a few lines, with an inline **MORE** that opens the
/// full text in a centred card.
///
/// The behaviour is the detail page's About card, lifted so other surfaces can
/// use it without inheriting that view's height negotiation with the ratings
/// column beside it. Metrics — the MORE label, the fade that clears the glyphs
/// behind it, and the card's size and chrome — are deliberately identical, so
/// the two read as one pattern rather than two implementations of a similar idea.
///
/// Truncation is *measured*, never guessed: the same text is laid out twice, once
/// line-limited and once unconstrained, and MORE appears only when the second is
/// genuinely taller. A character-count heuristic gets this wrong at both ends —
/// it offers MORE for text that already fits, and hides it for text that doesn't.
public struct ExpandableOverviewText: View {
    private let text: String
    /// Heading for the expanded card, e.g. the person's or title's name.
    private let title: String  // l10n:content — a person or media title from the provider, never copy
    private let lineLimit: Int
    private let font: Font
    private let alignment: TextAlignment

    @Environment(\.themePalette) private var palette

    @State private var visibleHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    @State private var cardHeight: CGFloat = 0
    @State private var isExpanded = false

    public init(
        text: String,
        title: String,  // l10n:content — a person or media title from the provider, never copy
        lineLimit: Int,
        font: Font,
        alignment: TextAlignment = .leading
    ) {
        self.text = text
        self.title = title
        self.lineLimit = lineLimit
        self.font = font
        self.alignment = alignment
    }

    private var isTruncated: Bool {
        visibleHeight > 1 && fullHeight > visibleHeight + 1
    }

    public var body: some View {
        Group {
            if isTruncated {
                Button { isExpanded = true } label: {
                    // The padding belongs to the *label*: PlozzCardButtonStyle
                    // supplies the glass surface but no inset, so without this
                    // the surface hugs the glyphs and reads as a different
                    // control from the About card it is meant to match.
                    clipped.padding(Self.cardPadding)
                }
                .buttonStyle(
                    PlozzCardButtonStyle(
                        cornerRadius: Self.cardCornerRadius,
                        focusedScale: PlozzTheme.Metrics.readOnlyFocusedCardScale
                    )
                )
                // `fullScreenCover` on tvOS, NOT `sheet`.
                //
                // A sheet is presented by `UISheetPresentationController`, which
                // lays the PRESENTING hierarchy out synchronously as part of its
                // transition. Behind this button that hierarchy is a person or
                // title page full of `MediaRowView` rails, so opening the card
                // rebuilt every card in every row inside one layout pass and blew
                // the 10-second scene-update watchdog — the device kills the app
                // with `0x8BADF00D`, which is the freeze. A full-screen cover
                // does not run that layout dance, and a sheet was never the right
                // idiom on tvOS anyway: this already draws its own dimmed
                // backdrop and card.
                #if os(tvOS)
                .fullScreenCover(isPresented: $isExpanded) { expandedCard }
                #else
                .sheet(isPresented: $isExpanded) { expandedCard }
                #endif
            } else {
                // Nothing to open, so no button — a focusable control that does
                // nothing reads as broken (the cast tiles spent a release like
                // that). Padded identically so the text sits in the same place
                // whether or not it happens to overflow.
                clipped.padding(Self.cardPadding)
            }
        }
    }

    private var clipped: some View {
        ZStack(alignment: .bottomTrailing) {
            Text(verbatim: text)
                .font(font)
                .multilineTextAlignment(alignment)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
                // Measure the visible (line-limited) height…
                .background {
                    GeometryReader { limited in
                        Color.clear.preference(
                            key: ExpandableVisibleHeightKey.self,
                            value: limited.size.height
                        )
                    }
                }
                // …and the height the same text wants unconstrained.
                .background(alignment: .top) {
                    Text(verbatim: text)
                        .font(font)
                        .multilineTextAlignment(alignment)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .hidden()
                        .overlay {
                            GeometryReader { full in
                                Color.clear.preference(
                                    key: ExpandableFullHeightKey.self,
                                    value: full.size.height
                                )
                            }
                        }
                }

            if isTruncated {
                // Fade the tail of the last line out so no glyphs sit behind
                // MORE, then draw MORE on that same line.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.45),
                        .init(color: .black, location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: Self.fadeWidth, height: Self.fadeHeight)
                .blendMode(.destinationOut)

                Text("MORE")
                    .font(Self.moreLabelFont)
                    .plozzForeground(.secondary)
            }
        }
        .compositingGroup()
        .onPreferenceChange(ExpandableVisibleHeightKey.self) { visibleHeight = $0 }
        .onPreferenceChange(ExpandableFullHeightKey.self) { fullHeight = $0 }
    }

    @ViewBuilder
    private var expandedCard: some View {
        #if os(tvOS)
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            ScrollView {
                cardBody
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            // An explicit height between a floor and a cap. `fixedSize` plus a
            // maxHeight is the wrong pairing here: it forces the scroll view to
            // its full content height and the cap then clips it, slicing the
            // heading off the top.
            .frame(width: Self.expandedWidth, height: min(max(cardHeight, 220), 860))
            // Measured from a SEPARATE, hidden copy — never from the content
            // inside the scroll view.
            //
            // Measuring in there fed the scroll view's own height back into the
            // frame that sizes it, and the two never settled: each pass changed
            // whether the content scrolled, which changed what was measured,
            // which resized the frame. On device that ran the attribute graph at
            // 88% CPU for over 100 seconds and locked the UI (a `cpu_resource`
            // report caught it mid-loop). The hidden copy is pinned to the same
            // width and left unconstrained vertically, so its height is a pure
            // function of the text and cannot depend on the frame it computes.
            .background {
                cardBody
                    .frame(width: Self.expandedWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ExpandableCardHeightKey.self,
                                value: geometry.size.height
                            )
                        }
                    }
            }
            .onPreferenceChange(ExpandableCardHeightKey.self) { cardHeight = $0 }
            .background {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(palette.settingsBackground)
            }
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        }
        // Menu closes the card. Without it the only way out was the system's own
        // sheet dismissal, which cannot fire while the focus engine is stuck.
        .onExitCommand { isExpanded = false }
        // Place focus once the card exists. In `task` rather than `onAppear`:
        // the content is still being laid out when `onAppear` fires, and
        // focusing a view mid-layout is unreliable.
        .background(ClearExpandableSheetBackground())
        #else
        NavigationStack {
            ScrollView {
                Text(verbatim: text)
                    .font(font)
                    .foregroundStyle(palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .background(palette.settingsBackground)
            .navigationTitle(title)
        }
        #endif
    }

    /// The expanded card's content, shared by the real one and the hidden copy
    /// that measures it — so the measurement can never drift from the thing it
    /// describes.
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: title)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            // One focusable block PER PARAGRAPH, rather than one Text.
            //
            // tvOS scrolls by moving focus between things — there is no
            // free-panning scroll view. A single Text, focusable or not, gives
            // the engine nowhere to travel, so a card taller than the screen
            // simply could not be read past its first screenful. Paragraphs are
            // the natural stops: focus steps down them and the scroll view
            // follows, and with the focus effect suppressed the page still reads
            // as continuous prose rather than a list of buttons.
            ForEach(Array(Self.paragraphs(of: text).enumerated()), id: \.offset) { _, paragraph in
                Text(verbatim: paragraph)
                    .font(.system(size: 29))
                    .foregroundStyle(palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusable()
                    .focusEffectDisabled()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(48)
    }

    /// Splits prose into focusable blocks.
    ///
    /// Real paragraph breaks where the text has them. A single long paragraph —
    /// common in a biography — is split further at sentence ends, so it still has
    /// somewhere for focus to stop; without that, one unbroken wall of text would
    /// be unscrollable however tall it grew.
    static func paragraphs(of text: String) -> [String] {
        let byBreak = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let source = byBreak.isEmpty ? [text] : byBreak

        return source.flatMap { block -> [String] in
            guard block.count > Self.maximumBlockLength else { return [block] }
            var blocks: [String] = []
            var current = ""
            for sentence in block.split(separator: ".", omittingEmptySubsequences: false) {
                let piece = current.isEmpty ? String(sentence) : current + "." + sentence
                if piece.count >= Self.maximumBlockLength {
                    blocks.append(piece.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current = piece
                }
            }
            let tail = current.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { blocks.append(tail) }
            return blocks.isEmpty ? [block] : blocks
        }
    }

    /// Roughly a screenful of this type, so focus never has to leap further than
    /// the viewer can follow.
    private static let maximumBlockLength = 420

    private static let expandedWidth: CGFloat = 900

    /// Matched to the About card so the two are the same control.
    private static var cardPadding: CGFloat {
        #if os(tvOS)
        22
        #else
        16
        #endif
    }

    private static var cardCornerRadius: CGFloat {
        #if os(tvOS)
        20
        #else
        16
        #endif
    }

    private static var moreLabelFont: Font {
        #if os(tvOS)
        .system(size: 20, weight: .semibold)
        #else
        .footnote.weight(.semibold)
        #endif
    }

    private static var fadeHeight: CGFloat {
        #if os(tvOS)
        34
        #else
        22
        #endif
    }

    private static var fadeWidth: CGFloat {
        #if os(tvOS)
        220
        #else
        150
        #endif
    }
}
#endif
