//
//  Int+FileSize.swift
//  ShuTaPla
//
//  On-disk size formatting for the Manager's file-list/gallery size indicators.
//

import Foundation

extension Int {
    /// A byte count as a human-readable size (`"12.3 MB"`), using the file-size convention
    /// (1000-based units, matching Finder) in the current locale.
    var formattedFileSize: String {
        Int64(self).formatted(.byteCount(style: .file))
    }
}
