#if canImport(SwiftUI) && canImport(UIKit)
import UIKit

/// Shared visual tokens for the hero foreground's pills and paging-dot container, so
/// both build an identical background for the selected `PillStyle`. The two flat
/// styles (`clean`, `glassish`) never sample the backdrop; only `glass` uses a live
/// `UIVisualEffectView`.
enum HeroForegroundGlass {
    /// Fully opaque theme-aware foreground ink. Explicit colors are used instead of
    /// semantic secondary colors so the renderer never gets an implicit alpha.
    static func primaryInk() -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .light ? .black : .white
        }
    }

    /// Fully opaque secondary ink: softer than primary without transparency.
    static func secondaryInk() -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .light
                ? UIColor(white: 0.22, alpha: 1)
                : UIColor(white: 0.78, alpha: 1)
        }
    }

    /// Builds the live-glass effect view for the `.glass` style, or an effect-less
    /// container (kept hidden by the caller, which draws a flat capsule instead) for
    /// the flat styles.
    static func makeView() -> UIVisualEffectView {
        guard HeroForegroundConfig.useGlass else { return UIVisualEffectView(effect: nil) }
        if #available(tvOS 26.0, *) {
            return UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    }

    /// The flat idle-capsule fill. Theme-aware: a dark translucent tint in dark mode,
    /// a light tint in light mode. Darkness is tunable via `PLZHERO_UIKIT_FILL` (0–1)
    /// for live eyeballing; defaults to a moderately dark 0.5 in dark mode.
    static let fillAlpha: CGFloat = {
        if let raw = ProcessInfo.processInfo.environment["PLZHERO_UIKIT_FILL"],
           let a = Double(raw), a >= 0 {
            return CGFloat(min(1, a))
        }
        return 0.5
    }()

    static func flatFill() -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .light
                ? UIColor.white.withAlphaComponent(max(0, fillAlpha - 0.06))
                : UIColor.black.withAlphaComponent(fillAlpha)
        }
    }

    /// The hairline border stroke for the flat capsule. A faint light edge in dark
    /// mode (and a faint dark edge in light mode) to define the pill against art —
    /// deliberately subtle. Alpha is tunable via `PLZHERO_UIKIT_BORDER` (0–1) for live
    /// eyeballing; defaults to 0.10 and `0` removes the border entirely.
    static let borderAlpha: CGFloat = {
        if let raw = ProcessInfo.processInfo.environment["PLZHERO_UIKIT_BORDER"],
           let a = Double(raw), a >= 0 {
            return CGFloat(min(1, a))
        }
        return 0.10
    }()

    static var borderWidth: CGFloat { borderAlpha <= 0 ? 0 : 2 }

    static func flatBorder() -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .light
                ? UIColor.black.withAlphaComponent(borderAlpha * 0.9)
                : UIColor.white.withAlphaComponent(borderAlpha)
        }
    }
}

/// One hero action **pill** rendered in UIKit (POC). Non-interactive — the SwiftUI
/// overlay owns focus/selection/dispatch — but it draws the pill visual and the
/// selected-highlight the same way the SwiftUI `heroPill` does:
///
/// * **Idle:** a Liquid Glass capsule (real UIKit `UIGlassEffect` on tvOS 26+,
///   falling back to an ultra-thin blur that mirrors the SwiftUI `.ultraThinMaterial`
///   path) with a white glyph/label.
/// * **Selected + hero focused:** a bright white capsule with a dark glyph/label, a
///   1.06 lift and a soft shadow, animated with the SwiftUI hero's 0.16 ease-out.
///
/// Progress pills (Play resume / active download) draw the shared inline capsule
/// gauge (≈150pt, matching `ResumeProgressCapsule`) *between* the glyph and the
/// trailing text, rather than a bar pinned to the bottom edge.
final class HeroForegroundPillView: UIView {
    /// Live-glass container, used only for the `.glass` style; hidden for the flat
    /// styles, which draw the capsule on the view's own layer instead.
    private let glassView: UIVisualEffectView = HeroForegroundGlass.makeView()
    private let style = HeroForegroundConfig.pillStyle
    /// Optional top-down highlight for the `.glassish` style — a faint sheen that
    /// fakes glass without any live backdrop sampling.
    private let sheenLayer = CAGradientLayer()
    private let glyphView = UIImageView()
    private let textLabel = UILabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()

    private let hPadding: CGFloat = 30
    private let vPadding: CGFloat = 18
    private let glyphTextGap: CGFloat = 12
    private let glyphSize: CGFloat = 30
    /// Half the former 150 — the resume trailing now also carries the "S5, E12 • "
    /// prefix, so a shorter bar keeps the pill from growing over-wide. Mirrors
    /// `PlayResumeButtonLabel.capsuleWidth`.
    private let barWidth: CGFloat = 75
    /// Matches `PlayResumeButtonLabel`'s resume bar height on tvOS heroes (the
    /// SwiftUI detail hero passes `barHeight: 10`) so the UIKit home hero pill and
    /// the SwiftUI detail hero render an identical bar.
    private let barHeight: CGFloat = 10

    private var pill: HeroForegroundModel.Pill?
    private var selected = false
    private var prominent = false
    private var progressFraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = false

        glassView.clipsToBounds = true
        glassView.isHidden = (style != .glass)
        addSubview(glassView)

        // Flat styles get a hairline border on the pill's own layer; `.glassish` adds
        // a subtle top sheen behind the content.
        if style != .glass {
            layer.borderColor = HeroForegroundGlass.flatBorder().cgColor
            layer.borderWidth = HeroForegroundGlass.borderWidth
        }
        if style == .glassish {
            sheenLayer.colors = [
                UIColor.white.withAlphaComponent(0.18).cgColor,
                UIColor.white.withAlphaComponent(0.0).cgColor,
            ]
            sheenLayer.startPoint = CGPoint(x: 0.5, y: 0)
            sheenLayer.endPoint = CGPoint(x: 0.5, y: 0.65)
            layer.addSublayer(sheenLayer)
        }

        glyphView.contentMode = .scaleAspectFit
        glyphView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        textLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        progressFill.backgroundColor = .white
        progressTrack.isHidden = true
        progressTrack.clipsToBounds = true
        for v in [glyphView, textLabel, progressTrack] { addSubview(v) }
        progressTrack.addSubview(progressFill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ pill: HeroForegroundModel.Pill, selected: Bool) {
        let selectionChanged = self.selected != selected
        self.pill = pill
        self.selected = selected
        prominent = pill.prominent
        let bright = selected || prominent

        let tint: UIColor = bright ? .black : HeroForegroundGlass.primaryInk()
        if let symbol = pill.systemImage {
            glyphView.image = UIImage(systemName: symbol)
            glyphView.tintColor = tint
            glyphView.isHidden = false
        } else {
            glyphView.image = nil
            glyphView.isHidden = true
        }
        if let text = pill.text {
            textLabel.text = text
            textLabel.textColor = tint
            textLabel.isHidden = false
        } else {
            textLabel.text = nil
            textLabel.isHidden = true
        }

        if let progress = pill.progress {
            progressTrack.isHidden = false
            let progressTint: UIColor = bright ? .black : HeroForegroundGlass.primaryInk()
            progressFill.backgroundColor = progressTint
            progressTrack.backgroundColor = progressTint.withAlphaComponent(0.3)
            progressFraction = max(0, min(1, progress))
        } else {
            progressTrack.isHidden = true
        }

        // Idle = flat capsule (clean/glassish) or live glass; selected = bright white.
        applyBackgroundAppearance()
        setNeedsLayout()

        // Only the lift scale animates as selection moves (matches SwiftUI 0.16 easeOut).
        let apply = { self.transform = selected ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity }
        if selectionChanged {
            UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: apply)
        } else {
            apply()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true,
              let pill else { return }
        // Refresh explicit layer-backed colors when tvOS changes appearance.
        configure(pill, selected: selected)
    }

    /// Resolves the pill background for the current style and selection:
    /// * **selected** — a bright white capsule (dark ink), any glass/sheen hidden.
    /// * **idle `.glass`** — the live `UIGlassEffect` view.
    /// * **idle `.clean` / `.glassish`** — a flat theme-aware translucent fill on the
    ///   view's own layer (plus a hairline border, and a sheen for `.glassish`), which
    ///   never samples the moving backdrop so it stays on the ~17ms frame budget.
    private func applyBackgroundAppearance() {
        if selected || prominent {
            glassView.isHidden = true
            sheenLayer.isHidden = true
            layer.borderWidth = 0
            backgroundColor = .white
        } else if style == .glass {
            glassView.isHidden = false
            backgroundColor = .clear
        } else {
            glassView.isHidden = true
            sheenLayer.isHidden = (style != .glassish)
            layer.borderWidth = HeroForegroundGlass.borderWidth
            layer.borderColor = HeroForegroundGlass.flatBorder().resolvedColor(with: traitCollection).cgColor
            backgroundColor = HeroForegroundGlass.flatFill()
        }
    }

    /// The label's natural single-line width, ceil'd with a hair of slack so the
    /// exact-fit capsule never truncates it (the sub-pixel remainder was showing as an
    /// ellipsis, most visibly once a focused pill scales up).
    private func naturalTextWidth() -> CGFloat {
        guard !textLabel.isHidden, !(textLabel.text ?? "").isEmpty else { return 0 }
        let fit = textLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                height: CGFloat.greatestFiniteMagnitude))
        return ceil(fit.width) + 1
    }

    /// The pill's natural size for the parent's manual row layout.
    func preferredSize() -> CGSize {
        let height = max(glyphSize, textLabel.font.lineHeight) + vPadding * 2
        // Icon-only pills (no text, no progress bar) render as a perfect circle: a
        // square whose side equals the capsule height, so the height/2 corner radius
        // rounds it fully rather than leaving a stadium/oval.
        if textLabel.isHidden && progressTrack.isHidden {
            return CGSize(width: height, height: height)
        }
        var contentWidth: CGFloat = 0
        if !glyphView.isHidden { contentWidth += glyphSize }
        if !progressTrack.isHidden {
            if contentWidth > 0 { contentWidth += glyphTextGap }
            contentWidth += barWidth
        }
        if !textLabel.isHidden {
            if contentWidth > 0 { contentWidth += glyphTextGap }
            contentWidth += naturalTextWidth()
        }
        let width = contentWidth + hPadding * 2
        return CGSize(width: width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = bounds.height / 2
        layer.cornerRadius = radius
        glassView.frame = bounds
        glassView.layer.cornerRadius = radius
        if sheenLayer.superlayer != nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sheenLayer.frame = bounds
            sheenLayer.cornerRadius = radius
            CATransaction.commit()
        }

        if selected {
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.30
            layer.shadowRadius = 14
            layer.shadowOffset = CGSize(width: 0, height: 8)
        } else {
            layer.shadowOpacity = 0
        }

        let midY = bounds.midY
        // Icon-only circular pill: centre the glyph both axes.
        if !glyphView.isHidden && textLabel.isHidden && progressTrack.isHidden {
            glyphView.frame = CGRect(x: bounds.midX - glyphSize / 2,
                                     y: midY - glyphSize / 2,
                                     width: glyphSize, height: glyphSize)
            return
        }

        var x = hPadding
        if !glyphView.isHidden {
            glyphView.frame = CGRect(x: x, y: midY - glyphSize / 2, width: glyphSize, height: glyphSize)
            x += glyphSize + glyphTextGap
        }
        if !progressTrack.isHidden {
            progressTrack.frame = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
            progressTrack.layer.cornerRadius = barHeight / 2
            // Floor the RESUME fill at a single dot (one bar height → a circle) so
            // any real progress reads as an intentional start, not a hairline
            // sliver (matching ResumeProgressCapsule). A live download gauge is
            // left exact so it isn't misrepresented at low percentages.
            let floorsFill = pill?.kind == .play
            let fillWidth: CGFloat
            if progressFraction <= 0 {
                fillWidth = 0
            } else if floorsFill {
                fillWidth = min(barWidth, max(barHeight, barWidth * progressFraction))
            } else {
                fillWidth = barWidth * progressFraction
            }
            progressFill.frame = CGRect(x: 0, y: 0, width: fillWidth, height: barHeight)
            progressFill.layer.cornerRadius = barHeight / 2
            x += barWidth + glyphTextGap
        }
        if !textLabel.isHidden {
            let remaining = bounds.width - x - hPadding
            // Prefer the label's own natural width so it never truncates; only fall
            // back to the (equal, by construction) remaining space if it's larger.
            let w = max(naturalTextWidth(), remaining)
            textLabel.frame = CGRect(x: x, y: 0, width: max(0, w), height: bounds.height)
        }
    }
}
#endif
