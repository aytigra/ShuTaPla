//
//  ImagePlayerView.swift
//  ShuTaPla
//
//  Displays the image engine's current image, scaled per its fit mode, with live
//  pan and zoom. Gesture deltas are previewed while a gesture is in progress and
//  committed into the engine's `transform` on end, so a new file (which resets the
//  transform to identity) always starts un-panned and un-zoomed.
//

import SwiftUI
import AppKit

struct ImagePlayerView: View {
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(\.displayScale) private var displayScale

    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var magnifyBy: CGFloat = 1
    @GestureState private var magnifyAnchor: UnitPoint = .center

    /// Floor for the zoom scale, applied to both the live preview and the committed value.
    /// `1` is natural size — the surface fit in `.fit`/`.cover`, 1:1 in `.original` — so a pinch
    /// can't shrink the picture below it (zooming out smaller than natural isn't useful).
    private static let minScale: CGFloat = 1

    private var engine: ImagePlaybackEngine { coordinator.imageEngine }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let image = engine.currentImage {
                    imageLayer(image, in: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(panGesture(in: proxy.size).simultaneously(with: zoomGesture(in: proxy.size)))
            // A click (no drag) toggles play/pause; a double click stops. Pan needs a 10pt
            // drag to engage, so a stationary click falls through to the tap.
            .playerContentClick()
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func imageLayer(_ image: CGImage, in size: CGSize) -> some View {
        // Preview and commit run the same math, so the render never has to reconcile an
        // anchor difference: zoom about the pinch point (kept fixed under the fingers), then
        // apply the live pan, always scaling about `.center`.
        let preview = engine.transform
            .zoomed(by: magnifyBy, about: pinchCenter(magnifyAnchor, in: size), minScale: Self.minScale)
            .panned(by: dragTranslation)

        base(image, in: size)
            .scaleEffect(preview.scale, anchor: .center)
            .offset(preview.offset)
    }

    /// The image at its fit-mode size before pan/zoom is applied. The `contentsGravity` of the EDR
    /// layer does the fit/cover scaling within the surface-sized frame; `.original` frames to the
    /// image's natural point size so pan/zoom can roam a picture larger than the surface.
    private func base(_ image: CGImage, in size: CGSize) -> some View {
        let frame = baseFrame(in: size)
        return EDRImageLayer(image: image, fitMode: engine.fitMode)
            .frame(width: frame.width, height: frame.height)
    }

    /// The base frame the transform's clamp resolves against — the picture's own point size in
    /// `.original`, the surface otherwise. `size` when no image is loaded (a harmless identity).
    private func baseFrame(in size: CGSize) -> CGSize {
        guard let image = engine.currentImage else { return size }
        return engine.fitMode.baseSize(
            imagePixelSize: CGSize(width: image.width, height: image.height),
            surface: size,
            displayScale: displayScale
        )
    }

    /// The pinch centre in screen coordinates (origin at the viewport centre) for a `UnitPoint`.
    private func pinchCenter(_ anchor: UnitPoint, in size: CGSize) -> CGSize {
        CGSize(width: (anchor.x - 0.5) * size.width, height: (anchor.y - 0.5) * size.height)
    }

    // MARK: - Gestures

    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in state = value.translation }
            .onEnded { value in
                engine.transform = engine.transform
                    .panned(by: value.translation)
                    .clamped(frame: baseFrame(in: size), viewport: size)
            }
    }

    private func zoomGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($magnifyBy) { value, state, _ in state = value.magnification }
            .updating($magnifyAnchor) { value, state, _ in state = value.startAnchor }
            .onEnded { value in
                engine.transform = engine.transform
                    .zoomed(by: value.magnification, about: pinchCenter(value.startAnchor, in: size), minScale: Self.minScale)
                    .clamped(frame: baseFrame(in: size), viewport: size)
            }
    }
}
