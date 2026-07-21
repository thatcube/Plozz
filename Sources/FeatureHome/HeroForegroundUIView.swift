#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
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
    private let ratingsHost = UIHostingController(
        rootView: AnyView(EmptyView())
    )
    private let pillsContainer = UIView()
    /// Effect-less host: dots/pill render directly over the hero with no capsule.
    private let dotsContainer = UIVisualEffectView(effect: nil)
    private let useGauge = HeroForegroundConfig.useGauge

    /// Reused pill views (pooled), so a page updates labels/frames in place rather
    /// than allocating a fresh row — persistent identity, the whole point.
    private var pillViews: [HeroForegroundPillView] = []
    /// Paging-dot views keyed by their real slide index (matching the SwiftUI hero's
    /// index-identity `ForEach`). Keying by slide — not by fixed slot — means that on
    /// a windowed page the persisting dots slide slot→slot, the dot leaving the window
    /// fades off its edge and the entering dot fades in, while the active pill holds at
    /// its slot: the "dots scroll under a held pill" animation. Views are created
    /// lazily and removed once they scroll out of the window.
    private var dotViewsByIndex: [Int: HeroPagingDotView] = [:]
    /// The dots to render this page, in slot order (from `HeroPagingDots.layout`).
    private var currentDotLayout: [HeroPagingDots.Dot] = []
    /// The active (fronted) slide index, drawn as the wide pill.
    private var activeDotIndex: Int?
    /// Indices whose view was created for the incoming page, so `layoutDots` can slide
    /// them in from the entering edge (with a fade) rather than popping at the origin.
    private var enteringDotIndices: Set<Int> = []
    /// Signature of the last positioned dot layout, so a same-page re-apply (a
    /// selection / metadata-fade update) is a no-op instead of snapping the dot frames
    /// to final and cancelling a running page-morph animation.
    private var lastDotsSignature: [Int] = []

    /// Drives the active paging pill's live auto-advance gauge (matches the SwiftUI
    /// hero's 30 Hz `TimelineView`). Only runs while a slide is auto-advancing and
    /// not paused; otherwise the fill is set once (full or empty) and the link stops.
    private var dotsGaugeLink: CADisplayLink?

    /// The slide whose logo the view currently expects, so a late async logo load
    /// is dropped if the slide has since changed (belt-and-braces with the
    /// coordinator's generation guard).
    private var currentItemID: String?
    private var model: HeroForegroundModel?
    /// The current slide's fully-processed logo (image + monochrome/halo flags), so
    /// a light/dark trait change can re-tint a monochrome wordmark and reapply the
    /// halo without reloading it. `nil` when the slide shows its text title.
    private var currentLogo: HeroUIKitLogo?

    /// The last rendered paging index, so a genuine page change can animate the
    /// active-dot morph (dot→pill / pill→dot sliding left→right, matching the SwiftUI
    /// hero); `nil` until the first dotted slide is shown.
    private var lastDotsIndex: Int?
    /// Set for exactly one layout pass whenever the page changed, so `layoutDots`
    /// animates the dot frames into place rather than snapping them.
    private var animateDotsMorph = false
    /// Direction of the last page change: `true` when the index INCREASED (window
    /// scrolls so new dots enter at the RIGHT edge), `false` when it decreased (new
    /// dots enter at the LEFT). Drives which edge an entering dot slides in from.
    private var dotsScrollForward = true
    /// Duration of the dot page-morph (matches the SwiftUI hero's `dotMorph`).
    private let dotsMorphDuration: CFTimeInterval = 0.3
    /// Opacity an entering edge dot starts at (it appears at full height and its final
    /// slot, then fades up to 1 within the morph — a slight initial fill, not a pop
    /// from nothing). Mirrors SwiftUI's opacity insertion transition.
    private let dotEnterStartAlpha: CGFloat = 0.3
    /// Duration of the logo cross-dissolve when a late-resolved logo lands (or a
    /// warm logo replaces the text title) while the description is already on screen.
    /// Mirrors the SwiftUI hero's `HeroLogoArtwork` `.onArrival` opacity transition /
    /// `.contentTransition(.opacity)` so the logo dissolves in instead of hard-snapping
    /// a beat after the metadata has settled. Pure content/alpha crossfade — no backdrop
    /// sampling, so it keeps the flat foreground's hitch-free transition budget.
    private let logoArrivalFade: TimeInterval = 0.3

    // MARK: Metrics (mirror the SwiftUI hero)
    private let columnSpacing: CGFloat = 12
    /// Extra breathing room above the action-pill row (on top of `columnSpacing`).
    private let pillsTopPadding: CGFloat = 16
    /// Extra margin between the paging dots and the action-pill row above them: the
    /// dots are laid out this far below their normal bottom-anchored slot so the pills
    /// stay put while the pagination gains more air.
    private let buttonsToDotsGap: CGFloat = 40
    private let pillSpacing: CGFloat = 24
    private let dotSize: CGFloat = 10
    private let activeDotWidth: CGFloat = 30
    private let dotSpacing: CGFloat = 12
    /// Narrower cinematic text column (was 576; trimmed 80pt for a tighter column).
    private let contentMaxWidth: CGFloat = 496
    /// Cap the logo to the same width as the description text column, so a wide
    /// wordmark spans the full text width rather than a narrower box.
    private let logoMaxWidth: CGFloat = 496
    private let dotsGlassHPad: CGFloat = 0
    private let dotsGlassVPad: CGFloat = 0
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
        // The legibility halo (for low-contrast logos) is a layer shadow derived
        // from the image's alpha, so it must not be clipped.
        logoImageView.layer.masksToBounds = false

        titleLabel.font = .systemFont(ofSize: 64, weight: .bold)
        titleLabel.numberOfLines = 2

        ratingLabel.font = UIFont(name: "Bungee-Regular", size: 18)
            ?? .systemFont(ofSize: 18, weight: .semibold)
        ratingLabel.layer.borderWidth = 3
        ratingLabel.layer.cornerRadius = 6
        ratingLabel.insets = UIEdgeInsets(top: 0, left: 11, bottom: 0, right: 11)
        ratingLabel.fixedHeight = 36
        ratingLabel.textAlignment = .center
        ratingLabel.isHidden = true

        metadataLabel.font = .systemFont(ofSize: 23, weight: .medium)
        metadataLabel.numberOfLines = 1

        overviewLabel.font = .systemFont(ofSize: 22)
        overviewLabel.numberOfLines = 3
        ratingsHost.view!.backgroundColor = .clear
        ratingsHost.view!.isUserInteractionEnabled = false

        // A low-opacity, wide-radius glyph shadow keeps copy readable over bright
        // artwork without looking outlined. It is static layer chrome (no backdrop
        // sampling), so it preserves the flat foreground's transition advantage.
        for label in [titleLabel, ratingLabel, metadataLabel, overviewLabel] {
            label.layer.shadowOpacity = 0.32
            label.layer.shadowRadius = 7
            label.layer.shadowOffset = CGSize(width: 0, height: 2)
        }
        applyThemeColors()

        for v in [logoImageView, titleLabel, ratingLabel, metadataLabel,
                  overviewLabel, ratingsHost.view!, pillsContainer, dotsContainer] {
            addSubview(v)
        }
        dotsContainer.clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { dotsGaugeLink?.invalidate() }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { stopContinuousUpdates() }
    }

    /// Explicit representable teardown. A `CADisplayLink` retains its target, so
    /// relying on `deinit` alone would keep this entire renderer alive indefinitely.
    func stopContinuousUpdates() {
        stopDotsGauge()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true {
            applyThemeColors()
            setNeedsLayout()
        }
    }

    private func applyThemeColors() {
        let primary = HeroForegroundGlass.primaryInk()
        let secondary = HeroForegroundGlass.secondaryInk()
        titleLabel.textColor = primary
        ratingLabel.textColor = primary
        metadataLabel.textColor = secondary
        overviewLabel.textColor = secondary

        let resolvedPrimary = primary.resolvedColor(with: traitCollection)
        ratingLabel.layer.borderColor = resolvedPrimary.withAlphaComponent(0.65).cgColor
        let shadow = traitCollection.userInterfaceStyle == .light ? UIColor.white : UIColor.black
        for label in [titleLabel, ratingLabel, metadataLabel, overviewLabel] {
            label.layer.shadowColor = shadow.cgColor
        }
        // A monochrome wordmark is recoloured to the scheme foreground, so a
        // light/dark switch must re-tint it (and re-evaluate the halo colour).
        applyLogoTintAndHalo()
    }

    // MARK: - Imperative apply

    /// Applies a slide's model in place. `slideChanged` drives the metadata
    /// snap-hide / fade-in exactly like the SwiftUI hero's `metadataVisible`.
    func apply(_ model: HeroForegroundModel, logo: HeroUIKitLogo?, metadataVisible: Bool, slideChanged: Bool) {
        self.model = model
        currentItemID = model.itemID

        // Logo vs text-title.
        if let logo {
            configureLogoImage(logo)
            logoImageView.isHidden = false
            titleLabel.isHidden = true
        } else {
            currentLogo = nil
            logoImageView.image = nil
            logoImageView.layer.shadowOpacity = 0
            logoImageView.isHidden = true
            titleLabel.isHidden = false
            titleLabel.text = model.title
        }

        if let rating = model.ratingBadgeText, !rating.isEmpty {
            ratingLabel.text = rating.uppercased()
            ratingLabel.isHidden = false
        } else {
            ratingLabel.isHidden = true
        }

        metadataLabel.text = model.metadataText
        metadataLabel.isHidden = (model.metadataText ?? "").isEmpty

        overviewLabel.text = model.overview
        overviewLabel.isHidden = (model.overview ?? "").isEmpty
        ratingsHost.rootView = AnyView(
            RatingsBadgeRow(ratings: model.ratings)
                .frame(maxWidth: .infinity, alignment: .leading)
        )
        ratingsHost.view!.isHidden = model.ratings.isEmpty

        applyPills(model)
        applyDots(model)
        setNeedsLayout()
        layoutIfNeeded()
        applyFade(metadataVisible: metadataVisible, slideChanged: slideChanged)
    }

    /// Late async logo assignment, identity-guarded. Cross-dissolves the logo in when
    /// the description block is already visible (a late resolve landing after the group
    /// fade has settled), mirroring the SwiftUI hero's `HeroLogoArtwork` arrival
    /// transition, instead of a hard snap. When the block is currently hidden (mid
    /// page snap-hide) it just sets the image so the group fade-in brings it up.
    func setLogo(_ logo: HeroUIKitLogo, for itemID: String) {
        guard itemID == currentItemID else { return }
        crossfadeToLogo(logo)
        setNeedsLayout()
    }

    /// Swaps the text title out for `logo`, dissolving when on screen. Sets the image
    /// and lays out at final geometry first (layout only positions the logo once its
    /// image is non-nil), then cross-dissolves via alpha so the logo fades up as the
    /// outgoing title fades out — no frame jump, no backdrop sampling.
    private func crossfadeToLogo(_ logo: HeroUIKitLogo) {
        let onScreen = !isHidden && logoImageView.alpha > 0.01
        configureLogoImage(logo)
        logoImageView.isHidden = false
        guard onScreen else {
            titleLabel.isHidden = true
            return
        }
        // Settle layout for the logo's real size before dissolving, so only opacity
        // animates — not the frame.
        logoImageView.alpha = 0
        setNeedsLayout()
        layoutIfNeeded()
        UIView.animate(withDuration: logoArrivalFade, delay: 0,
                       options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]) {
            self.logoImageView.alpha = 1
            self.titleLabel.alpha = 0
        } completion: { _ in
            self.titleLabel.isHidden = true
            self.titleLabel.alpha = 1
        }
    }

    /// Installs a resolved logo into `logoImageView` with the same treatment as the
    /// SwiftUI ``HeroLogoArtwork``: a monochrome wordmark is drawn as a template
    /// image (tinted to the scheme foreground in ``applyLogoTintAndHalo``), while
    /// multi-colour brand art draws as-is. Tint/halo are applied separately so a
    /// trait change can recolour without reloading.
    private func configureLogoImage(_ logo: HeroUIKitLogo) {
        currentLogo = logo
        logoImageView.image = logo.image.withRenderingMode(
            logo.isMonochrome ? .alwaysTemplate : .alwaysOriginal
        )
        applyLogoTintAndHalo()
    }

    /// Applies the current logo's scheme-adaptive tint and legibility halo. A
    /// monochrome wordmark is tinted to the scheme foreground (white in dark mode,
    /// black in light) and needs no halo (it contrasts the scheme-tone scrim by
    /// construction). A low-contrast multi-colour logo gets a soft alpha-derived
    /// glow — light for a dark logo, dark for a light one — mirroring
    /// `LogoLegibilityHalo`.
    private func applyLogoTintAndHalo() {
        guard let logo = currentLogo else {
            logoImageView.layer.shadowOpacity = 0
            return
        }
        if logo.isMonochrome {
            logoImageView.tintColor = traitCollection.userInterfaceStyle == .light ? .black : .white
            logoImageView.layer.shadowOpacity = 0
            return
        }
        guard logo.needsHalo else {
            logoImageView.layer.shadowOpacity = 0
            return
        }
        if logo.isDark {
            // Light glow for a dark logo — unchanged across appearances.
            logoImageView.layer.shadowColor = UIColor.white.cgColor
            logoImageView.layer.shadowOpacity = 0.6
            logoImageView.layer.shadowRadius = 9
        } else if traitCollection.userInterfaceStyle == .light {
            // Softer, lighter dark glow in light mode (matches LogoLegibilityHalo):
            // the bright hero doesn't need a heavy black halo, so drop the opacity
            // and widen the radius for a gentle lift instead of a hard smudge.
            logoImageView.layer.shadowColor = UIColor.black.cgColor
            logoImageView.layer.shadowOpacity = 0.28
            logoImageView.layer.shadowRadius = 13
        } else {
            logoImageView.layer.shadowColor = UIColor.black.cgColor
            logoImageView.layer.shadowOpacity = 0.55
            logoImageView.layer.shadowRadius = 9
        }
        logoImageView.layer.shadowOffset = .zero
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
            dotViewsByIndex.values.forEach { $0.removeFromSuperview() }
            dotViewsByIndex.removeAll()
            currentDotLayout = []
            activeDotIndex = nil
            enteringDotIndices.removeAll()
            lastDotsSignature = []
            dotsContainer.isHidden = true
            stopDotsGauge()
            lastDotsIndex = nil
            return
        }
        // Animate the whole row's morph on a genuine page change (never on the first
        // show, and never when the page didn't actually move — e.g. a selection or
        // metadata-fade re-apply). Every page change animates, matching SwiftUI's
        // `.animation(value: index)`; `.beginFromCurrentState` lets a rapid burst
        // retarget the in-flight morph instead of piling up.
        if let last = lastDotsIndex, last != dots.index {
            animateDotsMorph = true
            if last == dots.count - 1, dots.index == 0 {
                dotsScrollForward = true
            } else if last == 0, dots.index == dots.count - 1 {
                dotsScrollForward = false
            } else {
                dotsScrollForward = dots.index > last
            }
        } else {
            animateDotsMorph = false
        }
        lastDotsIndex = dots.index

        let layout = HeroPagingDots.layout(count: dots.count, index: dots.index)
        currentDotLayout = layout
        activeDotIndex = dots.index
        enteringDotIndices.removeAll()

        // Get-or-create a view per REAL slide index, so identity is stable across the
        // window scroll and the persisting dots animate slot→slot.
        for d in layout {
            let view: HeroPagingDotView
            if let existing = dotViewsByIndex[d.index] {
                view = existing
            } else {
                view = HeroPagingDotView()
                dotViewsByIndex[d.index] = view
                dotsContainer.contentView.addSubview(view)
                // Entering on an animated page change: it appears at its final slot
                // and full height, starting slightly filled (not from nothing) and
                // fading up to full — matching SwiftUI's opacity insertion. No vertical
                // slide / scale-in ("from the top").
                if animateDotsMorph {
                    enteringDotIndices.insert(d.index)
                    view.alpha = dotEnterStartAlpha
                }
            }
            let scale: CGFloat
            switch d.size {
            case .full: scale = 1.0
            case .medium: scale = 0.78
            case .small: scale = 0.55
            }
            view.configure(
                active: d.index == dots.index,
                tint: HeroForegroundGlass.primaryInk(),
                scale: scale
            )
            view.isHidden = false
        }
        // Drive (or freeze) the active pill's live gauge from the dwell.
        refreshDotsGauge(dots)
    }

    // MARK: Auto-advance gauge

    /// The wide active pill's view (the one that renders the auto-advance gauge).
    private var activeDotView: HeroPagingDotView? {
        guard let activeDotIndex else { return nil }
        return dotViewsByIndex[activeDotIndex]
    }

    /// Starts/stops the display link and sets the active pill's fill for the current
    /// dwell. Mirrors the SwiftUI `brightFillWidth`: no auto-advance ⇒ a full pill;
    /// auto-advance ⇒ a dot growing to the full pill across the dwell; paused ⇒
    /// frozen at `pausedAt`.
    private func refreshDotsGauge(_ dots: HeroForegroundModel.Dots) {
        guard let active = activeDotView else {
            stopDotsGauge()
            return
        }
        guard dots.autoAdvance, useGauge, let start = dots.dwellStart, dots.dwellDuration > 0 else {
            // Auto-advance off, gauge A/B-disabled, or no dwell: the active pill is a
            // solid full pill with no per-frame ticking.
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
        guard let start = activeDwellStart, let active = activeDotView else {
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
        [logoImageView, titleLabel, ratingLabel, metadataLabel,
         overviewLabel, ratingsHost.view!, pillsContainer]
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
        // `HomeHeroView.uikitContent` already applies the shared Hero/card leading
        // padding to this representable's host. Applying it again here shifted the
        // UIKit foreground one full gutter to the right of the rows and SwiftUI
        // fallback. Layout in host-local coordinates so physical x matches cards.
        let leading: CGFloat = 0
        let trailing: CGFloat = 60
        let maxWidth = max(1, min(bounds.width - leading - trailing, contentMaxWidth))

        // Measure the bottom-anchored block bottom→top.
        var y = bounds.height - bottomMargin

        // Dots (in their glass capsule) at the very bottom of the block, dropped an
        // extra `buttonsToDotsGap` below the buttons so the pills/metadata stay at the
        // lowered column position while the pagination gains more air beneath them.
        if model?.dots != nil {
            layoutDots(bottom: y + buttonsToDotsGap, leading: leading)
            dotsContainer.isHidden = false
            y -= dotsGlassHeight + columnSpacing
        } else {
            dotsContainer.isHidden = true
        }

        // Pills row above the dots.
        let pillsHeight = layoutPills(bottom: y, leading: leading)
        y -= pillsHeight + columnSpacing + pillsTopPadding

        if !ratingsHost.view!.isHidden {
            let size = ratingsHost.sizeThatFits(
                in: CGSize(width: maxWidth, height: 52)
            )
            let h = min(max(size.height, 36), 52)
            ratingsHost.view!.frame = CGRect(
                x: leading,
                y: y - h,
                width: maxWidth,
                height: h
            )
            y -= h + columnSpacing
        }

        // Overview above the pills (bottom-anchored: its bottom sits at y).
        if !overviewLabel.isHidden {
            let size = overviewLabel.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
            let h = min(size.height, ceil(overviewLabel.font.lineHeight * 3))
            overviewLabel.frame = CGRect(x: leading, y: y - h, width: maxWidth, height: h)
            y -= h + columnSpacing
        }

        // Metadata line.
        if !metadataLabel.isHidden || !ratingLabel.isHidden {
            let h: CGFloat = 36
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
            let cap = min(maxWidth, logoMaxWidth)
            let maxH: CGFloat = 160
            let aspect = image.size.height / image.size.width
            // Fit within both the width cap and the height cap, preserving aspect and
            // never upscaling. Crucially, size the frame to the ACTUAL fitted image —
            // if the height cap binds we shrink the width too. Otherwise the frame
            // stays wider than the scaled image and `.scaleAspectFit` centres it,
            // making a tall/narrow logo look shifted right instead of left-aligned.
            var w = min(cap, image.size.width)
            var h = w * aspect
            if h > maxH {
                h = maxH
                w = h / aspect
            }
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
            // Position via bounds+center, not frame: a selected pill carries a 1.06
            // `transform`, and setting `.frame` on a transformed view back-computes a
            // shrunken bounds (width/1.06) and lays its content out in that smaller box
            // before scaling up — which visibly shifts the glyph/text on focus. bounds
            // and center are transform-independent, so the content stays put and only
            // the uniform scale is applied around the centre.
            pill.bounds = CGRect(x: 0, y: 0, width: widths[i], height: height)
            pill.center = CGPoint(x: x + widths[i] / 2, y: height / 2)
            pill.layoutIfNeeded()
            x += widths[i] + pillSpacing
        }
        return height
    }

    private func layoutDots(bottom: CGFloat, leading: CGFloat) {
        guard !currentDotLayout.isEmpty else {
            dotsContainer.isHidden = true
            return
        }
        dotsContainer.isHidden = false

        // Fixed-pitch slots: the active pill is `activeDotWidth` wide, every other dot
        // occupies a full `dotSize` slot (a shrunk edge dot is centred inside its slot)
        // so the row's total width — and thus the glass capsule — never breathes.
        let slotWidths: [CGFloat] = currentDotLayout.map {
            $0.index == activeDotIndex ? activeDotWidth : dotSize
        }
        var rowWidth: CGFloat = 0
        for (i, w) in slotWidths.enumerated() {
            rowWidth += w
            if i < slotWidths.count - 1 { rowWidth += dotSpacing }
        }
        let glassWidth = rowWidth + dotsGlassHPad * 2
        let glassHeight = dotsGlassHeight
        // Centre the capsule across the hero width, matching the SwiftUI hero.
        let glassX = (bounds.width - glassWidth) / 2
        dotsContainer.frame = CGRect(x: glassX, y: bottom - glassHeight, width: glassWidth, height: glassHeight)
        dotsContainer.layer.cornerRadius = 0

        let morph = animateDotsMorph
        animateDotsMorph = false

        // A same-page re-apply (selection / metadata-fade) reaches here with an
        // unchanged layout. Re-running the positioning would snap the dot frames to
        // final and cancel a running page-morph animation, so skip it — the dots are
        // already where they belong. (Only the layout signature matters; the glass
        // capsule frame above is refreshed every pass in case the hero width changed.)
        let signature = [activeDotIndex ?? -1]
            + currentDotLayout.flatMap { [$0.index, $0.size.rank] }
        if !morph && signature == lastDotsSignature { return }
        lastDotsSignature = signature

        // Leading x of each visible slot, in its own (container) coordinate space.
        var slotX: [Int: CGFloat] = [:]
        var cursor = dotsGlassHPad
        for (i, d) in currentDotLayout.enumerated() {
            slotX[d.index] = cursor
            cursor += slotWidths[i] + dotSpacing
        }
        let windowStart = currentDotLayout.first!.index
        let windowEnd = currentDotLayout.last!.index
        let glassH = glassHeight
        let cy = glassH / 2

        // Start entering dots just OUTSIDE the entry edge of the capsule, at their
        // FULL-size (dotSize) height, then let `positionDots` slide them to their slot
        // inside the animation — so a new dot glides in horizontally from the left/right
        // edge (the direction the window scrolled) at full height and fades up from a
        // slight fill, rather than "forming" in place / growing from a corner. This
        // mirrors SwiftUI, where the whole row translates so the newcomer visibly
        // travels in from the edge while its opacity rises.
        let enterEdgeX = dotsScrollForward
            ? glassWidth - dotsGlassHPad + dotSpacing   // just past the right inner edge
            : dotsGlassHPad - dotSize - dotSpacing        // just past the left inner edge
        // A cyclic last↔first wrap replaces the entire visible index window. Starting
        // all eight new views at one edge makes them fan out from a single point.
        // SwiftUI instead treats these as independent insertion/removal transitions,
        // so crossfade each newcomer at its own final slot for this discontinuity.
        let replacesWholeWindow = enteringDotIndices.count > 1
        for idx in enteringDotIndices {
            guard let view = dotViewsByIndex[idx] else { continue }
            let draw = dotSize * view.currentScale
            view.bounds = CGRect(x: 0, y: 0, width: draw, height: draw)
            if replacesWholeWindow, let sx = slotX[idx] {
                view.center = CGPoint(x: sx + dotSize / 2, y: cy)
            } else {
                view.center = CGPoint(x: enterEdgeX + dotSize / 2, y: cy)
            }
            view.alpha = dotEnterStartAlpha
        }
        enteringDotIndices.removeAll()

        // Views that scrolled out of the window: fade them out IN PLACE (again like
        // SwiftUI's removal transition) and remove once faded — but only if they're
        // still outside the window then, so a dot that scrolls back in during rapid
        // reverse paging isn't deleted by a stale completion.
        let leaving = dotViewsByIndex.filter { $0.key < windowStart || $0.key > windowEnd }

        let positionDots = { [self] in
            for d in currentDotLayout {
                guard let view = dotViewsByIndex[d.index] else { continue }
                view.alpha = 1
                if d.index == activeDotIndex {
                    view.bounds = CGRect(x: 0, y: 0, width: activeDotWidth, height: dotSize)
                    view.center = CGPoint(x: slotX[d.index]! + activeDotWidth / 2, y: cy)
                } else {
                    // Shrunk circle centred inside a full-size slot.
                    let draw = dotSize * view.currentScale
                    view.bounds = CGRect(x: 0, y: 0, width: draw, height: draw)
                    view.center = CGPoint(x: slotX[d.index]! + dotSize / 2, y: cy)
                }
                view.layoutIfNeeded()
            }
            // Leaving dots fade in place — keep their current frame, just go transparent.
            for (_, view) in leaving {
                view.alpha = 0
            }
        }
        let cleanup = { [self] in
            for (idx, view) in leaving {
                // Still out of the (latest) window? Then it really left — remove it.
                let start = currentDotLayout.first?.index ?? 0
                let end = currentDotLayout.last?.index ?? -1
                if idx < start || idx > end {
                    view.removeFromSuperview()
                    dotViewsByIndex[idx] = nil
                }
            }
        }
        if morph {
            UIView.animate(withDuration: dotsMorphDuration, delay: 0,
                           options: [.curveEaseInOut, .beginFromCurrentState],
                           animations: positionDots,
                           completion: { _ in cleanup() })
        } else {
            positionDots()
            cleanup()
        }
    }
}

/// Stable ordering of the windowed dot sizes, used to build a cheap layout signature
/// so a same-page re-apply can be detected and skipped (avoids stomping a running
/// page-morph animation).
private extension HeroPagingDots.Size {
    var rank: Int {
        switch self {
        case .full: return 0
        case .medium: return 1
        case .small: return 2
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
        let becameActive = active && !isActive
        isActive = active
        currentScale = scale
        backgroundColor = tint.withAlphaComponent(0.28)
        fill.backgroundColor = tint
        fill.isHidden = !active
        if becameActive, bounds.height > 0 {
            // Seed the active fill as a full-height circle before the enclosing dot
            // morph begins. Otherwise its first layout animates from CGRect.zero,
            // visibly growing from the parent's top-left corner.
            let height = bounds.height
            UIView.performWithoutAnimation {
                fill.bounds = CGRect(x: 0, y: 0, width: height, height: height)
                fill.center = CGPoint(x: height / 2, y: bounds.midY)
                fill.layer.cornerRadius = height / 2
            }
        }
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
        fill.bounds = CGRect(x: 0, y: 0, width: w, height: bounds.height)
        fill.center = CGPoint(x: w / 2, y: bounds.midY)
        fill.layer.cornerRadius = bounds.height / 2
    }
}

/// A `UILabel` with content insets, used for the bordered rating chip.
private final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets.zero
    var fixedHeight: CGFloat?
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(
            width: s.width + insets.left + insets.right,
            height: fixedHeight ?? (s.height + insets.top + insets.bottom)
        )
    }
}
#endif
