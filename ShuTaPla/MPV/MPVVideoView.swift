//
//  MPVVideoView.swift
//  ShuTaPla
//
//  The OpenGL surface the app owns and mpv renders into through the libmpv render API.
//  mpv has no window of its own: it draws on demand into this layer's framebuffer whenever
//  we call `mpv_render_context_render`. The layer defaults to SDR and opts into EDR per file:
//  the engine applies an `HDRVideoConfig` once a file's colour params are decoded, tagging the
//  float framebuffer with a PQ colour space so HDR clips can exceed SDR white on capable displays.
//
//  The CGL context is created eagerly (not via CoreAnimation's lazy `copyCGLContext`), so the
//  mpv render context exists before the first file's video output is initialised — otherwise
//  mpv reports "No render context set" and falls back to audio-only for that file. The layer
//  then hands the same context back to CoreAnimation for compositing.
//
//  OpenGL is deprecated on macOS but remains available (it runs over Metal on Apple Silicon);
//  the libmpv render API exposes only OpenGL and software targets, so this is the embedding path.
//

import AppKit
import QuartzCore
import OpenGL
import OpenGL.GL3

/// The `NSView` that hosts the mpv render layer. It backs itself with an ``MPVOpenGLLayer`` and
/// keeps the layer's scale in step with the display; all drawing happens inside the layer.
final class MPVVideoView: NSView {

    private let glLayer = MPVOpenGLLayer()

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

    override func makeBackingLayer() -> CALayer { glLayer }

    /// Connects the layer to the client and creates its render context. Called once by the
    /// engine right after it creates both.
    func attach(_ client: MPVClient) { glLayer.attach(client) }

    /// Applies the decided colour output to the layer (EDR opt-in + framebuffer colour space).
    /// The engine calls this per file once the decoded params yield an ``HDRVideoConfig``.
    func apply(_ config: HDRVideoConfig) { glLayer.apply(config) }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        glLayer.contentsScale = window?.backingScaleFactor ?? glLayer.contentsScale
    }
}

/// A `CAOpenGLLayer` that hands its framebuffer to libmpv each frame.
///
/// It owns an explicit CGL context, created up front in `attach(_:)` together with the mpv
/// render context, and serves that same context to CoreAnimation through
/// `copyCGLContext(forPixelFormat:)`. mpv's render-update callback marks the layer for display,
/// and `draw(inCGLContext:…)` renders the current frame into the framebuffer CoreAnimation bound.
///
/// `nonisolated`: CoreAnimation invokes the context/draw overrides on its own render thread,
/// not the main actor, so the type opts out of the project's default `@MainActor` isolation.
/// Everything it touches off that thread — `MPVClient`'s render methods and `CALayer`'s own
/// drawing API — is itself safe to call from there.
nonisolated final class MPVOpenGLLayer: CAOpenGLLayer {

    weak var client: MPVClient?

    private var cglPixelFormat: CGLPixelFormatObj?
    private var cglContext: CGLContextObj?

    override init() {
        super.init()
        isAsynchronous = false                 // redraw on demand, driven by mpv's update callback
        isOpaque = true
        needsDisplayOnBoundsChange = true
        apply(.sdr)                            // SDR until a file's decoded params engage EDR
        createContext()
    }

    override init(layer: Any) { super.init(layer: layer) }   // presentation-copy: no own context
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        createContext()
    }

    deinit {
        if let cglContext { CGLReleaseContext(cglContext) }
        if let cglPixelFormat { CGLReleasePixelFormat(cglPixelFormat) }
    }

    // MARK: - Context

    /// Builds the CGL pixel format and context once, headless (no display mask). A floating-point
    /// backbuffer lets EDR values exceed 1.0.
    private func createContext() {
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            kCGLPFAAllowOfflineRenderers,
            kCGLPFAColorFloat,
            kCGLPFAColorSize, CGLPixelFormatAttribute(64),
            CGLPixelFormatAttribute(0),
        ]
        var format: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attributes, &format, &count)
        guard let format else { return }
        cglPixelFormat = format
        var context: CGLContextObj?
        CGLCreateContext(format, nil, &context)
        cglContext = context
    }

    /// Wires the client and creates its render context against our GL context — eagerly, so the
    /// context exists before the first file's video output is initialised.
    func attach(_ client: MPVClient) {
        self.client = client
        guard let cglContext else { return }
        CGLSetCurrentContext(cglContext)
        // `nonisolated(unsafe)`: the layer isn't `Sendable`, but `setNeedsDisplay()` is safe to
        // call across threads and the layer outlives the render context.
        nonisolated(unsafe) let layer = self
        client.createRenderContext {
            // Fires on an mpv thread; bounce to the main thread to mark for redraw.
            DispatchQueue.main.async { layer.setNeedsDisplay() }
        }
    }

    /// Tags the layer for the decided colour output: EDR opt-in and the framebuffer colour space
    /// (SDR sRGB, or a PQ space that hands HDR values to the OS tone-mapper). Marks for redraw so
    /// the change takes on the current frame.
    func apply(_ config: HDRVideoConfig) {
        wantsExtendedDynamicRangeContent = config.extendedDynamicRange
        colorspace = config.colorSpace.cgColorSpace
        setNeedsDisplay()
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        if let cglPixelFormat { return CGLRetainPixelFormat(cglPixelFormat) }
        return super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
        if let cglContext { return CGLRetainContext(cglContext) }
        return super.copyCGLContext(forPixelFormat: pixelFormat)
    }

    // MARK: - Drawing

    override func draw(
        inCGLContext context: CGLContextObj,
        pixelFormat: CGLPixelFormatObj,
        forLayerTime layerTime: CFTimeInterval,
        displayTime: UnsafePointer<CVTimeStamp>?
    ) {
        CGLSetCurrentContext(context)

        // mpv renders into whichever framebuffer CoreAnimation bound for this layer.
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &fbo)

        let scale = contentsScale
        let width = GLint(max(bounds.width * scale, 1))
        let height = GLint(max(bounds.height * scale, 1))
        client?.render(fbo: fbo, width: width, height: height)

        super.draw(inCGLContext: context, pixelFormat: pixelFormat,
                   forLayerTime: layerTime, displayTime: displayTime)
        client?.reportSwap()
    }
}

nonisolated extension HDRVideoConfig.ColorSpace {
    /// The concrete `CGColorSpace` the render layer tags its float framebuffer with. The decision
    /// stays a pure enum (unit-testable without a GL surface); this is where it resolves to a real
    /// colour space.
    var cgColorSpace: CGColorSpace? {
        switch self {
        case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3_PQ: CGColorSpace(name: CGColorSpace.displayP3_PQ)
        case .itur_2100_PQ: CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        }
    }
}
