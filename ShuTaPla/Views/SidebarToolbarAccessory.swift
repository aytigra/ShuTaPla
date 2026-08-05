//
//  SidebarToolbarAccessory.swift
//  ShuTaPla
//
//  The Manager's sidebar-region controls — the scope tabs and New Playlist — while the sidebar is
//  open: a leading titlebar accessory rather than toolbar items. AppKit places a `.leading`
//  accessory immediately right of the traffic lights and leaves its width to the app; the toolbar's
//  own items then indent past it, so it composes with the tracking separator that bounds the center
//  region. Being outside the toolbar is the point: a toolbar without room *must* push items into the
//  overflow menu and offers no way to opt out, so as items inside the sidebar region these two
//  disappeared exactly when the sidebar was narrowest.
//
//  The container spans from its own origin to the sidebar divider, holding the tabs flush leading
//  and the `+` against the divider, and never shrinks below the two controls. It also drives the
//  sidebar pane's minimum thickness from those same measured widths, so a drag can never narrow the
//  pane past what the controls need.
//
//  A collapsed sidebar leaves it nothing to span, so it steps out of the titlebar altogether and the
//  controls become toolbar items for as long as the collapse lasts (`SidebarToolbarLayout
//  .toolbarIdentifiers`) — which is also how they get the system's Liquid Glass group capsule, since
//  only the toolbar can draw one that is composited into the titlebar rather than blurring it again.
//

import SwiftUI
import AppKit

// MARK: - Accessory controller

@MainActor
final class SidebarToolbarAccessory: NSTitlebarAccessoryViewController {
    private weak var splitViewController: NSSplitViewController?

    init(env: ManagerEnv, splitViewController: NSSplitViewController) {
        self.splitViewController = splitViewController
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .leading
        // The titlebar fills the accessory's height in both normal and full-screen layouts; only the
        // width is ours to drive.
        fullScreenMinHeight = 0
        view = SidebarToolbarAccessoryView(
            scope: env.hostingView(ScopeTabs()),
            plus: env.hostingView(NewPlaylistButton())
        )
        // The split view posts this continuously through a divider drag, through the collapse and
        // expand animations, and through the window resizes that move the traffic-light inset — so
        // it is the whole set of geometry sources, and the `+` follows the divider frame by frame
        // rather than snapping into place when the gesture ends. The selector form deregisters
        // itself when this controller deallocates.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewDidResizeSubviews),
            name: NSSplitView.didResizeSubviewsNotification,
            object: splitViewController.splitView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func splitViewDidResizeSubviews() { updateGeometry() }

    /// Resizes the container to the space the sidebar leaves and re-derives the sidebar's minimum
    /// thickness, both keyed on the container's own origin — which the traffic lights set, and which
    /// full-screen changes. The divider is read from the **center** pane's leading edge rather than
    /// the sidebar pane's trailing edge: a collapsed pane keeps its pre-collapse frame, so its own
    /// edge reports a stale width for exactly the state that matters.
    ///
    /// Only ever runs while the sidebar is open: a collapse takes the whole accessory out of the
    /// window (`ManagerSplitViewController.syncSidebarControls`), so there is no collapsed geometry
    /// to describe here. `window == nil` is that unmounted state, and the guard covers it.
    func updateGeometry() {
        guard let container = view as? SidebarToolbarAccessoryView,
              let splitViewController,
              let centerPane = splitViewController.splitView.arrangedSubviews.dropFirst().first,
              container.window != nil
        else { return }
        let leadingInset = container.convert(CGPoint.zero, to: nil).x
        let dividerX = centerPane.convert(CGPoint.zero, to: nil).x
        container.fit(availableWidth: dividerX - leadingInset)

        // Guarded because writing it re-lays out the split view, which posts the notification that
        // lands back here.
        if let sidebarItem = splitViewController.splitViewItems.first {
            let thickness = container.minimumSidebarThickness(leadingInset: leadingInset)
            if sidebarItem.minimumThickness != thickness { sidebarItem.minimumThickness = thickness }
        }
    }
}

// MARK: - Container

/// Lays the two groups out across the container's width: tabs leading, `+` trailing so it sits on
/// the sidebar divider, each vertically centered on the titlebar line.
private final class SidebarToolbarAccessoryView: NSView {
    private let scope: NSView
    private let plus: NSView

    init(scope: NSView, plus: NSView) {
        self.scope = scope
        self.plus = plus
        super.init(frame: CGRect(origin: .zero, size: scope.fittingSize))
        addSubview(scope)
        addSubview(plus)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Takes the width the sidebar leaves — `dividerX − ownOriginX`, which sweeps down through zero
    /// as the sidebar collapses past this view's origin and back up as it expands — and floors it at
    /// the groups' own width, so the controls stay whole throughout either animation.
    func fit(availableWidth: CGFloat) {
        let width = resolve(availableWidth).width
        guard frame.width != width else { return }
        setFrameSize(CGSize(width: width, height: frame.height))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Resolved against the width actually granted, so the groups stay inside their container
        // even if AppKit hands back less than `fit` asked for.
        place(scope, at: 0)
        place(plus, at: resolve(bounds.width).plusOrigin)
    }

    /// What the sidebar pane has to be at least, for the controls this container actually holds,
    /// given where the traffic lights put its leading edge.
    func minimumSidebarThickness(leadingInset: CGFloat) -> CGFloat {
        SidebarToolbarLayout.minimumSidebarThickness(leadingInset: leadingInset, metrics: metrics)
    }

    private func place(_ view: NSView, at x: CGFloat) {
        let size = view.fittingSize
        view.frame = CGRect(
            x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height
        )
    }

    private func resolve(_ availableWidth: CGFloat) -> (width: CGFloat, plusOrigin: CGFloat) {
        SidebarToolbarLayout.resolve(availableWidth: availableWidth, metrics: metrics)
    }

    /// Measured on demand, so a control that changes size — a scope tab gaining a word, a different
    /// system font — moves both the container's width and the pane's minimum with it.
    private var metrics: SidebarToolbarLayout.Metrics {
        .init(scopeWidth: scope.fittingSize.width, plusWidth: plus.fittingSize.width)
    }
}

// MARK: - Controls

/// The scope selector: the Image, Video, and Audio tabs, as one group — the container's leading
/// group while the sidebar is open, a toolbar item once it collapses.
struct ScopeTabs: View {
    var body: some View {
        HStack(spacing: 2) {
            ScopeTabButton(scope: .image, title: "Image", systemImage: "photo.stack")
            ScopeTabButton(scope: .video, title: "Video", systemImage: "film.stack")
            ScopeTabButton(scope: .audio, title: "Audio", systemImage: "music.note.square.stack")
        }
    }
}

/// One scope tab. Switching scope is a view-only change — it never starts, stops, or loads a channel.
/// The tab also drives the sidebar: clicking the active scope collapses the left panel; clicking any
/// tab while collapsed expands it and selects that scope.
private struct ScopeTabButton: View {
    let scope: MediaType
    let title: String
    let systemImage: String

    @Environment(AppState.self) private var appState
    @Environment(ManagerChrome.self) private var chrome

    var body: some View {
        Button(action: activate) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(TitlebarControlButtonStyle(isActive: appState.managerScope == scope))
        .help(title)
    }

    private func activate() {
        if chrome.sidebarCollapsed {
            appState.switchScope(to: scope)
            chrome.sidebarCollapsed = false
        } else if appState.managerScope == scope {
            chrome.sidebarCollapsed = true
        } else {
            appState.switchScope(to: scope)
        }
    }
}

/// A group of one.
struct NewPlaylistButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            appState.isImportingPlaylist = true
        } label: {
            Label("New Playlist", systemImage: "plus")
        }
        .buttonStyle(TitlebarControlButtonStyle())
        .disabled(appState.isAddingPlaylist)
        .help("Add a playlist from a folder")
    }
}

// MARK: - Titlebar styling

/// A control on the titlebar line: no bezel of its own, a soft gray capsule under the pointer, a
/// stronger one while pressed or while it is the active choice. Gray throughout, never an accent
/// fill — the system's selected-toggle look rather than a filled control.
///
/// The glass capsule belongs to the *group*, never to the individual button, which is how the system
/// draws a toolbar item group — so a button reads the same whether it sits over the sidebar, where
/// there is no capsule to draw, or in the toolbar item the collapsed sidebar hands it to.
struct TitlebarControlButtonStyle: ButtonStyle {
    var isActive = false

    /// How strongly the highlight capsule fills, for the state the control is in. `isEnabled` is read
    /// here rather than filtered at the hover event: nothing delivers a hover event when a control is
    /// disabled under a stationary pointer, so a filtered event would leave the last stored hover
    /// drawn beneath the dimmed button until the pointer moved.
    nonisolated static func fillOpacity(
        isActive: Bool, isPressed: Bool, hovering: Bool, isEnabled: Bool
    ) -> Double {
        if isActive || isPressed { return 1 }
        return hovering && isEnabled ? 0.5 : 0
    }

    func makeBody(configuration: Configuration) -> some View {
        Cell(configuration: configuration, isActive: isActive)
    }

    /// A view rather than a plain `makeBody` body, so the hover state has somewhere to live.
    private struct Cell: View {
        let configuration: ButtonStyleConfiguration
        let isActive: Bool

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .symbolVariant(isActive ? .fill : .none)
                .font(.system(size: 17))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 28)
                // Inset from the hit area, so the capsule reads as a highlight under the icon rather
                // than as a button bezel filling the cell.
                .background(Capsule().fill(.quaternary.opacity(fillOpacity)).padding(1))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }

        private var fillOpacity: Double {
            TitlebarControlButtonStyle.fillOpacity(
                isActive: isActive, isPressed: configuration.isPressed,
                hovering: hovering, isEnabled: isEnabled
            )
        }
    }
}
