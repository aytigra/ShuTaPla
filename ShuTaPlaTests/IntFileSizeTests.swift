//
//  IntFileSizeTests.swift
//  ShuTaPlaTests
//
//  `Int.formattedFileSize`: the human-readable on-disk size shown in the Manager's file
//  list and gallery. Assertions check the scale unit rather than exact digits, so they
//  stay robust to locale grouping/decimal separators.
//

import Testing
import Foundation
@testable import ShuTaPla

@Suite struct IntFileSizeTests {

    @Test func bytesForUnderAKilobyte() {
        #expect(500.formattedFileSize.localizedCaseInsensitiveContains("byte"))
    }

    @Test func kilobyteScale() {
        // The file-size style renders kilobytes SI-style as "kB" (lowercase k); MB/GB are uppercase.
        #expect(2_000.formattedFileSize.contains("kB"))
    }

    @Test func megabyteScale() {
        #expect(1_500_000.formattedFileSize.contains("MB"))
    }

    @Test func gigabyteScale() {
        #expect(2_500_000_000.formattedFileSize.contains("GB"))
    }
}
