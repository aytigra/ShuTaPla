//
//  MediaPreviewView.swift
//  ShuTaPla
//
//  The Manager "peek": a single file — video or image — shown in a floating card centered
//  over a dimmed backdrop, controls-free. The card is sized to the media's aspect ratio and
//  fit within the content area minus a margin; the backdrop is inert (dismissal is
//  keyboard-only, routed by `HotkeyRouter`). Mounted inside the safe area by `RootView`, so
//  it stops at the toolbar rather than drawing under the window chrome.
//
//  The card appears only once the media's `contentSize` is known — so it fades in at its true
//  shape rather than animating through a placeholder size. That size is a video's cached pixel
//  dimensions or an image's decoded size (both known at or right after mount), or, on a
//  first-ever preview of a video, mpv's `dwidth`/`dheight` a beat after load. It reads the
//  isolated `MediaPreview` engine, never the coordinator.
//

import SwiftUI
import AppKit

struct MediaPreviewView: View {
    @Environment(MediaPreview.self) private var preview

    private static let backdropOpacity = 0.55
    private static let edgeInset: CGFloat = 40
    private static let cornerRadius: CGFloat = 12
    private static let progressStripHeight: CGFloat = 3

    /// The card's fallback shape while a file with no cached dimensions downloads — just enough to
    /// carry the placeholder, latched to the media's true shape once it arrives.
    private static let placeholderCardSize = CGSize(width: 600, height: 600)

    /// The card's aspect ratio, latched from `preview.contentSize`. It only ever takes a real
    /// size and never resets to `nil`, so the card stays structurally present through the close.
    /// `close()` clears `contentSize` the instant it clears `isOpen`; if the card's presence
    /// tracked `contentSize` it would drop out of the layer at exit — while the backdrop kept
    /// fading with `RootView`'s transition — and the two would fall out of sync (smooth over the
    /// side panel, a white snap over the centered card). Latching keeps the whole layer one unit
    /// that fades out together. Fresh per open, since the view unmounts on close.
    @State private var cardSize: CGSize?

    var body: some View {
        ZStack {
            Color.black.opacity(Self.backdropOpacity)   // inert dimming; keyboard-only dismissal
            if let cardSize {
                card
                    .aspectRatio(cardSize, contentMode: .fit)
                    .padding(Self.edgeInset)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))   // entrance only
            }
        }
        .animation(.easeInOut(duration: 0.2), value: cardSize)
        .onChange(of: preview.contentSize, initial: true) { _, size in
            // Latch the media's shape; never back to nil. `initial: true` because a video's
            // cached pixel dimensions make `contentSize` known already at mount — without it the
            // card would never appear for an already-sized preview, since no *change* follows.
            if let size { cardSize = size }
        }
        .onChange(of: preview.cloudPendingFile != nil, initial: true) { _, pending in
            // A file with no cached dimensions has no `contentSize` while it downloads, so give the
            // card a default shape to carry the placeholder; the media's real shape latches on arrival.
            if pending, cardSize == nil { cardSize = Self.placeholderCardSize }
        }
    }

    /// The media at the card's aspect ratio, corners rounded and lifted off the backdrop.
    @ViewBuilder
    private var card: some View {
        ZStack(alignment: .bottom) {
            if let pending = preview.cloudPendingFile {
                CloudDownloadingPlaceholder(file: pending)
            } else {
                switch preview.mediaType {
                case .video:
                    PreviewVideoView()
                    progressStrip
                case .image:
                    if let image = preview.image {
                        Image(nsImage: image).resizable()
                    }
                case .audio, .none:
                    EmptyView()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .shadow(radius: 24)
    }

    /// A non-interactive fill scaled to the video's play position, growing from the leading
    /// edge along the card's bottom. Hidden until the duration is known.
    @ViewBuilder
    private var progressStrip: some View {
        let duration = preview.duration
        if duration > 0 {
            GeometryReader { proxy in
                Rectangle()
                    .fill(.white.opacity(0.8))
                    .frame(width: proxy.size.width * min(1, preview.currentTime / duration))
            }
            .frame(height: Self.progressStripHeight)
        }
    }
}

/// Surfaces the preview engine's video render view. Separate from `VideoPlayerView`, which
/// reads the coordinator: the preview runs on its own engine, outside the channel bookkeeping.
private struct PreviewVideoView: NSViewRepresentable {
    @Environment(MediaPreview.self) private var preview

    func makeNSView(context: Context) -> NSView {
        preview.videoRenderView ?? NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
