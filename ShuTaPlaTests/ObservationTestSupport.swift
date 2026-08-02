//
//  ObservationTestSupport.swift
//  ShuTaPlaTests
//
//  The shared seam for asserting Observation invalidation. Several sinks write derived facts onto
//  a `PlaylistFile` from a repeated path — the metadata merge, the HDR cache, the cloud feed — and
//  each must stay silent when the fact it settles hasn't moved: an equal write would re-render
//  every view reading the property for nothing. Both halves are asserted through
//  `firesObservation`: a restated fact must not fire, a genuinely new one must.
//

import Foundation
import Observation

/// A one-shot flag for `withObservationTracking`'s `@Sendable` `onChange`, which can't mutate a
/// captured `var`. The callback runs synchronously on the main actor within the mutation.
private final class Fired: @unchecked Sendable { var value = false }

/// Whether `mutate` fires an Observation invalidation for the properties `read` touches.
@MainActor func firesObservation(reading read: () -> Void, on mutate: () -> Void) -> Bool {
    let fired = Fired()
    withObservationTracking(read) { fired.value = true }
    mutate()
    return fired.value
}
