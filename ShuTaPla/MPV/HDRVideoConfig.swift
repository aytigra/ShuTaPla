//
//  HDRVideoConfig.swift
//  ShuTaPla
//
//  How one video's colour output is driven: whether the render layer opts into extended dynamic
//  range and, if so, in which colour space, plus the matching `target-*` options for the mpv
//  client. Computed per file from the decoded `video-params` and the hosting screen's EDR
//  capability, then applied to both the client (`target-prim`/`target-trc`/`target-peak`) and
//  the layer (`wantsExtendedDynamicRangeContent` + `colorspace`).
//
//  In the libmpv render API path mpv owns no window and can't discover that our layer is
//  EDR-capable, so left alone it tone-maps HDR (PQ/HLG) down to SDR before the frame reaches our
//  framebuffer. This config is what tells mpv to instead emit the PQ signal into the float
//  backbuffer and tags the layer with the PQ colour space the OS tone-mapper needs — mirroring
//  IINA's `requestEdrMode()` for the same architecture.
//
//  The type is pure: it names its layer colour space as an enum rather than a `CGColorSpace`, so
//  the decision is unit-testable without a GL surface. The layer maps the case to a concrete
//  `CGColorSpace` when it applies the config.
//

/// The rendering configuration for one video's colour output. See ``decide(gamma:primaries:displaySupportsEDR:)``.
///
/// `nonisolated`: a pure value type computed off the main actor by the layer/client wiring and
/// asserted against in a plain (non-`@MainActor`) test suite, so it opts out of the project's
/// default main-actor isolation.
nonisolated struct HDRVideoConfig: Equatable {

    /// The CG colour space the render layer tags its float framebuffer with.
    enum ColorSpace: Equatable {
        /// Standard-range output — the layer's SDR default (`CGColorSpace.sRGB`).
        case sRGB
        /// PQ in the Display P3 gamut (`CGColorSpace.displayP3_PQ`).
        case displayP3_PQ
        /// PQ in the Rec.2020 gamut (`CGColorSpace.itur_2100_PQ`).
        case itur_2100_PQ
    }

    /// Whether the layer sets `wantsExtendedDynamicRangeContent`.
    var extendedDynamicRange: Bool
    /// The layer's framebuffer colour space.
    var colorSpace: ColorSpace
    /// mpv `target-prim`: the output primaries, or `auto` to pass content through unchanged.
    var targetPrimaries: String
    /// mpv `target-trc`: the output transfer function, or `auto`.
    var targetTransfer: String
    /// mpv `target-peak`: the output peak luminance, or `auto` (passthrough — brightness tuning
    /// is a later step).
    var targetPeak: String

    /// Standard dynamic range: no EDR, sRGB layer, and `auto` targets so mpv tone-maps as it would
    /// by default. The result for SDR content, non-HDR primaries, or an SDR display.
    static let sdr = HDRVideoConfig(extendedDynamicRange: false, colorSpace: .sRGB,
                                    targetPrimaries: "auto", targetTransfer: "auto", targetPeak: "auto")

    /// Decides the output configuration for a decoded video.
    ///
    /// EDR engages only when the display can show it and the content is HDR in a wide gamut:
    /// `gamma` is PQ or HLG **and** `primaries` is Display P3 or Rec.2020. mpv is then told to emit
    /// that gamut in PQ (`target-trc = pq`) into the float backbuffer rather than tone-mapping to
    /// SDR, and the layer is tagged with the matching PQ colour space so the OS tone-mapper takes it
    /// to real EDR. Everything else — SDR content, `bt.709`, unknown primaries, or a display without
    /// EDR — returns ``sdr``.
    ///
    /// - Parameters:
    ///   - gamma: mpv `video-params/gamma` (transfer function), e.g. `pq`, `hlg`, `bt.1886`.
    ///   - primaries: mpv `video-params/primaries`, e.g. `display-p3`, `bt.2020`, `bt.709`.
    ///   - displaySupportsEDR: whether the hosting screen reports EDR headroom > 1.0.
    static func decide(gamma: String, primaries: String, displaySupportsEDR: Bool) -> HDRVideoConfig {
        guard displaySupportsEDR, gamma == "pq" || gamma == "hlg" else { return .sdr }
        switch primaries {
        case "display-p3":
            return HDRVideoConfig(extendedDynamicRange: true, colorSpace: .displayP3_PQ,
                                  targetPrimaries: "display-p3", targetTransfer: "pq", targetPeak: "auto")
        case "bt.2020":
            return HDRVideoConfig(extendedDynamicRange: true, colorSpace: .itur_2100_PQ,
                                  targetPrimaries: "bt.2020", targetTransfer: "pq", targetPeak: "auto")
        default:
            return .sdr
        }
    }
}
