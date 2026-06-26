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

struct ImagePlayerView: View {
    @Environment(PlaybackCoordinator.self) private var coordinator

    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var magnifyBy: CGFloat = 1
    @GestureState private var magnifyAnchor: UnitPoint = .center

    /// Floor for the zoom scale, applied to both the live preview and the committed
    /// value so a pinch can't drive the image toward zero and snap back on release.
    private static let minScale: CGFloat = 0.1

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
            .gesture(panGesture.simultaneously(with: zoomGesture(in: proxy.size)))
            // A click (no drag) toggles play/pause; a double click stops. Pan needs a 10pt
            // drag to engage, so a stationary click falls through to the tap.
            .playerContentClick()
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func imageLayer(_ image: NSImage, in size: CGSize) -> some View {
        let transform = engine.transform
        let offset = CGSize(
            width: transform.offset.width + dragTranslation.width,
            height: transform.offset.height + dragTranslation.height
        )
        let scale = max(Self.minScale, transform.scale * magnifyBy)

        base(image, in: size)
            // Zoom about the pinch point during the gesture (anchor settles back to
            // center when idle), so the content under the fingers stays put.
            .scaleEffect(scale, anchor: magnifyAnchor)
            .offset(offset)
    }

    /// The image at its fit-mode size before pan/zoom is applied.
    @ViewBuilder
    private func base(_ image: NSImage, in size: CGSize) -> some View {
        switch engine.fitMode {
        case .fit:
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
        case .cover:
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
        case .original:
            Image(nsImage: image)
        }
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in state = value.translation }
            .onEnded { value in
                engine.transform.offset.width += value.translation.width
                engine.transform.offset.height += value.translation.height
            }
    }

    private func zoomGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($magnifyBy) { value, state, _ in state = value.magnification }
            .updating($magnifyAnchor) { value, state, _ in state = value.startAnchor }
            .onEnded { value in
                let newScale = max(Self.minScale, engine.transform.scale * value.magnification)
                // The live preview scaled about the pinch point; the committed transform
                // scales about the center. Fold the difference into the offset so the
                // image doesn't jump when the gesture hands back to the centered render.
                let anchor = value.startAnchor
                engine.transform.offset.width += (anchor.x - 0.5) * size.width * (1 - newScale)
                engine.transform.offset.height += (anchor.y - 0.5) * size.height * (1 - newScale)
                engine.transform.scale = newScale
            }
    }
}
