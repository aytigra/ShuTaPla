//
//  CloudStatus+Classification.swift
//  ShuTaPla
//
//  Deriving a file's `CloudStatus` from the two OS sources that report iCloud
//  eviction state: the `URLResourceValues` a folder scan fetches, and the
//  `NSMetadataItem` a live `NSMetadataQuery` delivers. Both funnel into one pure
//  `classify` core so the scan-time snapshot and the live feed can never drift.
//
//  `nonisolated` so it runs on whichever context reads it — the file-system
//  actor's off-main scan and the main-actor cloud service alike.
//

import Foundation

nonisolated extension CloudStatus {

    /// The shared decision tree, over normalized inputs. A non-ubiquitous file is `.local`
    /// (it lives only on this disk); a ubiquitous one is `.downloading` while bytes are in
    /// flight, `.inCloud` when evicted to a placeholder, and `.local` once fully present.
    /// Downloading wins over the not-downloaded flag: a fetch in progress is the live truth.
    static func classify(isUbiquitous: Bool, isDownloading: Bool, isNotDownloaded: Bool) -> CloudStatus {
        guard isUbiquitous else { return .local }
        if isDownloading { return .downloading }
        return isNotDownloaded ? .inCloud : .local
    }

    /// Classifies the ubiquitous keys a folder scan prefetched. `nil` (or a non-ubiquitous
    /// item) is `.local`. Mirrors `FileSystemService`'s enumeration keys.
    static func from(_ values: URLResourceValues?) -> CloudStatus {
        classify(
            isUbiquitous: values?.isUbiquitousItem == true,
            isDownloading: values?.ubiquitousItemIsDownloading == true,
            isNotDownloaded: values?.ubiquitousItemDownloadingStatus == .notDownloaded
        )
    }

    /// Classifies a live-query `NSMetadataItem`. The downloading-status attribute stands in for
    /// ubiquity — an item carrying it is in iCloud; its absence means the item is purely local.
    static func from(_ item: NSMetadataItem) -> CloudStatus {
        let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
        let isDownloading = item.value(forAttribute: NSMetadataUbiquitousItemIsDownloadingKey) as? Bool
        return classify(
            isUbiquitous: status != nil,
            isDownloading: isDownloading == true,
            isNotDownloaded: status == NSMetadataUbiquitousItemDownloadingStatusNotDownloaded
        )
    }
}
