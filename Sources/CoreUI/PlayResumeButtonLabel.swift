import SwiftUI

/// The thin watched-progress bar shown inside a Play/Resume button, between the
/// play glyph and the "… left" line. Its colours flip with the button's
/// light/dark background — dark ink on a light (focused/selected) button, light
/// ink on a dark (idle) button — so it stays legible either way.
///
/// Shared by the item-detail hero Play button (`DetailHeroView`) and the Home
/// hero Play pill (`HomeHeroView`) so the resume affordance is identical in both.
public struct ResumeProgressCapsule: View {
    /// Watched fraction (`0...1`) driving the fill width.
    public let progress: Double
    /// Whether the bar sits on a light background (dark ink) vs dark (light ink).
    public let onLight: Bool
    public var width: CGFloat
    public var height: CGFloat
    /// Smallest fill shown for any real progress (`> 0`). When enabled the fill
    /// never drops below a single dot (one bar height → a full circle), so a tiny
    /// resume position reads as an intentional start rather than a hairline sliver.
    /// Live gauges (downloads) pass `false` to stay exact at low percentages.
    public var floorsMinimumFill: Bool

    public init(
        progress: Double,
        onLight: Bool,
        width: CGFloat = 150,
        height: CGFloat = 6,
        floorsMinimumFill: Bool = true
    ) {
        self.progress = progress
        self.onLight = onLight
        self.width = width
        self.height = height
        self.floorsMinimumFill = floorsMinimumFill
    }

    public var body: some View {
        let track = onLight ? Color.black.opacity(0.22) : Color.white.opacity(0.32)
        let fill = onLight ? Color.black.opacity(0.85) : Color.white
        Capsule()
            .fill(track)
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(fill)
                    .frame(width: filledWidth, height: height)
            }
            .animation(.easeInOut(duration: 0.2), value: onLight)
    }

    /// The fill width. Any real progress (`> 0`) shows at least a single dot (one
    /// bar height → a full circle) when `floorsMinimumFill` is set. Exactly 0
    /// shows nothing.
    private var filledWidth: CGFloat {
        guard progress > 0 else { return 0 }
        let minFill = floorsMinimumFill ? height : 0
        return min(width, max(minFill, width * progress))
    }
}

/// The inner content of a Play/Resume button: a play glyph followed by either the
/// resume form (`▶  [progress bar]  … left`) when the item is partially watched,
/// or the plain `▶  title` otherwise.
///
/// This is the single source of truth for how the resume affordance looks, so the
/// item-detail hero and the Home hero render it identically. The glyph and text
/// inherit the ambient `.font`, so each caller keeps its own type scale; the
/// progress bar is a fixed size.
public struct PlayResumeButtonLabel: View {
    /// Plain-form label shown when the item has no resumable progress (e.g. "Play").
    public let title: String
    /// In-progress fraction; a value in `0..<1` (together with `remainingText`)
    /// switches the label to the resume form. `nil`/`0`/`1` shows the plain title.
    public let progress: Double?
    /// Remaining-time text (e.g. "20m") shown after the bar in the resume form.
    public let remainingText: String?
    /// The episode the button will play, as `S{n}, E{m}` — appended to the plain
    /// title ("Play S21, E8") and prefixed to the resume trailing ("S5, E12 • 43m").
    /// `nil` for movies/series, which keep their plain label.
    public var seasonEpisodeText: String?
    /// Whether the label sits on a light background, forwarded to the progress bar.
    public let onLight: Bool
    public var spacing: CGFloat
    public var capsuleWidth: CGFloat
    /// Height of the resume progress bar inside the button. Defaults to the
    /// compact 6pt used on iOS; tvOS heroes pass a taller bar.
    public var barHeight: CGFloat

    public init(
        title: String,
        progress: Double?,
        remainingText: String?,
        seasonEpisodeText: String? = nil,
        onLight: Bool,
        spacing: CGFloat = 16,
        capsuleWidth: CGFloat = 75,
        barHeight: CGFloat = 6
    ) {
        self.title = title
        self.progress = progress
        self.remainingText = remainingText
        self.seasonEpisodeText = seasonEpisodeText
        self.onLight = onLight
        self.spacing = spacing
        self.capsuleWidth = capsuleWidth
        self.barHeight = barHeight
    }

    /// The resume form is used only for a genuinely in-progress item: a fraction
    /// strictly between 0 and 1 with a remaining-time string to show.
    private var resumeForm: (progress: Double, remaining: String)? {
        guard let progress, progress > 0, progress < 1, let remainingText else { return nil }
        // Prefix the season/episode when present: "S5, E12 • 43m".
        let trailing = seasonEpisodeText.map { "\($0) • \(remainingText)" } ?? remainingText
        return (progress, trailing)
    }

    /// The plain (non-resume) label: the base title with the season/episode appended
    /// when present — "Play S21, E8" — else just the base title ("Play").
    private var plainTitle: String {
        seasonEpisodeText.map { "\(title) \($0)" } ?? title
    }

    public var body: some View {
        HStack(spacing: spacing) {
            Image(systemName: "play.fill")
            if let resumeForm {
                ResumeProgressCapsule(progress: resumeForm.progress, onLight: onLight, width: capsuleWidth, height: barHeight)
                Text(resumeForm.remaining)
                    .lineLimit(1)
            } else {
                Text(plainTitle)
                    .lineLimit(1)
            }
        }
    }
}
