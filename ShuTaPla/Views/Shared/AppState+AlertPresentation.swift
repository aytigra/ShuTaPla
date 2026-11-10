//
//  AppState+AlertPresentation.swift
//  ShuTaPla
//
//  The `isPresented` binding of an app-root modal (`AppState.windowModals`).
//

import SwiftUI

extension AppState {
    /// True while the shown modal is of `kind`. SwiftUI's dismissal runs `dismiss` only for a modal
    /// on screen: one still queued is not, and the dismissal of another must not clear it.
    func isPresented(_ kind: WindowModal.Kind, dismiss: @escaping () -> Void) -> Binding<Bool> {
        Binding(
            get: { self.windowModals.shown?.kind == kind },
            set: { if !$0, self.windowModals.shown?.kind == kind { dismiss() } }
        )
    }
}
