#if canImport(SwiftUI) && canImport(UIKit)
import UIKit
import CoreUI

/// The persistent UIKit hero **visual foreground** (POC, gated by
/// ``HeroForegroundConfig``). One long-lived view that renders a slide's
/// logo/title, metadata, overview, action-pill *visuals* and paging dots, and is
/// updated **imperatively in place** by ``HeroForegroundCoordinator`` on a page —
/// never rebuilt. It is purely a picture: it owns no focus, no gestures, no
/// controls. The SwiftUI hero keeps the single focus/action/accessibility overlay.
///
/// Layout is manual and **bottom-anchored** (the block hugs the bottom of the
/// view's bounds, mirroring the SwiftUI content column whose leading `Spacer`
/// pins the logo/metadata/buttons/dots low on the hero).
final class HeroForegroundUIView: UIView {
    // MARK: Subviews
    private let logoImageView = UIImageView()
    private let titleLabel = UILabel()
    private let ratingLabel = PaddedLabel()
    private let metadataLabel = UILabel()
    private let overviewLabel = UILabel()
    private let pillsContainer = UIView()
    private let dotsContainer = UIView()

    /// Reused pill views (pooled), so a page updates labels/frames in place rather
    /// than allocating a fresh row — persistent identity, the whole point.
    private var pillViews: [HeroForegroundPillView] = []
    /// Reused dot views (pooled) for the same reason.
    private var dotViews: [UIView] = []

    /// The slide whose logo the view currently expects, so a late async logo load
    /// is dropped if the slide has since changed (belt-and-braces with the
    /// coordinator's generation guard).
    private var currentItemID: String?
    private var model: HeroForegroundModel?

    // MARK: Metrics (mirror the SwiftUI hero)
    private let columnSpacing: CGFloat = 12
    private let pillSpacing: CGFloat = 24
    private let dotSize: CGFloat = 10
    private let activeDotWidth: CGFloat = 30
    private let dotSpacing: CGFloat = 12
    private let bottomMargin: CGFloat = 24

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = false

        logoImageView.contentMode = .scaleAspectFit
        logoImageView.isHidden = true

        titleLabel.font = .systemFont(ofSize: 64, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2

        ratingLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        ratingLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        ratingLabel.layer.borderColor = UIColor.white.withAlphaComponent(0.55).cgColor
        ratingLabel.layer.borderWidth = 1.5
        ratingLabel.layer.cornerRadius = 6
        ratingLabel.insets = UIEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
        ratingLabel.isHidden = true

        metadataLabel.font = .systemFont(ofSize: 23, weight: .medium)
        metadataLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        metadataLabel.numberOfLines = 1

        overviewLabel.font = .systemFont(ofSize: 22)
        overviewLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        overviewLabel.numberOfLines = 3

        for v in [logoImageView, titleLabel, ratingLabel, metadataLabel, overviewLabel, pillsContainer, dotsContainer] {
            addSubview(v)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Imperative apply

    /// Applies a slide's model in place. `slideChanged` drives the metadata
    /// snap-hide / fade-in exactly like the SwiftUI hero's `metadataVisible`.
    func apply(_ model: HeroForegroundModel, logo: UIImage?, metadataVisible: Bool, slideChanged: Bool) {
        self.model = model
        currentItemID = model.itemID

        // Logo vs text-title.
        if let logo {
            logoImageView.image = logo
            logoImageView.isHidden = false
            titleLabel.isHidden = true
        } else {
            logoImageView.image = nil
            logoImageView.isHidden = true
            titleLabel.isHidden = false
            titleLabel.text = model.title
        }

        if let rating = model.ratingBadgeText, !rating.isEmpty {
            ratingLabel.text = rating
            ratingLabel.isHidden = false
        } else {
            ratingLabel.isHidden = true
        }

        metadataLabel.text = model.metadataText
        metadataLabel.isHidden = (model.metadataText ?? "").isEmpty

        overviewLabel.text = model.overview
        overviewLabel.isHidden = (model.overview ?? "").isEmpty

        applyPills(model)
        applyDots(model)
        setNeedsLayout()
        layoutIfNeeded()
        applyFade(metadataVisible: metadataVisible, slideChanged: slideChanged)
    }

    /// Late async logo assignment, identity-guarded.
    func setLogo(_ image: UIImage, for itemID: String) {
        guard itemID == currentItemID else { return }
        logoImageView.image = image
        logoImageView.isHidden = false
        titleLabel.isHidden = true
        setNeedsLayout()
    }

    // MARK: Pills

    private func applyPills(_ model: HeroForegroundModel) {
        // Grow the pool as needed; reuse existing views.
        while pillViews.count < model.pills.count {
            let pill = HeroForegroundPillView()
            pillViews.append(pill)
            pillsContainer.addSubview(pill)
        }
        for (i, pillView) in pillViews.enumerated() {
            if i < model.pills.count {
                let selected = model.heroFocused && i == model.selectedIndex
                pillView.configure(model.pills[i], selected: selected)
                pillView.isHidden = false
            } else {
                pillView.isHidden = true
            }
        }
    }

    // MARK: Dots

    private func applyDots(_ model: HeroForegroundModel) {
        guard let dots = model.dots else {
            dotViews.forEach { $0.isHidden = true }
            return
        }
        let layout = HeroPagingDots.layout(count: dots.count, index: dots.index)
        while dotViews.count < layout.count {
            let dot = UIView()
            dot.backgroundColor = UIColor.white.withAlphaComponent(0.28)
            dotViews.append(dot)
            dotsContainer.addSubview(dot)
        }
        for (i, dotView) in dotViews.enumerated() {
            if i < layout.count {
                let d = layout[i]
                let active = d.index == dots.index
                let scale: CGFloat
                switch d.size {
                case .full: scale = 1.0
                case .medium: scale = 0.78
                case .small: scale = 0.55
                }
                dotView.tag = active ? 1 : 0
                dotView.backgroundColor = active
                    ? UIColor.white
                    : UIColor.white.withAlphaComponent(0.28)
                // Store scale via layer for layout.
                dotView.layer.setValue(scale, forKey: "plzScale")
                dotView.isHidden = false
            } else {
                dotView.isHidden = true
            }
        }
    }

    // MARK: Fade (metadataVisible)

    /// The set of views that fade with the show description on a page (the SwiftUI
    /// hero fades logo/metadata/overview + pills together; dots stay visible).
    private var fadeViews: [UIView] {
        [logoImageView, titleLabel, ratingLabel, metadataLabel, overviewLabel, pillsContainer]
    }

    private func applyFade(metadataVisible: Bool, slideChanged: Bool) {
        let target: CGFloat = metadataVisible ? 1 : 0
        if !metadataVisible {
            // Snap hide instantly so the outgoing text never lingers over new art.
            fadeViews.forEach { $0.layer.removeAllAnimations(); $0.alpha = 0 }
        } else {
            let animate = fadeViews.contains { $0.alpha < 1 }
            if animate {
                UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                    self.fadeViews.forEach { $0.alpha = target }
                }
            } else {
                fadeViews.forEach { $0.alpha = target }
            }
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        let leading = HomeHeroLayout.contentLeadingPadding
        let trailing: CGFloat = 60
        let maxWidth = max(1, min(bounds.width - leading - trailing, 960))

        // Measure the bottom-anchored block bottom→top.
        var y = bounds.height - bottomMargin

        // Dots at the very bottom of the block.
        if model?.dots != nil {
            let dotsHeight = dotSize
            layoutDots(bottom: y, leading: leading)
            dotsContainer.isHidden = false
            y -= dotsHeight + columnSpacing
        } else {
            dotsContainer.isHidden = true
        }

        // Pills row above the dots.
        let pillsHeight = layoutPills(bottom: y, leading: leading)
        y -= pillsHeight + columnSpacing

        // Overview above the pills (bottom-anchored: its bottom sits at y).
        if !overviewLabel.isHidden {
            let size = overviewLabel.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
            let h = min(size.height, ceil(overviewLabel.font.lineHeight * 3))
            overviewLabel.frame = CGRect(x: leading, y: y - h, width: maxWidth, height: h)
            y -= h + columnSpacing
        }

        // Metadata line.
        if !metadataLabel.isHidden || !ratingLabel.isHidden {
            let h: CGFloat = 30
            var x = leading
            if !ratingLabel.isHidden {
                let rSize = ratingLabel.intrinsicContentSize
                ratingLabel.frame = CGRect(x: x, y: y - h + (h - rSize.height) / 2, width: rSize.width, height: rSize.height)
                x += rSize.width + 16
            }
            if !metadataLabel.isHidden {
                metadataLabel.frame = CGRect(x: x, y: y - h, width: maxWidth - (x - leading), height: h)
            }
            y -= h + columnSpacing
        }

        // Logo or title on top of the block.
        if !logoImageView.isHidden, let image = logoImageView.image, image.size.width > 0 {
            let cap = min(maxWidth, 620)
            let aspect = image.size.height / image.size.width
            let w = min(cap, image.size.width)
            let h = min(160, w * aspect)
            logoImageView.frame = CGRect(x: leading, y: y - h, width: w, height: h)
        } else if !titleLabel.isHidden {
            let size = titleLabel.sizeThatFits(CGSize(width: min(maxWidth, 1000), height: .greatestFiniteMagnitude))
            let h = min(size.height, ceil(titleLabel.font.lineHeight * 2))
            titleLabel.frame = CGRect(x: leading, y: y - h, width: min(maxWidth, 1000), height: h)
        }
    }

    /// Lays out the pill row with its bottom at `bottom`; returns the row height.
    @discardableResult
    private func layoutPills(bottom: CGFloat, leading: CGFloat) -> CGFloat {
        let visible = pillViews.filter { !$0.isHidden }
        guard !visible.isEmpty else {
            pillsContainer.frame = CGRect(x: leading, y: bottom, width: 0, height: 0)
            return 0
        }
        var height: CGFloat = 0
        var widths: [CGFloat] = []
        for pill in visible {
            let s = pill.preferredSize()
            widths.append(s.width)
            height = max(height, s.height)
        }
        let totalWidth = widths.reduce(0, +) + pillSpacing * CGFloat(visible.count - 1)
        pillsContainer.frame = CGRect(x: leading, y: bottom - height, width: totalWidth, height: height)
        var x: CGFloat = 0
        for (i, pill) in visible.enumerated() {
            pill.frame = CGRect(x: x, y: 0, width: widths[i], height: height)
            pill.layoutIfNeeded()
            x += widths[i] + pillSpacing
        }
        return height
    }

    private func layoutDots(bottom: CGFloat, leading: CGFloat) {
        let visible = dotViews.filter { !$0.isHidden }
        guard !visible.isEmpty else { return }
        var totalWidth: CGFloat = 0
        for (i, dot) in visible.enumerated() {
            let w = dot.tag == 1 ? activeDotWidth : dotSize
            totalWidth += w
            if i < visible.count - 1 { totalWidth += dotSpacing }
        }
        // Center the dots across the hero width (matching the SwiftUI hero).
        let startX = max(leading, (bounds.width - totalWidth) / 2)
        dotsContainer.frame = CGRect(x: 0, y: bottom - dotSize, width: bounds.width, height: dotSize)
        var x = startX
        for dot in visible {
            let active = dot.tag == 1
            let w = active ? activeDotWidth : dotSize
            let scale = (dot.layer.value(forKey: "plzScale") as? CGFloat) ?? 1
            let drawH = active ? dotSize : dotSize * scale
            let drawW = active ? activeDotWidth : dotSize * scale
            // Frame is relative to dotsContainer's own coordinate space.
            dot.frame = CGRect(x: x + (w - drawW) / 2, y: (dotSize - drawH) / 2, width: drawW, height: drawH)
            dot.layer.cornerRadius = drawH / 2
            x += w + dotSpacing
        }
    }
}

/// A `UILabel` with content insets, used for the bordered rating chip.
private final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets.zero
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }
}
#endif
