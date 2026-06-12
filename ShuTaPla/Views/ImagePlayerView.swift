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
            .gesture(panGesture.simultaneously(with: zoomGesture))
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
        let scale = transform.scale * magnifyBy

        base(image, in: size)
            .scaleEffect(scale)
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

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($magnifyBy) { value, state, _ in state = value.magnification }
            .onEnded { value in
                engine.transform.scale = max(0.1, engine.transform.scale * value.magnification)
            }
    }
}
