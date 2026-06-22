#if canImport(Libmpv) && canImport(UIKit)
import UIKit
import QuartzCore

/// A `CAMetalLayer` subclass handed to libmpv as its render surface (`wid`).
///
/// libmpv renders on tvOS via `vo=gpu-next` over Vulkan → MoltenVK → Metal, and
/// MoltenVK presents into this `CAMetalLayer`. The `drawableSize` override is the
/// upstream MPVKit workaround for a MoltenVK quirk where the drawable size is
/// momentarily forced to `1x1` to complete a presentation, which otherwise
/// causes flicker / a stuck 1x1 surface.
/// See https://github.com/mpv-player/mpv/pull/13651
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

/// The engine's **bare** video-output surface: a plain `UIView` that hosts the
/// `MPVMetalLayer` libmpv draws into. It carries no transport chrome — the shared
/// player overlay (`CustomPlayerContainer`) hosts this view and layers all UI on
/// top, exactly like the VLCKit and native engines.
///
/// The hosted metal layer is owned by the engine (so its pointer can be handed to
/// mpv as `wid` before the view is ever added to a hierarchy) and is added here as
/// a sublayer, kept sized to the view's bounds — mirroring MPVKit's reference
/// tvOS player.
final class MPVRenderView: UIView {
    private let metalLayer: MPVMetalLayer

    init(metalLayer: MPVMetalLayer) {
        self.metalLayer = metalLayer
        super.init(frame: .zero)
        backgroundColor = .black
        metalLayer.backgroundColor = UIColor.black.cgColor
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
        layer.addSublayer(metalLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Resize the render surface to fill the view without animating the frame
        // change (which would lag a frame behind playback during layout passes).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
        metalLayer.contentsScale = scale
        CATransaction.commit()
    }
}
#endif
