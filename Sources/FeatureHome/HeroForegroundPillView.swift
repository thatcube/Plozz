#if canImport(SwiftUI) && canImport(UIKit)
import UIKit

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
    private let glassView: UIVisualEffectView = {
        if #available(tvOS 26.0, *) {
            return UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    }()
    private let glyphView = UIImageView()
    private let textLabel = UILabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()

    private let hPadding: CGFloat = 30
    private let vPadding: CGFloat = 18
    private let glyphTextGap: CGFloat = 12
    private let glyphSize: CGFloat = 30
    private let barWidth: CGFloat = 150
    private let barHeight: CGFloat = 6

    private var pill: HeroForegroundModel.Pill?
    private var selected = false
    private var progressFraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = false

        glassView.clipsToBounds = true
        addSubview(glassView)

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

        let tint: UIColor = selected ? .black : .white
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
            progressFill.backgroundColor = selected ? .black : .white
            progressTrack.backgroundColor = (selected ? UIColor.black : UIColor.white).withAlphaComponent(0.3)
            progressFraction = max(0, min(1, progress))
        } else {
            progressTrack.isHidden = true
        }

        // Idle = Liquid Glass; selected = bright white fill (glass hidden).
        glassView.isHidden = selected
        backgroundColor = selected ? .white : .clear
        setNeedsLayout()

        // Only the lift scale animates as selection moves (matches SwiftUI 0.16 easeOut).
        let apply = { self.transform = selected ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity }
        if selectionChanged {
            UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: apply)
        } else {
            apply()
        }
    }

    /// The pill's natural size for the parent's manual row layout.
    func preferredSize() -> CGSize {
        var contentWidth: CGFloat = 0
        if !glyphView.isHidden { contentWidth += glyphSize }
        if !progressTrack.isHidden {
            if contentWidth > 0 { contentWidth += glyphTextGap }
            contentWidth += barWidth
        }
        if !textLabel.isHidden {
            if contentWidth > 0 { contentWidth += glyphTextGap }
            textLabel.sizeToFit()
            contentWidth += textLabel.bounds.width
        }
        // Icon-only pills get a squarer minimum so info/watchlist/next read as chips.
        if textLabel.isHidden && progressTrack.isHidden { contentWidth = max(contentWidth, 34) }
        let width = contentWidth + hPadding * 2
        let height = max(glyphSize, textLabel.font.lineHeight) + vPadding * 2
        return CGSize(width: width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = bounds.height / 2
        layer.cornerRadius = radius
        glassView.frame = bounds
        glassView.layer.cornerRadius = radius

        if selected {
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.30
            layer.shadowRadius = 14
            layer.shadowOffset = CGSize(width: 0, height: 8)
        } else {
            layer.shadowOpacity = 0
        }

        var x = hPadding
        let midY = bounds.midY
        if !glyphView.isHidden {
            glyphView.frame = CGRect(x: x, y: midY - glyphSize / 2, width: glyphSize, height: glyphSize)
            x += glyphSize + glyphTextGap
        }
        if !progressTrack.isHidden {
            progressTrack.frame = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
            progressTrack.layer.cornerRadius = barHeight / 2
            progressFill.frame = CGRect(x: 0, y: 0, width: barWidth * progressFraction, height: barHeight)
            progressFill.layer.cornerRadius = barHeight / 2
            x += barWidth + glyphTextGap
        }
        if !textLabel.isHidden {
            let w = bounds.width - x - hPadding
            textLabel.frame = CGRect(x: x, y: 0, width: max(0, w), height: bounds.height)
        }
    }
}
#endif
