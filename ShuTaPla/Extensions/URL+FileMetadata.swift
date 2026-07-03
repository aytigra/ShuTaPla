//
//  URL+FileMetadata.swift
//  ShuTaPla
//
//  Cheap on-disk facts read from a resolved file URL for the media-metadata cache:
//  the file's byte size and, for stills, its header pixel dimensions. Both are shared
//  by the list-mode `MediaMetadataService` and the gallery thumbnailer, which read
//  them off the main actor while a file is already open.
//

import Foundation
import ImageIO

extension URL {

    /// On-disk size in bytes, or `nil` when it can't be read.
    nonisolated var fileSizeBytes: Int? {
        (try? resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// The pixel dimensions of the image at this URL, read from its header
    /// (`CGImageSource` properties, decoding no pixels), or `nil` when they can't be read.
    nonisolated var imagePixelSize: (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(self as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
