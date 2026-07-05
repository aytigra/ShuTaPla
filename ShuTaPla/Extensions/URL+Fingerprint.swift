//
//  URL+Fingerprint.swift
//  ShuTaPla
//
//  A cheap, content-derived identity for a media file, used to key the thumbnail
//  cache and to spot the same file referenced by two playlists at different folder
//  depths. Reads a fixed head and tail window rather than hashing gigabytes of video.
//

import Foundation
import CryptoKit

extension URL {
    /// A cheap, content-derived identity for a media file: stable across rename,
    /// move, and copy, and independent of which folder (or playlist) references
    /// it. Hashes the byte size together with the head and tail windows of the
    /// file — enough to distinguish files without reading gigabytes of video.
    /// `nil` when the file can't be opened.
    nonisolated func contentFingerprint(windowBytes: Int = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: self) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        var hasher = SHA256()
        // Size first, so two files sharing a head/tail window (padding, shared
        // container header) but differing in length still diverge.
        hasher.update(data: withUnsafeBytes(of: size.littleEndian) { Data($0) })

        try? handle.seek(toOffset: 0)
        if let head = try? handle.read(upToCount: windowBytes) {
            hasher.update(data: head)
        }
        // Tail window only when the file is larger than one window — otherwise
        // the head already covered the whole file.
        if size > UInt64(windowBytes) {
            try? handle.seek(toOffset: size - UInt64(windowBytes))
            if let tail = try? handle.read(upToCount: windowBytes) {
                hasher.update(data: tail)
            }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
