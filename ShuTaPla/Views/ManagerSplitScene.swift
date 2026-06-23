//
//  ManagerSplitScene.swift
//  ShuTaPla
//
//  The AppKit backbone of Manager mode: an `NSSplitViewController` hosting the three
//  SwiftUI panes (playlists sidebar, center file panel, tag inspector) and a custom
//  `NSToolbar` whose items align to the split view's dividers via tracking separators.
//
//  The toolbar is a real window toolbar, so its controls sit on the traffic-light line,
//  are fully interactive, and group into three pane-aligned regions: the sidebar region
//  carries the scope tabs and New Playlist; the center region carries the playlist title
//  and the scope's playback actions; the inspector region carries the tag controls. Two
//  `NSTrackingSeparatorToolbarItem`s pin the region boundaries to the sidebar and inspector
//  dividers, so each region stays bounded by its pane.
//
//  The panes are SwiftUI (`PlaylistSidebar` / `PlaylistCenterView` / `TagSidebar`) hosted
//  across the AppKit boundary, so `ManagerEnv` re-injects the SwiftData container and the
//  observable services that the SwiftUI environment would otherwise carry. `ManagerChrome`
//  holds the view-chrome the toolbar and the split view share — sidebar collapse, inspector
//  visibility, and tag-management mode — as the single source of truth.
//

import SwiftUI
import SwiftData
import AppKit
import Observation

// MARK: - Chrome state

/// The Manager's view-chrome, shared by the toolbar controls and the split view. The toolbar
/// buttons write it; the split view collapses its panes to match. Scope itself lives in
/// `AppState.managerScope`, since data routing keys off it.
@MainActor
@Observable
final class ManagerChrome {
    /// Whether the playlists sidebar is collapsed. The scope tabs drive it: clicking the active
    /// scope collapses, clicking either while collapsed expands.
    var sidebarCollapsed = false
    /// Whether the tag inspector is shown.
    var inspectorVisible = true
    /// Whether the inspector is in whole-playlist tag-management mode rather than filter-and-edit.
    var managingTags = false
}

// MARK: - Environment bridge

/// The observable services and SwiftData container the hosted panes need, re-applied to each
/// `NSHostingController`/`NSHostingView` rootView so the SwiftUI environment survives the AppKit
/// boundary.
@MainActor
struct ManagerEnv {
    let appState: AppState
    let coordinator: PlaybackCoordinator
    let thumbnailService: ThumbnailService
    let durationService: DurationService
    let chrome: ManagerChrome
    let modelContainer: ModelContainer

    /// Wraps a SwiftUI view with the full Manager environment so it renders identically whether it
    /// lives inside the SwiftUI tree or is hosted from AppKit.
    func host(_ view: some View) -> some View {
        view
            .environment(appState)
            .environment(coordinator)
            .environment(thumbnailService)
            .environment(durationService)
            .environment(chrome)
            .modelContainer(modelContainer)
    }
}

// MARK: - SwiftUI bridge

/// Hosts `ManagerSplitViewController` in the SwiftUI tree and keeps the window toolbar attached
/// while Manager mode is on screen.
struct ManagerSplitScene: NSViewControllerRepresentable {
    let env: ManagerEnv

    func makeNSViewController(context: Context) -> ManagerSplitViewController {
        ManagerSplitViewController(env: env)
    }

    func updateNSViewController(_ controller: ManagerSplitViewController, context: Context) {
        controller.attachToolbarIfNeeded()
    }

    static func dismantleNSViewController(_ controller: ManagerSplitViewController, coordinator: ()) {
        controller.detachToolbar()
    }

    /// Fills the proposed area so the split view spans the full window. The default sizing pass asks
    /// the split view controller for its fitting size — the sum of the panes' minimum thicknesses —
    /// and SwiftUI then centers that narrower content, leaving margins on both edges. With the split
    /// view undersized, a divider drag can't hand freed width to the center pane and a pane collapse
    /// detaches from the window edge. Reporting the full proposed size pins it edge to edge.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController: ManagerSplitViewController,
        context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

// MARK: - Split view controller

@MainActor
final class ManagerSplitViewController: NSSplitViewController, NSToolbarDelegate {
    private let env: ManagerEnv

    private let sidebarItem: NSSplitViewItem
    private let centerItem: NSSplitViewItem
    private let inspectorItem: NSSplitViewItem

    private var managerToolbar: NSToolbar?
    private weak var hostWindow: NSWindow?
    private var sidebarCollapseObservation: NSKeyValueObservation?
    private var inspectorCollapseObservation: NSKeyValueObservation?

    init(env: ManagerEnv) {
        self.env = env

        // Each pane fills its column: opting out of hosting-content sizing drops the intrinsic-width
        // constraint that would otherwise pin a pane (e.g. the audio placeholder) to its content's
        // size and force the dividers to move symmetrically instead of resizing the dragged pane.
        //
        // The side panes carry no maximum thickness on purpose: a cap turns a drag that grows the
        // pane past the cap into a drag that shrinks the *next* pane over, so the side panels would
        // slide toward the center once the inspector hit its limit. A minimum thickness is enough to
        // keep them usable.
        let sidebar = NSHostingController(rootView: env.host(PlaylistSidebar()))
        sidebar.sizingOptions = []
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.canCollapse = true

        let center = NSHostingController(rootView: env.host(PlaylistCenterView()))
        center.sizingOptions = []
        centerItem = NSSplitViewItem(viewController: center)
        centerItem.minimumThickness = 360
        centerItem.canCollapse = false

        // The inspector edits the active scope's tag-management mode, which is shared chrome state.
        let managingTags = Binding(
            get: { [chrome = env.chrome] in chrome.managingTags },
            set: { [chrome = env.chrome] newValue in chrome.managingTags = newValue }
        )
        // A regular trailing pane, not an inspector item: the inspector behavior installs its own
        // width management that fights a manual divider drag.
        let inspector = NSHostingController(rootView: env.host(TagSidebar(managingTags: managingTags)))
        inspector.sizingOptions = []
        inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.minimumThickness = 220
        inspectorItem.canCollapse = true

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        addSplitViewItem(sidebarItem)
        addSplitViewItem(centerItem)
        addSplitViewItem(inspectorItem)
        // Set holding priorities after the items are installed so the side panes hold their widths
        // and the center (lowest priority) is the one that grows or shrinks for a divider drag or a
        // pane collapse. Applying them in the initializer lets `sidebarWithViewController` override.
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        centerItem.holdingPriority = NSLayoutConstraint.Priority(250)
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(260)
        // Persist the divider positions across launches. Set after the items are installed so the
        // split view restores against the final pane set. Collapse state stays driven by
        // `ManagerChrome` (applied below), so autosave only governs pane widths.
        splitView.autosaveName = "ManagerSplitView"
        applyCollapse(animated: false)
        startObserving()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        attachToolbarIfNeeded()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        attachToolbarIfNeeded()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        detachToolbar()
    }

    // MARK: Toolbar attachment

    /// Installs the Manager toolbar on the host window, once it has one. Idempotent — safe to call
    /// from the appearance callbacks and from the representable's update pass.
    func attachToolbarIfNeeded() {
        guard let window = view.window else { return }
        hostWindow = window

        let toolbar = managerToolbar ?? makeToolbar()
        managerToolbar = toolbar

        if window.toolbar !== toolbar {
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.toolbar = toolbar
        }
    }

    /// Removes the Manager toolbar when Manager mode leaves the screen, so Welcome and Player don't
    /// inherit it.
    func detachToolbar() {
        guard let window = hostWindow, window.toolbar === managerToolbar else { return }
        window.toolbar = nil
        window.titleVisibility = .visible
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "ManagerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    // MARK: Pane collapse

    /// Drives the panes to match the chrome, animating user-initiated toggles.
    private func applyCollapse(animated: Bool) {
        setCollapsed(sidebarItem, to: env.chrome.sidebarCollapsed, animated: animated)
        setCollapsed(inspectorItem, to: !env.chrome.inspectorVisible, animated: animated)
    }

    private func setCollapsed(_ item: NSSplitViewItem, to collapsed: Bool, animated: Bool) {
        guard item.isCollapsed != collapsed else { return }
        if animated {
            item.animator().isCollapsed = collapsed
        } else {
            item.isCollapsed = collapsed
        }
    }

    /// Mirrors chrome → panes (toolbar toggles) and panes → chrome (a divider dragged to the edge),
    /// keeping the toolbar's highlight in step with the actual layout. The equality guards in
    /// `setCollapsed` and below break the feedback loop between the two directions.
    private func startObserving() {
        observeChrome()
        observeScope()
        sidebarCollapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
            guard let collapsed = change.newValue else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.env.chrome.sidebarCollapsed != collapsed {
                    self.env.chrome.sidebarCollapsed = collapsed
                }
            }
        }
        inspectorCollapseObservation = inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
            guard let collapsed = change.newValue else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.env.chrome.inspectorVisible != !collapsed {
                    self.env.chrome.inspectorVisible = !collapsed
                }
            }
        }
    }

    private func observeChrome() {
        withObservationTracking {
            _ = env.chrome.sidebarCollapsed
            _ = env.chrome.inspectorVisible
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyCollapse(animated: true)
                self.observeChrome()
            }
        }
    }

    private func observeScope() {
        withObservationTracking {
            _ = env.appState.managerScope
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.realignSeparators()
                self.observeScope()
            }
        }
    }

    /// Forces a split-view layout pass so the toolbar's tracking separators realign to the dividers.
    /// A scope switch changes pane content but not pane widths, so without a nudge the separators
    /// stay where they were and the center items overlap the inspector items until the next drag.
    private func realignSeparators() {
        splitView.needsLayout = true
        splitView.layoutSubtreeIfNeeded()
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .scopeTabs, .flexibleSpace, .newPlaylist,
            .sidebarTrackingSeparator,
            .title, .flexibleSpace, .centerActions,
            .trailingSeparator,
            .flexibleSpace, .manageTags, .toggleTags,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarTrackingSeparator:
            // The system identifier (not a custom tracking separator): AppKit anchors the items placed
            // before it so the scope tabs and New Playlist stay in the toolbar when the sidebar
            // collapses, instead of spilling into the overflow menu.
            return NSTrackingSeparatorToolbarItem(identifier: .sidebarTrackingSeparator, splitView: splitView, dividerIndex: 0)
        case .trailingSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: .trailingSeparator, splitView: splitView, dividerIndex: 1)
        case .scopeTabs:
            return hosting(itemIdentifier, label: "Scope", visibility: .high) { ScopeTabs() }
        case .newPlaylist:
            return hosting(itemIdentifier, label: "New Playlist", visibility: .high) { NewPlaylistButton() }
        case .title:
            // The title yields first when space is tight, and reads as a plain label, not a control.
            let item = hosting(itemIdentifier, label: "Playlist", visibility: .low) { ManagerTitleLabel() }
            item.isBordered = false
            return item
        case .centerActions:
            return hosting(itemIdentifier, label: "Actions", visibility: .high) { CenterActionsBar() }
        case .manageTags:
            return hosting(itemIdentifier, label: "Manage Tags", visibility: .high) { ManageTagsButton() }
        case .toggleTags:
            return hosting(itemIdentifier, label: "Toggle Tags", visibility: .high) { ToggleTagsButton() }
        default:
            return nil
        }
    }

    /// Builds a toolbar item whose content is a SwiftUI view hosted with the full Manager
    /// environment, sized to its intrinsic content.
    private func hosting(
        _ identifier: NSToolbarItem.Identifier,
        label: String,
        visibility: NSToolbarItem.VisibilityPriority = .standard,
        @ViewBuilder _ content: () -> some View
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let view = NSHostingView(rootView: env.host(content()))
        view.sizingOptions = [.intrinsicContentSize]
        item.view = view
        item.label = label
        item.visibilityPriority = visibility
        return item
    }
}

private extension NSToolbarItem.Identifier {
    static let scopeTabs = NSToolbarItem.Identifier("ManagerScopeTabs")
    static let newPlaylist = NSToolbarItem.Identifier("ManagerNewPlaylist")
    static let title = NSToolbarItem.Identifier("ManagerTitle")
    static let centerActions = NSToolbarItem.Identifier("ManagerCenterActions")
    static let trailingSeparator = NSToolbarItem.Identifier("ManagerTrailingSeparator")
    static let manageTags = NSToolbarItem.Identifier("ManagerManageTags")
    static let toggleTags = NSToolbarItem.Identifier("ManagerToggleTags")
}

// MARK: - Toolbar controls

/// The scope selector: the Image, Video, and Audio tabs in a single toolbar item. Expanded, they sit tightly
/// as sidebar tabs; collapsed, they spread to the spacing of the other toolbar button groups since
/// each becomes an ordinary bordered toolbar button.
private struct ScopeTabs: View {
    @Environment(ManagerChrome.self) private var chrome

    var body: some View {
        HStack(spacing: chrome.sidebarCollapsed ? 6 : 2) {
            ScopeTabButton(scope: .image, title: "Image", systemImage: "photo.stack")
            ScopeTabButton(scope: .video, title: "Video", systemImage: "film.stack")
            ScopeTabButton(scope: .audio, title: "Audio", systemImage: "music.note.square.stack")
        }
    }
}

/// One scope tab, styled like the navigator toggle in a system toolbar: the active scope reads as a
/// subtle gray capsule highlight (no accent fill) matching the rounded toolbar buttons, inactive tabs
/// light up gray on hover. Switching scope is a view-only change — it never starts, stops, or loads a
/// channel. The tab also drives the sidebar: clicking the active scope collapses the left panel;
/// clicking either tab while collapsed expands it and selects that scope.
private struct ScopeTabButton: View {
    let scope: ManagerScope
    let title: String
    let systemImage: String

    @Environment(AppState.self) private var appState
    @Environment(ManagerChrome.self) private var chrome

    @State private var hovering = false

    var body: some View {
        if chrome.sidebarCollapsed {
            // Collapsed: the sidebar is hidden, so the tabs read as ordinary toolbar buttons —
            // bordered capsules with the system's padding, matching the other toolbar controls —
            // rather than naked sidebar tabs. Clicking either expands the sidebar onto that scope.
            Button(action: activate) {
                Label(title, systemImage: systemImage)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .labelStyle(.iconOnly)
            .help(title)
        } else {
            let isActive = appState.managerScope == scope
            Button(action: activate) {
              Image(systemName: isActive ? "\(systemImage).fill" : systemImage)
                    .font(.system(size: 17))
                    .frame(width: 32, height: 28)
                    .background(highlight(isActive: isActive))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .onHover { hovering = $0 }
            .help(title)
        }
    }

    /// The active scope's gray capsule matches the system toolbar's selected-toggle look; an inactive
    /// scope shows a fainter gray on hover. No accent fill — the icon keeps its label color throughout.
    @ViewBuilder
    private func highlight(isActive: Bool) -> some View {
        if isActive {
            Capsule().fill(.quaternary)
        } else if hovering {
            Capsule().fill(.quaternary.opacity(0.5))
        }
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

private struct NewPlaylistButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            appState.isImportingPlaylist = true
        } label: {
            Label("New Playlist", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .labelStyle(.iconOnly)
        .disabled(appState.isAddingPlaylist)
        .help("Add a playlist from a folder")
    }
}

/// The current playlist's name, the window's center title. Placeholder when nothing is selected.
private struct ManagerTitleLabel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Text(appState.managedPlaylist?.name ?? "ShuTaPla")
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 280)
    }
}

/// The active scope's playback actions, bounded to the center region: visual gets Play · Reshuffle ·
/// List/Gallery · Settings; audio gets Reshuffle · Settings. Empty when nothing is selected.
private struct CenterActionsBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 6) {
            if let playlist = appState.managedPlaylist {
                switch appState.managerScope {
                case .image, .video: visualActions(playlist)
                case .audio: audioActions(playlist)
                }
            }
        }
        .buttonStyle(.bordered)
        .labelStyle(.iconOnly)
    }

    @ViewBuilder
    private func visualActions(_ playlist: Playlist) -> some View {
        @Bindable var playlist = playlist

        // The skipped triage filter leaves no playable sequence, so the Play affordance is hidden.
        if playlist.filterState.serviceFilter != .skipped {
            Button {
                appState.beginPlayback(of: playlist)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(!playlist.hasPlaybackFiles)
            .help("Play")
        }

        Button {
            appState.reshuffle(playlist)
        } label: {
            Label("Reshuffle", systemImage: "shuffle")
        }
        .help("Reshuffle")

        Picker("View", selection: $playlist.preferences.viewMode) {
            Image(systemName: "list.bullet").tag(ViewMode.list)
            Image(systemName: "square.grid.2x2").tag(ViewMode.gallery)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("List or gallery")

        settingsButton
    }

    @ViewBuilder
    private func audioActions(_ playlist: Playlist) -> some View {
        Button {
            appState.reshuffle(playlist)
        } label: {
            Label("Reshuffle", systemImage: "shuffle")
        }
        .help("Reshuffle")

        settingsButton
    }

    /// Per-playlist settings — a placeholder affordance, disabled until the settings surface exists.
    private var settingsButton: some View {
        Button {
        } label: {
            Label("Settings", systemImage: "slider.horizontal.3")
        }
        .disabled(true)
        .help("Playlist settings")
    }
}

private struct ManageTagsButton: View {
    @Environment(AppState.self) private var appState
    @Environment(ManagerChrome.self) private var chrome

    var body: some View {
        Button {
            // Entering management is meaningless with the panel hidden, so reveal it.
            if !chrome.managingTags { chrome.inspectorVisible = true }
            chrome.managingTags.toggle()
        } label: {
            Label("Manage Tags", systemImage: "tag")
                .symbolVariant(chrome.managingTags ? .fill : .none)
        }
        .buttonStyle(.bordered)
        .labelStyle(.iconOnly)
        .tint(chrome.managingTags ? .accentColor : nil)
        .disabled(appState.managedPlaylist == nil)
        .help(chrome.managingTags ? "Edit selected files' tags" : "Manage playlist tags")
    }
}

private struct ToggleTagsButton: View {
    @Environment(ManagerChrome.self) private var chrome

    var body: some View {
        Button {
            chrome.inspectorVisible.toggle()
        } label: {
            Label("Toggle Tags", systemImage: "sidebar.right")
        }
        .buttonStyle(.bordered)
        .labelStyle(.iconOnly)
        .help(chrome.inspectorVisible ? "Hide tags" : "Show tags")
    }
}
