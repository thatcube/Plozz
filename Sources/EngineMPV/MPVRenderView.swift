#if canImport(Libmpv) && canImport(UIKit)
import UIKit
import QuartzCore
import Metal

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

    /// Applies the colorimetry for `mode` to this surface, to be called *before*
    /// mpv (re)creates its MoltenVK swapchain on the next `load()`. On tvOS HDR is
    /// expressed purely through the drawable format + BT.2020 PQ/HLG colorspace
    /// (there is no `wantsExtendedDynamicRangeContent`); the actual HDR display
    /// switch is driven separately via `AVDisplayManager`.
    func configure(for mode: MPVHDRMode) {
        pixelFormat = MPVHDR.metalPixelFormat(for: mode)
        colorspace = MPVHDR.colorspace(for: mode)
    }

    /// The format/colorspace the layer actually holds, for diagnostics. Note this
    /// reflects what we *requested*; if MoltenVK overrides the swapchain format
    /// the realized drawable may differ — libplacebo still adapts (via
    /// `target-colorspace-hint`) and degrades to correct SDR rather than failing.
    var realizedColorInfo: (pixelFormat: String, colorspace: String?) {
        (pixelFormat.debugName, colorspace?.name as String?)
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

    /// Invoked whenever the view's `window` changes (including `nil` on removal).
    /// The engine uses this to apply / clear the HDR display-mode switch, which
    /// requires a live `UIWindow` (`avDisplayManager`).
    var onWindowChange: (@MainActor (UIWindow?) -> Void)?

    init(metalLayer: MPVMetalLayer) {
        self.metalLayer = metalLayer
        super.init(frame: .zero)
        backgroundColor = .black
        metalLayer.backgroundColor = UIColor.black.cgColor
        metalLayer.framebufferOnly = false
        metalLayer.contentsScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
        if metalLayer.device == nil {
            metalLayer.device = MTLCreateSystemDefaultDevice()
        }
        let scale = metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        layer.addSublayer(metalLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Resize the render surface to fill the view without animating the frame
        // change (which would lag a frame behind playback during layout passes).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        CATransaction.commit()
    }
}
#endif
