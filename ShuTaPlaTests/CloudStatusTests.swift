//
//  CloudStatusTests.swift
//  ShuTaPlaTests
//
//  The shared cloud-status classification (`CloudStatus.classify`) that both the folder
//  scan and the live query funnel into. The OS-type adapters (`from(URLResourceValues)`,
//  `from(NSMetadataItem)`) read read-only system values that a test can't synthesize, so
//  the truth table is exercised on the pure core they both delegate to.
//

import Testing
@testable import ShuTaPla

struct CloudStatusTests {

    @Test(arguments: [
        // A non-ubiquitous file is always local, whatever the other flags read.
        (false, false, false, CloudStatus.local),
        (false, true,  true,  CloudStatus.local),
        // Ubiquitous and fully present on disk.
        (true,  false, false, CloudStatus.local),
        // Ubiquitous but evicted to a placeholder — in the cloud, not yet fetched.
        (true,  false, true,  CloudStatus.inCloud),
        // Ubiquitous with a fetch in flight — downloading wins over the not-downloaded flag.
        (true,  true,  false, CloudStatus.downloading),
        (true,  true,  true,  CloudStatus.downloading),
    ])
    func classifyMapsEveryCombination(
        isUbiquitous: Bool, isDownloading: Bool, isNotDownloaded: Bool, expected: CloudStatus
    ) {
        #expect(
            CloudStatus.classify(
                isUbiquitous: isUbiquitous,
                isDownloading: isDownloading,
                isNotDownloaded: isNotDownloaded
            ) == expected
        )
    }

    /// The badge mapping that drives `CloudStatusBadge`: a glyph and a VoiceOver label for the
    /// two cloud states, and nothing at all for a local file (the badge renders empty).
    @Test(arguments: [
        (CloudStatus.local, nil as String?),
        (.inCloud, "icloud"),
        (.downloading, "icloud.and.arrow.down"),
    ])
    func badgeSymbolMapsEachStatus(status: CloudStatus, symbol: String?) {
        #expect(status.badgeSymbol == symbol)
        // A label is present exactly when there is a glyph to describe.
        #expect((status.badgeAccessibilityLabel != nil) == (symbol != nil))
    }
}
