//
//  BrowsingFolderURL.swift
//  ShuTaPla
//
//  The resolved folder URL a file surface (the Manager browser, an overlay's list) holds open via a
//  reference-counted scoped-access session for its lifetime. A surface publishes it here; the leaf
//  cells (`GalleryCell`, `FileRowView`) read it and hand it to the thumbnail/metadata services so the
//  per-file read appends the relative path to this one URL instead of resolving the folder bookmark
//  per file. `nil` when no session is open — the services then resolve per file as before.
//

import SwiftUI
import SwiftData

extension EnvironmentValues {
    @Entry var browsingFolderURL: URL?
}

/// Holds one scoped-access session open for `playlist`'s folder for as long as the surface shows it,
/// and publishes the resolved URL through `browsingFolderURL`.
private struct BrowsingSessionModifier: ViewModifier {
    let playlist: Playlist?
    let folderAccess: ScopedFolderAccess

    /// The open session's playlist id and resolved URL. The id is kept so the published value can be
    /// gated on the *currently shown* playlist.
    private struct Session { let id: PersistentIdentifier; let url: URL }
    @State private var session: Session?

    /// The URL handed to the cells — the open one only while it belongs to the shown playlist. The
    /// `@State` set inside the async task lags the first render after a switch, so gating on the id
    /// keeps the previous playlist's URL from ever reaching the new one's cells (they see `nil` and
    /// resolve per file until the new session's URL is published).
    private var publishedURL: URL? {
        guard let id = playlist?.persistentModelID else { return nil }
        return session?.id == id ? session?.url : nil
    }

    func body(content: Content) -> some View {
        content
            .environment(\.browsingFolderURL, publishedURL)
            .task(id: playlist?.persistentModelID) {
                guard let playlist, let url = folderAccess.beginBrowsing(playlist) else { return }
                let id = playlist.persistentModelID
                session = Session(id: id, url: url)
                defer {
                    folderAccess.endBrowsing(playlist)
                    if session?.id == id { session = nil }
                }
                // Hold the grant for the surface's lifetime: park until a playlist switch (new id) or
                // the surface's removal cancels this task, then release in the `defer`.
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            }
    }
}

extension View {
    /// Opens a reference-counted scoped-access session for `playlist`'s folder held for as long as this
    /// file surface shows it, publishing the resolved folder URL through `browsingFolderURL` so the
    /// surface's cells skip the per-file bookmark resolve. A `nil` playlist opens no session.
    func browsingSession(for playlist: Playlist?, folderAccess: ScopedFolderAccess) -> some View {
        modifier(BrowsingSessionModifier(playlist: playlist, folderAccess: folderAccess))
    }
}
