//
//  TestSchema.swift
//  ShuTaPlaTests
//
//  The model set every test container is built from, taken straight from the version the app ships.
//  A hand-listed subset is a trap: a relationship whose destination is missing fails the container
//  build itself, so the whole suite would go red on an entity added elsewhere — and it would go red
//  for a reason that has nothing to do with what any of those tests cover.
//
//  Migration suites are the exception and name their pinned version directly, since the shape they
//  need is a historical one.
//

import Foundation
import SwiftData
@testable import ShuTaPla

var appTestSchema: Schema { Schema(versionedSchema: SchemaV10.self) }
