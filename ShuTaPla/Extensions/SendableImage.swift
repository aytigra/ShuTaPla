//
//  SendableImage.swift
//  ShuTaPla
//
//  A box that carries an `NSImage` decoded off the main actor back to it.
//  `NSImage` isn't `Sendable`, but a decode worker constructs one and never
//  mutates it afterward, so wrapping it lets the finished image cross the actor
//  boundary as a value. The unchecked conformance is safe under that invariant.
//

import AppKit

nonisolated struct SendableImage: @unchecked Sendable {
    let image: NSImage
    init(_ image: NSImage) { self.image = image }
}
