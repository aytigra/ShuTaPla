import AppKit
import QuartzCore

/// The `NSView` mpv renders into.
///
/// mpv (via `--gpu-context=moltenvk`) draws through Vulkan → MoltenVK → Metal onto this view's
/// `CAMetalLayer`. The view itself issues no draw calls; it owns the surface, keeps the layer's
/// drawable size in step with the backing scale on resize/display change, and opts the layer into
/// EDR so mpv's HDR tone-mapping can pass through to capable displays.
///
/// The owning `MPVClient` is created with this view's pointer as its `wid`, which mpv requires
/// before initialization — so construct the view first, then the client.
final class MPVMetalView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    /// Back the view with a `CAMetalLayer` rather than the default `CALayer`.
    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false           // mpv/MoltenVK needs to read back the drawable
        layer.wantsExtendedDynamicRangeContent = true
        layer.contentsScale = window?.backingScaleFactor ?? 2.0
        return layer
    }

    var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    /// The pointer handed to mpv as its `wid`.
    var windowID: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    // MARK: - Surface sizing

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let metalLayer else { return }
        let scale = window?.backingScaleFactor ?? metalLayer.contentsScale
        metalLayer.contentsScale = scale
        let size = bounds.size
        metalLayer.drawableSize = CGSize(width: max(size.width * scale, 1),
                                         height: max(size.height * scale, 1))
    }
}
