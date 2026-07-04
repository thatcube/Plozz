import SwiftUI

/// The thin watched-progress bar shown inside a Play/Resume button, between the
/// play glyph and the "… left" line. Its colours flip with the button's
/// light/dark background — dark ink on a light (focused/selected) button, light
/// ink on a dark (idle) button — so it stays legible either way.
///
/// Shared by the item-detail hero Play button (`DetailHeroView`) and the Home
/// hero Play pill (`HomeHeroView`) so the resume affordance is identical in both.
struct ResumeProgressCapsule: View {
    /// Watched fraction (`0...1`) driving the fill width.
    let progress: Double
    /// Whether the bar sits on a light background (dark ink) vs dark (light ink).
    let onLight: Bool
    var width: CGFloat = 150
    var height: CGFloat = 6

    var body: some View {
        let track = onLight ? Color.black.opacity(0.22) : Color.white.opacity(0.32)
        let fill = onLight ? Color.black.opacity(0.85) : Color.white
        Capsule()
            .fill(track)
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(fill)
                    .frame(width: max(8, width * progress), height: height)
            }
            .animation(.easeInOut(duration: 0.2), value: onLight)
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
struct PlayResumeButtonLabel: View {
    /// Plain-form label shown when the item has no resumable progress (e.g. "Play").
    let title: String
    /// In-progress fraction; a value in `0..<1` (together with `remainingText`)
    /// switches the label to the resume form. `nil`/`0`/`1` shows the plain title.
    let progress: Double?
    /// Remaining-time text (e.g. "20m") shown after the bar in the resume form.
    let remainingText: String?
    /// Whether the label sits on a light background, forwarded to the progress bar.
    let onLight: Bool
    var spacing: CGFloat = 16
    var capsuleWidth: CGFloat = 150

    /// The resume form is used only for a genuinely in-progress item: a fraction
    /// strictly between 0 and 1 with a remaining-time string to show.
    private var resumeForm: (progress: Double, remaining: String)? {
        guard let progress, progress > 0, progress < 1, let remainingText else { return nil }
        return (progress, remainingText)
    }

    var body: some View {
        HStack(spacing: spacing) {
            Image(systemName: "play.fill")
            if let resumeForm {
                ResumeProgressCapsule(progress: resumeForm.progress, onLight: onLight, width: capsuleWidth)
                Text(resumeForm.remaining)
                    .lineLimit(1)
            } else {
                Text(title)
                    .lineLimit(1)
            }
        }
    }
}
