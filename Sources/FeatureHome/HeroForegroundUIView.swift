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
    /// Liquid Glass capsule that hosts the paging dots (real `UIGlassEffect` on
    /// tvOS 26+, ultra-thin blur below), mirroring the SwiftUI `pagingDotsGlass`.
    private let dotsContainer: UIVisualEffectView = {
        if #available(tvOS 26.0, *) {
            return UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    }()

    /// Reused pill views (pooled), so a page updates labels/frames in place rather
    /// than allocating a fresh row — persistent identity, the whole point.
    private var pillViews: [HeroForegroundPillView] = []
    /// Reused dot views (pooled) for the same reason.
    private var dotViews: [HeroPagingDotView] = []

    /// Drives the active paging pill's live auto-advance gauge (matches the SwiftUI
    /// hero's 30 Hz `TimelineView`). Only runs while a slide is auto-advancing and
    /// not paused; otherwise the fill is set once (full or empty) and the link stops.
    private var dotsGaugeLink: CADisplayLink?

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
    private let dotsGlassHPad: CGFloat = 14
    private let dotsGlassVPad: CGFloat = 9
    private let bottomMargin: CGFloat = 24

    /// Total height of the paging-dot glass capsule (dot + vertical padding), used to
    /// reserve vertical space in the bottom-anchored layout.
    private var dotsGlassHeight: CGFloat { dotSize + dotsGlassVPad * 2 }

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
        dotsContainer.clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { dotsGaugeLink?.invalidate() }

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
            dotsContainer.isHidden = true
            stopDotsGauge()
            return
        }
        let layout = HeroPagingDots.layout(count: dots.count, index: dots.index)
        while dotViews.count < layout.count {
            let dot = HeroPagingDotView()
            dotViews.append(dot)
            dotsContainer.contentView.addSubview(dot)
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
                dotView.configure(active: active, tint: .white, scale: scale)
                dotView.isHidden = false
            } else {
                dotView.isHidden = true
            }
        }
        // Drive (or freeze) the active pill's live gauge from the dwell.
        refreshDotsGauge(dots)
    }

    // MARK: Auto-advance gauge

    /// Starts/stops the display link and sets the active pill's fill for the current
    /// dwell. Mirrors the SwiftUI `brightFillWidth`: no auto-advance ⇒ a full pill;
    /// auto-advance ⇒ a dot growing to the full pill across the dwell; paused ⇒
    /// frozen at `pausedAt`.
    private func refreshDotsGauge(_ dots: HeroForegroundModel.Dots) {
        guard let active = dotViews.first(where: { !$0.isHidden && $0.isActive }) else {
            stopDotsGauge()
            return
        }
        guard dots.autoAdvance, let start = dots.dwellStart, dots.dwellDuration > 0 else {
            // Auto-advance off (or no dwell): the active pill is a solid full pill.
            stopDotsGauge()
            active.setFillFraction(1)
            return
        }
        if let paused = dots.pausedAt {
            // Frozen: hold the fill at the paused instant, no ticking.
            stopDotsGauge()
            active.setFillFraction(gaugeFraction(start: start, duration: dots.dwellDuration, now: paused))
            return
        }
        // Live: tick the fill at ~30 Hz until the page changes.
        activeDwellStart = start
        activeDwellDuration = dots.dwellDuration
        if dotsGaugeLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tickDotsGauge))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            dotsGaugeLink = link
        }
        tickDotsGauge()
    }

    private var activeDwellStart: Date?
    private var activeDwellDuration: Double = 0

    @objc private func tickDotsGauge() {
        guard let start = activeDwellStart,
              let active = dotViews.first(where: { !$0.isHidden && $0.isActive }) else {
            stopDotsGauge()
            return
        }
        active.setFillFraction(gaugeFraction(start: start, duration: activeDwellDuration, now: Date()))
    }

    private func gaugeFraction(start: Date, duration: Double, now: Date) -> CGFloat {
        guard duration > 0 else { return 1 }
        return CGFloat(min(1, max(0, now.timeIntervalSince(start) / duration)))
    }

    private func stopDotsGauge() {
        dotsGaugeLink?.invalidate()
        dotsGaugeLink = nil
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

        // Dots (in their glass capsule) at the very bottom of the block.
        if model?.dots != nil {
            layoutDots(bottom: y, leading: leading)
            dotsContainer.isHidden = false
            y -= dotsGlassHeight + columnSpacing
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
        guard !visible.isEmpty else {
            dotsContainer.isHidden = true
            return
        }
        // Fixed-pitch slots: the active pill is `activeDotWidth` wide, every other dot
        // occupies a full `dotSize` slot (a shrunk edge dot is centred inside its slot)
        // so the row's total width — and thus the glass capsule — never breathes.
        var rowWidth: CGFloat = 0
        for (i, dot) in visible.enumerated() {
            rowWidth += dot.isActive ? activeDotWidth : dotSize
            if i < visible.count - 1 { rowWidth += dotSpacing }
        }
        let glassWidth = rowWidth + dotsGlassHPad * 2
        let glassHeight = dotsGlassHeight
        // Centre the capsule across the hero width, matching the SwiftUI hero.
        let glassX = (bounds.width - glassWidth) / 2
        dotsContainer.frame = CGRect(x: glassX, y: bottom - glassHeight, width: glassWidth, height: glassHeight)
        dotsContainer.layer.cornerRadius = glassHeight / 2

        // Lay the dots inside the glass content view (its own coordinate space).
        var x = dotsGlassHPad
        let cy = glassHeight / 2
        for dot in visible {
            if dot.isActive {
                dot.frame = CGRect(x: x, y: cy - dotSize / 2, width: activeDotWidth, height: dotSize)
                dot.layoutIfNeeded()
                x += activeDotWidth + dotSpacing
            } else {
                // Shrunk circle centred inside a full-size slot.
                let scale = dot.currentScale
                let draw = dotSize * scale
                dot.frame = CGRect(x: x + (dotSize - draw) / 2, y: cy - draw / 2, width: draw, height: draw)
                dot.layoutIfNeeded()
                x += dotSize + dotSpacing
            }
        }
    }
}

/// One paging indicator drawn in UIKit: a dim capsule track plus (for the active
/// slide) a bright fill that grows from a dot to the full pill as the auto-advance
/// dwell elapses — the UIKit twin of the SwiftUI `pagingIndicator`/`activeDotFill`.
private final class HeroPagingDotView: UIView {
    private(set) var isActive = false
    private(set) var currentScale: CGFloat = 1
    private let fill = UIView()
    private var fraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        fill.isHidden = true
        addSubview(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(active: Bool, tint: UIColor, scale: CGFloat) {
        isActive = active
        currentScale = scale
        backgroundColor = tint.withAlphaComponent(0.28)
        fill.backgroundColor = tint
        fill.isHidden = !active
        setNeedsLayout()
    }

    /// Sets the bright fill fraction (`0...1`). The fill interpolates from a dot
    /// (`height`) up to the full pill (`width`) so it starts moving immediately,
    /// matching the SwiftUI `brightFillWidth`.
    func setFillFraction(_ f: CGFloat) {
        fraction = max(0, min(1, f))
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        guard isActive, bounds.height > 0 else { return }
        let w = bounds.height + (bounds.width - bounds.height) * fraction
        fill.frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
        fill.layer.cornerRadius = bounds.height / 2
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
