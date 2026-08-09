//
//  FloatingPanel.swift
//  ShuTaPla
//
//  The chrome of a panel SwiftUI draws over the content below it — a suggestion dropdown, the saved
//  searches list: rounded, hairline-bordered, and shadowed. Shared so the two read as one kind of
//  surface, and so the compositing below is stated once rather than remembered twice.
//

import SwiftUI

extension View {
    /// Dresses this view as a floating panel over the content below it.
    ///
    /// `compositingGroup` is what makes the shadow the panel's own: without it the shadow applies to
    /// every shape drawn inside, so a filled row smears its own blur across the panel.
    func floatingPanel(_ background: some ShapeStyle, cornerRadius: CGFloat = 6) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        return self
            .background(background, in: shape)
            // Nothing inside paints past the corners the border and shadow follow.
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.secondary.opacity(0.25)))
            .compositingGroup()
            .shadow(radius: 8, y: 2)
    }
}
