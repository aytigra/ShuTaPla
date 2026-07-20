//
//  VideoColorTagsTests.swift
//  ShuTaPlaTests
//
//  Task 19 step 5b — the pure mapping from a video's CoreMedia colour tags to the mpv-style
//  strings the HDR path speaks, and the `isHDR` flag derived from the transfer function. The
//  format-description read and the libmpv fallback are thin I/O around this table; the table
//  itself is the testable core, so it's asserted here without opening a file (the real HDR
//  video samples are large and transient).
//

import Testing
import CoreMedia
@testable import ShuTaPla

@Suite struct VideoColorTagsTests {

    /// Each recognised CoreMedia transfer function maps to its mpv string; an SDR or absent
    /// tag maps to `bt.709`/`nil`, never a false HDR value.
    @Test(arguments: [
        (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String, "pq"),
        (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String, "hlg"),
        (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String, "bt.709"),
    ] as [(String?, String)])
    func gammaMapsCoreMediaTransferFunctions(input: String?, expected: String) {
        #expect(VideoColorTags.mpvGamma(input) == expected)
    }

    /// Each recognised CoreMedia primaries value maps to its mpv string.
    @Test(arguments: [
        (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String, "bt.2020"),
        (kCMFormatDescriptionColorPrimaries_P3_D65 as String, "display-p3"),
        (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String, "bt.709"),
    ] as [(String?, String)])
    func primariesMapCoreMediaColorPrimaries(input: String?, expected: String) {
        #expect(VideoColorTags.mpvPrimaries(input) == expected)
    }

    /// A missing or unrecognised tag maps to `nil` — an SDR file with no colour tags reads as
    /// SDR rather than being forced onto a wrong value.
    @Test func absentOrUnknownTagsMapToNil() {
        #expect(VideoColorTags.mpvGamma(nil) == nil)
        #expect(VideoColorTags.mpvPrimaries(nil) == nil)
        #expect(VideoColorTags.mpvGamma("Something-Else") == nil)
        #expect(VideoColorTags.mpvPrimaries("Something-Else") == nil)
    }

    /// `isHDR` is true only for the PQ/HLG transfers; SDR, unrecognised, and absent gammas are SDR.
    @Test func isHDRIsExactlyPQorHLG() {
        #expect(VideoColorTags.isHDR(gamma: "pq"))
        #expect(VideoColorTags.isHDR(gamma: "hlg"))
        #expect(!VideoColorTags.isHDR(gamma: "bt.709"))
        #expect(!VideoColorTags.isHDR(gamma: nil))
    }
}
