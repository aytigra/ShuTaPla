//
//  HDRImageConfig.swift
//  ShuTaPla
//
//  How one still image's layer is driven: which `contentsGravity` scales it to the surface and
//  whether the layer opts into extended dynamic range. Computed per file from the fit mode, the
//  decoded image's HDR range, and the hosting screen's EDR capability, then applied to the
//  layer-backed view in `ImagePlayerView`.
//
//  The image channel isn't mpv: `ImagePlaybackEngine` decodes a `CGImage` (with the HDR gain map
//  applied / PQ values preserved) and a raw `CALayer` displays it, because only a layer can do
//  aspect-fill and carry the image's HDR colour space to the OS tone-mapper. This type is pure so
//  the fit-mode → gravity map and the EDR-gating decision are unit-testable without a screen.
//

import QuartzCore

/// The layer configuration for one displayed image. See ``decide(fitMode:imageIsHDR:displaySupportsEDR:)``.
///
/// `nonisolated`: a pure value type decided off the main actor and asserted against in a plain
/// (non-`@MainActor`) test suite, so it opts out of the project's default main-actor isolation.
nonisolated struct HDRImageConfig: Equatable {

    /// How the layer scales its contents to the surface bounds.
    var contentsGravity: CALayerContentsGravity
    /// The layer's `preferredDynamicRange`: `.high` engages EDR, `.standard` keeps it SDR.
    var preferredDynamicRange: CALayer.DynamicRange

    /// Decides the layer configuration for a decoded image.
    ///
    /// EDR engages only when the image is HDR **and** the hosting screen can show it — mirroring the
    /// video decision. The gravity comes straight from the fit mode.
    ///
    /// - Parameters:
    ///   - fitMode: how the image is scaled to the surface.
    ///   - imageIsHDR: whether the decoded `CGImage` carries HDR range (see `CGImage.isHDR`).
    ///   - displaySupportsEDR: whether the hosting screen reports EDR headroom > 1.0.
    static func decide(fitMode: ImageFitMode, imageIsHDR: Bool, displaySupportsEDR: Bool) -> HDRImageConfig {
        HDRImageConfig(contentsGravity: gravity(for: fitMode),
                       preferredDynamicRange: imageIsHDR && displaySupportsEDR ? .high : .standard)
    }

    /// The layer gravity for a fit mode: fit letterboxes, cover fills and crops, original is a
    /// centred 1:1 (the case `NSImageView` can't express, which is why a raw layer is used).
    static func gravity(for fitMode: ImageFitMode) -> CALayerContentsGravity {
        switch fitMode {
        case .fit: return .resizeAspect
        case .cover: return .resizeAspectFill
        case .original: return .center
        }
    }
}
