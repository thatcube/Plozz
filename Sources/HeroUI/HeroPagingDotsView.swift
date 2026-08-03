#if canImport(UIKit)
import SwiftUI
import UIKit
import CoreUI
import FeatureHomeCore

/// The hero's paging dots, drawn as Core Animation layers.
///
/// Every part of this animates: the gauge fills the active pill, and on a page
/// change the pill morphs back to a dot while the next dot grows into a pill,
/// with the window of dots sliding under them. Describing that to Core Animation
/// once — rather than recomputing it on each frame — is what lets it run at the
/// display's full rate while the app itself does nothing.
///
/// Layer identity is keyed on the slide index, so a dot that survives a page
/// change keeps its layer and genuinely travels to its new place instead of one
/// dot disappearing and another appearing where it landed.
public final class HeroPagingDotsView: UIView {
    public struct Configuration: Equatable {
        public var count: Int
        public var activeIndex: Int
        public var autoAdvance: Bool
        /// How far through the dwell the gauge already is.
        public var gaugeFraction: CGFloat
        /// Seconds left in the dwell, or `nil` when it is not running — paused,
        /// or auto-advance switched off — in which case the gauge holds still.
        public var gaugeRemaining: TimeInterval?

        public init(
            count: Int,
            activeIndex: Int,
            autoAdvance: Bool,
            gaugeFraction: CGFloat,
            gaugeRemaining: TimeInterval?
        ) {
            self.count = count
            self.activeIndex = activeIndex
            self.autoAdvance = autoAdvance
            self.gaugeFraction = gaugeFraction
            self.gaugeRemaining = gaugeRemaining
        }
    }

    private typealias Metrics = HeroPagingIndicatorMetrics

    /// One track layer per slide index, plus the fill that lives inside it.
    ///
    /// The fill is a CHILD of its dot rather than a single layer repositioned
    /// between them. A shared fill carried the previous slide's width to the
    /// next dot — so a page change flashed the new dot full before the ramp
    /// restarted it — and it could not take part in the morph, because the dots
    /// slide to their new places while it was being moved by hand.
    private var dotLayers: [Int: CALayer] = [:]
    private var fillLayers: [Int: CALayer] = [:]
    private var configuration: Configuration?
    private var tint: UIColor = .white
    /// The ramp currently stated to Core Animation, so a restatement mid-slide
    /// can pick up where that one has reached instead of jumping backwards.
    private var statedRamp: (index: Int, fraction: CGFloat, remaining: TimeInterval, at: Date)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func apply(_ configuration: Configuration, tint: UIColor) {
        let previous = self.configuration
        let tintChanged = self.tint != tint
        self.configuration = configuration
        self.tint = tint

        let pageChanged = previous?.activeIndex != configuration.activeIndex
            || previous?.count != configuration.count
        if previous?.count != configuration.count { invalidateIntrinsicContentSize() }
        // A page change is the only thing worth animating the layout for. A
        // gauge tick or a re-render with the same page must not restart the
        // morph, or the dots would keep sliding on the spot.
        layoutDots(animated: pageChanged && previous != nil, tintChanged: tintChanged)

        let gaugeChanged = pageChanged
            || previous?.gaugeRemaining != configuration.gaugeRemaining
            || previous?.autoAdvance != configuration.autoAdvance
        if gaugeChanged { refreshGauge(restarting: pageChanged) }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layoutDots(animated: false, tintChanged: true)
        refreshGauge(restarting: false)
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: contentWidth(), height: Metrics.dotSize)
    }

    /// Width of the dot window as drawn: one wide pill, the rest circles, plus
    /// the gaps. Reported so the row sizes itself rather than depending on
    /// whatever width it happens to be given.
    private func contentWidth() -> CGFloat {
        guard let configuration, configuration.count > 0 else { return 0 }
        let visible = min(configuration.count, Metrics.maxVisible)
        let others = CGFloat(max(visible - 1, 0))
        return others * Metrics.dotSize
            + Metrics.activeWidth
            + others * Metrics.dotSpacing
    }

    // MARK: Layout

    private struct Slot {
        let dot: HeroPagingDots.Dot
        let frame: CGRect
        let isActive: Bool
    }

    private func slots() -> [Slot] {
        guard let configuration, configuration.count > 0, bounds.height > 0 else {
            return []
        }
        let layout = HeroPagingDots.layout(
            count: configuration.count,
            index: configuration.activeIndex,
            maxVisible: Metrics.maxVisible,
            edgeShrink: Metrics.edgeShrink
        )
        // Centre the row. The window of dots changes width as the active pill
        // grows and shrinks, and laying out from zero pinned that change to the
        // leading edge, so the whole row shifted left instead of staying put.
        var totalWidth: CGFloat = 0
        for dot in layout {
            let isActive = dot.index == configuration.activeIndex
            totalWidth += isActive ? Metrics.activeWidth : Metrics.dotSize
        }
        totalWidth += Metrics.dotSpacing * CGFloat(max(layout.count - 1, 0))

        var x = ((bounds.width - totalWidth) / 2).rounded()
        var result: [Slot] = []
        for dot in layout {
            let isActive = dot.index == configuration.activeIndex
            let slotWidth = isActive ? Metrics.activeWidth : Metrics.dotSize
            let scale = Metrics.scale(for: dot.size)
            let size = CGSize(
                width: isActive ? Metrics.activeWidth : Metrics.dotSize * scale,
                height: isActive ? Metrics.dotSize : Metrics.dotSize * scale
            )
            let frame = CGRect(
                x: x + (slotWidth - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            result.append(Slot(dot: dot, frame: frame, isActive: isActive))
            x += slotWidth + Metrics.dotSpacing
        }
        return result
    }

    private func layoutDots(animated: Bool, tintChanged: Bool) {
        let slots = self.slots()
        let liveIndices = Set(slots.map(\.dot.index))

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(Metrics.morphDuration)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeInEaseOut)
            )
        }

        for slot in slots {
            let dotLayer = dotLayers[slot.dot.index] ?? makeDotLayer(at: slot.frame)
            if dotLayers[slot.dot.index] == nil {
                dotLayers[slot.dot.index] = dotLayer
                layer.addSublayer(dotLayer)
            }
            if tintChanged {
                dotLayer.backgroundColor = tint.withAlphaComponent(0.28).cgColor
            }
            dotLayer.frame = slot.frame
            dotLayer.cornerRadius = slot.frame.height / 2
            dotLayer.opacity = 1

            // The fill rides inside its dot, so the morph carries it for free.
            let fill = fillLayers[slot.dot.index] ?? makeFillLayer(in: dotLayer)
            if fillLayers[slot.dot.index] == nil {
                fillLayers[slot.dot.index] = fill
            }
            if tintChanged { fill.backgroundColor = tint.cgColor }
            fill.isHidden = !slot.isActive
            // Geometry only — never animated, or the fill would slide around
            // inside its dot during the page morph.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            HeroPagingGauge.prepare(
                fill,
                height: slot.frame.height,
                midY: slot.frame.height / 2
            )
            CATransaction.commit()
            if !slot.isActive {
                // An inactive dot holds no gauge; clearing it means the dot this
                // slide moves to starts empty instead of inheriting a width.
                HeroPagingGauge.setStatic(
                    fill,
                    fraction: 0,
                    trackWidth: slot.frame.width,
                    height: slot.frame.height
                )
            }
        }

        // Dots that scrolled out of the window leave rather than vanish.
        for (index, dotLayer) in dotLayers where !liveIndices.contains(index) {
            dotLayers[index] = nil
            fillLayers[index] = nil
            if animated {
                dotLayer.opacity = 0
                CATransaction.setCompletionBlock { dotLayer.removeFromSuperlayer() }
            } else {
                dotLayer.removeFromSuperlayer()
            }
        }

        CATransaction.commit()
    }

    private func makeDotLayer(at frame: CGRect) -> CALayer {
        let dotLayer = CALayer()
        // Seeded at its destination so a newly created dot doesn't animate in
        // from the origin on its first layout.
        dotLayer.frame = frame
        dotLayer.cornerRadius = frame.height / 2
        dotLayer.backgroundColor = tint.withAlphaComponent(0.28).cgColor
        dotLayer.opacity = 0
        return dotLayer
    }

    private func makeFillLayer(in dotLayer: CALayer) -> CALayer {
        let fill = CALayer()
        fill.backgroundColor = tint.cgColor
        fill.isHidden = true
        dotLayer.addSublayer(fill)
        return fill
    }

    // MARK: Gauge

    private func refreshGauge(restarting: Bool) {
        guard let configuration,
              let active = slots().first(where: \.isActive),
              let fill = fillLayers[active.dot.index] else { return }

        fill.isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        HeroPagingGauge.prepare(
            fill,
            height: active.frame.height,
            midY: active.frame.height / 2
        )
        CATransaction.commit()

        guard configuration.autoAdvance, let remaining = configuration.gaugeRemaining else {
            // Auto-advance off, or the dwell is paused: hold where it stands.
            statedRamp = nil
            HeroPagingGauge.setStatic(
                fill,
                fraction: configuration.autoAdvance ? configuration.gaugeFraction : 1,
                trackWidth: active.frame.width,
                height: active.frame.height
            )
            return
        }
        let now = Date()
        var fraction = configuration.gaugeFraction
        // Only a page change may send the gauge back to the start.
        if !restarting, let stated = statedRamp, stated.index == active.dot.index {
            fraction = max(
                fraction,
                HeroPagingGauge.projectedFraction(
                    from: stated.fraction,
                    started: stated.at,
                    remaining: stated.remaining,
                    now: now
                )
            )
        }
        statedRamp = (active.dot.index, fraction, remaining, now)
        HeroPagingGauge.animate(
            fill,
            from: fraction,
            remaining: remaining,
            trackWidth: active.frame.width,
            height: active.frame.height
        )
    }
}
#endif

/// Hosts ``HeroPagingDotsView`` so a SwiftUI hero can use it.
///
/// The dots need no SwiftUI state of their own: everything they show is either
/// given here or already running inside Core Animation, so a re-render only
/// re-states the destination rather than driving a frame.
public struct HeroPagingDotsRepresentable: UIViewRepresentable {
    public let configuration: HeroPagingDotsView.Configuration
    public let tint: UIColor

    public init(
        configuration: HeroPagingDotsView.Configuration,
        tint: UIColor
    ) {
        self.configuration = configuration
        self.tint = tint
    }

    public func makeUIView(context: Context) -> HeroPagingDotsView {
        let view = HeroPagingDotsView(frame: .zero)
        view.apply(configuration, tint: tint)
        return view
    }

    public func updateUIView(_ view: HeroPagingDotsView, context: Context) {
        view.apply(configuration, tint: tint)
    }
}
