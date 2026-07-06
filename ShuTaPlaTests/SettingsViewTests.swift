//
//  SettingsViewTests.swift
//  ShuTaPlaTests
//
//  The pure cache-pressure predicate shared by the Settings size readout and the Manager
//  notice-strip banner: the 1 GB caution threshold.
//

import Testing
import Foundation
@testable import ShuTaPla

struct SettingsViewTests {

    /// The caution fires only once the cache exceeds the 1 GB threshold — false below it, at it,
    /// and while the size is still loading (`nil`).
    @Test func cacheOverLimitFiresOnlyAboveThreshold() {
        #expect(AppConstants.cacheOverLimit(bytes: nil) == false)
        #expect(AppConstants.cacheOverLimit(bytes: 0) == false)
        #expect(AppConstants.cacheOverLimit(bytes: AppConstants.thumbnailCacheWarningBytes) == false)   // exactly at → no caution
        #expect(AppConstants.cacheOverLimit(bytes: AppConstants.thumbnailCacheWarningBytes + 1) == true)
    }

    /// Publishing the flag reflects the measured size: an over-limit size sets it, and a later
    /// under-limit size (as after a clear/orphan sweep) clears it, so the banner can't stay stale.
    @Test func publishCachePressureTracksMeasuredSize() {
        defer { UserDefaults.standard.removeObject(forKey: AppConstants.thumbnailCacheOverLimitKey) }

        ThumbnailService.publishCachePressure(bytes: AppConstants.thumbnailCacheWarningBytes + 1)
        #expect(UserDefaults.standard.bool(forKey: AppConstants.thumbnailCacheOverLimitKey) == true)

        ThumbnailService.publishCachePressure(bytes: 0)   // e.g. cache just cleared
        #expect(UserDefaults.standard.bool(forKey: AppConstants.thumbnailCacheOverLimitKey) == false)
    }
}
