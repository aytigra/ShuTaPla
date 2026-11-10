//
//  DispatchQueue+Async.swift
//  ShuTaPla
//
//  The bridge from blocking work to `async`. The cooperative pool has one thread per core
//  and expects no thread to block, so a remux, a libmpv decode or a cross-volume copy runs
//  on a Dispatch queue and the caller suspends until it ends.
//

import Foundation

extension DispatchQueue {
    /// Runs the blocking `work` on this queue and returns its result; the caller suspends,
    /// holding no thread, until `work` ends.
    nonisolated func run<T>(_ work: @escaping @Sendable () -> sending T) async -> sending T {
        await withCheckedContinuation { continuation in
            self.async { continuation.resume(returning: work()) }
        }
    }
}
