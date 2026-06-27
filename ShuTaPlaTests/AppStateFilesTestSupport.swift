//
//  AppStateFilesTestSupport.swift
//  ShuTaPlaTests
//
//  Test-only resolved views of the production identifier sequences. The app exposes the
//  Manager and overlay file lists as `[PersistentIdentifier]` (`managerFileIDs` and friends)
//  and resolves only the on-screen rows through `file(for:)`, so a large playlist never
//  materializes at once. The parity tests assert on filenames and order, so they resolve the
//  whole sequence here — a convenience that belongs to the tests, not the app.
//

import Foundation
import SwiftData
@testable import ShuTaPla

extension AppState {
    var managerFiles: [PlaylistFile] { managerFileIDs.compactMap(file(for:)) }
    var audioChannelFiles: [PlaylistFile] { audioChannelFileIDs.compactMap(file(for:)) }
    var visualChannelFiles: [PlaylistFile] { visualChannelFileIDs.compactMap(file(for:)) }
}
